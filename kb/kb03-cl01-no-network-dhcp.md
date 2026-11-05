# 03 CL01 can't reach GLPI: no usable IP address (DHCP)

| Field | Value |
|---|---|
| **Type** | Incident: client network connectivity |
| **Priority** | P3: one client affected; servers unaffected |
| **Status** | Resolved |
| **Affected** | CL01 (Windows 11, DHCP client) |
| **Related** | dcdiag event `0x423` on DC01 (DHCP authorisation at boot) |

---

## Symptom
After installing the GLPI Agent, DC01 appeared in **GLPI → Assets → Computers**, but CL01 didn't. A connectivity test from CL01 failed before any packet was sent:

```
PS> Test-NetConnection 10.10.10.20 -Port 80
WARNING: TCP connect to (10.10.10.20 : 80) failed
InterfaceAlias   :            ← empty
SourceAddress    :            ← empty
TcpTestSucceeded : False
```

## Scope
- **CL01 only.** DC01 reached GLPI and sent its inventory.
- DC01 has a **static IP**; CL01 gets its address from **DHCP** (a reservation at 10.10.10.50).
- The GLPI Agent service on CL01 was running, so the agent itself wasn't the issue.

## Key clue
`InterfaceAlias` and `SourceAddress` were **empty**. Windows couldn't pick a network interface or source address for the connection, so CL01 had **no usable IP address** on the lab network. The fault was on the client side, before GLPI or the firewall were involved.

## Hypotheses
1. Virtual network cable disconnected in VMware
2. No DHCP lease, because DC01's DHCP service wasn't serving
3. GLPI unreachable (ruled out: DC01 reached it from the same network)

## Diagnosis and fix
| # | Where | Action | Result |
|---|---|---|---|
| 1 | CL01 | `Test-NetConnection 10.10.10.20 -Port 80` | Empty source address: no usable IP |
| 2 | DC01 | `Get-DhcpServerInDC` | DC01 authorised |
| 3 | DC01 | `Restart-Service DHCPServer` | DHCP re-checks its authorisation now that AD is fully started |
| 4 | DC01 | `sc.exe config DHCPServer start= delayed-auto` | DHCP now starts ~2 minutes after boot, once AD is ready |
| 5 | CL01 | `ipconfig /renew` → `ipconfig /all` | `10.10.10.50 (Preferred)`, the expected reservation |
| 6 | CL01 | `Test-NetConnection 10.10.10.20 -Port 80` | `TcpTestSucceeded : True` |
| 7 | GLPI | Refresh **Assets → Computers** | CL01 listed. The agent retried by itself once the network was up, so no `--force` was needed |

> **Not recorded:** CL01's address *before* the renew (an APIPA `169.254.x.x` would have confirmed hypothesis 2 directly). Capture `ipconfig /all` **before** fixing, next time.

## Root cause (probable)
DC01 runs both **Active Directory** and **DHCP**. At boot, the DHCP service started **before AD was ready**, couldn't confirm that it's authorised in AD (dcdiag event `0x423`: *"failed to see a directory server for authorization"*), and **stopped issuing leases**. A Windows DHCP server in a domain refuses to serve until it can verify its authorisation, which is a protection against rogue DHCP servers. CL01, booting afterwards, got no lease and so had no usable address.

## Prevention
- **Delayed start** for the DHCP Server service on DC01 (`delayed-auto`), so it starts after AD is available.
- **Boot order:** start EDGE01 → DC01 → *wait for DC01 to finish booting* → UBU01 → CL01.
- After booting the lab, check the DC: `Get-Service DHCPServer` and `Get-DhcpServerv4ScopeStatistics`.

## Lessons
- **Read every field of a failed test.** An empty `SourceAddress` points at the client, not the server, and saves time chasing the wrong machine.
- **Static vs DHCP explains "works on one machine, not the other."** Servers with static IPs keep working when DHCP fails; clients don't.
- **Capture the broken state before fixing.** The pre-fix `ipconfig /all` output would have turned "probable" into "confirmed".
- `Test-Connection` (ping only) ≠ `Test-NetConnection` (ping + TCP port). Use the one with `-Port` to test a service.

**Skills:** DHCP · AD-integrated DHCP authorisation · Windows service start types · layered troubleshooting
