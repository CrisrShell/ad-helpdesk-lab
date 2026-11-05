# 08 No network, APIPA address: DHCP scope exhausted

| Field | Value |
|---|---|
| **Type** | Incident: network |
| **GLPI ticket** | #4 |
| **Category** | Network |
| **Priority** | `High` (Impact: High · Urgency: High: every new or renewing device affected) |
| **SLA** | TTO 30 min · TTR 8 h → `met` |
| **Affected** | CL01 (user Ava Stone); potentially every DHCP client on `10.10.10.0/24` |
| **Status** | Closed |

---

## Symptom
The user couldn't reach the shares or the F: drive. CL01 showed an address in `169.254.x.x`.

## Key concepts
| Term | Meaning |
|---|---|
| **DORA** | How a PC gets an address: **D**iscover → **O**ffer → **R**equest → **A**ck |
| **APIPA** (`169.254.x.x`) | The address Windows gives **itself** when no DHCP server answers. It only reaches other APIPA hosts, so in practice it means "no network" |
| **Scope exhaustion** | Every address in the pool is leased out, so the server sends **no Offer** |
| **DHCP starvation** | An **attack** that floods fake requests to use up the pool. Mitigated with **DHCP snooping** and **port security** on switches |

**APIPA only says "no DHCP answer", not why.** There are four suspects:

| # | Suspect | Ruled out by |
|---|---|---|
| 1 | DHCP service stopped or not authorised (KB 03, KB 04) | Steps 3–4 |
| 2 | Network path between client and server broken | Step 8 (the server logged the request) |
| 3 | **Scope full** | Steps 6–8 → **root cause** |
| 4 | Client fault | The client sent requests and got a clear refusal |

## Before any change: baseline and backup (DC01)
```powershell
Get-DhcpServerv4Scope | Format-List ScopeId, Name, StartRange, EndRange, State, LeaseDuration
Get-DhcpServerv4Reservation -ScopeId 10.10.10.0
New-Item -ItemType Directory -Force C:\Backup | Out-Null
Export-DhcpServer -File C:\Backup\dhcp-before-ticket4.xml -Leases
```
The backup stays on the server and is **not** committed to Git.

## Diagnosis

**Client (CL01, PowerShell as admin)**

| # | Command | Result |
|---|---|---|
| 1 | `ipconfig /all` | IPv4 `169.254.x.x` **(Autoconfiguration)**, DHCP Enabled: Yes, no DHCP server |
| 2 | `Test-NetConnection 10.10.10.10 -Port 445` | Fails: the client is on the wrong network, so this says nothing about DC01 |

**Server (DC01)**

| # | Check | Command | Result |
|---|---|---|---|
| 3 | Service running | `Get-Service DHCPServer` | Running ✅ |
| 4 | Authorised in AD | `Get-DhcpServerInDC` | dc01 listed ✅ |
| 5 | Scope active | `Get-DhcpServerv4Scope` | Active, range only `.100–.104` |
| 6 | **Free addresses** | `Get-DhcpServerv4ScopeStatistics` | **Free 0 · 100% in use** ← clue |
| 7 | Who holds them | `Get-DhcpServerv4Lease -ScopeId 10.10.10.0 \| Select-Object IPAddress, ClientId, HostName` | 5 unknown clients `UNKNOWN-100…104` |
| 8 | Did the server hear CL01? | `Get-Content C:\Windows\System32\dhcp\DhcpSrvLog-$((Get-Date).ToString('ddd')).log -Tail 15` | Event ID **14**: *address pool exhausted* |

**Step 8 is the key.** It proves the request **reached** the server (the network path is fine) and was refused because the pool was empty.

**GUI alternative:** `dhcpmgmt.msc` → IPv4 → Scope → **Address Leases** / **Display Statistics**.

## Security check
The five clients weren't in the **GLPI inventory** (Assets → Computers lists only DC01 and CL01). Unknown devices holding a whole pool can mean **DHCP starvation**.
On a real network: find the switch port from the MAC address table, then enable **DHCP snooping** and **port security**.

## Root cause
The pool was too small (5 addresses), and all of them were leased by unknown clients. CL01 had also lost its **reservation**, so it competed for the pool like any other device.

> **Lab note:** the fault was injected by removing CL01's reservation, shrinking the range to `.100–.104` and adding 5 fake leases with `Add-DhcpServerv4Lease`.

## Fix (DC01, PowerShell): an emergency change, recorded in the ticket
```powershell
100..104 | ForEach-Object { Remove-DhcpServerv4Lease -IPAddress "10.10.10.$_" }          # remove unknown leases
Set-DhcpServerv4Scope -ScopeId 10.10.10.0 -StartRange 10.10.10.100 -EndRange 10.10.10.199   # restore pool (baseline)
Add-DhcpServerv4Reservation -ScopeId 10.10.10.0 -IPAddress 10.10.10.50 -ClientId 00-0C-29-9F-87-11 -Name CL01
```
I used **PowerShell rather than the GUI** for the fix because the values come exactly from the baseline, the changes are repeatable, and the output goes straight into the ticket as evidence.

**Command gotcha:** `Remove-DhcpServerv4Lease -ScopeId … -IPAddress …` fails with *"Parameter set cannot be resolved"*. The command has **parameter sets**, so it accepts **either** `-IPAddress` **or** `-ScopeId`, not both. `Get-Command <cmd> -Syntax` shows the valid combinations.

## Verification
**DC01:** the scope range matches the baseline, the CL01 reservation exists, and `Get-DhcpServerv4ScopeStatistics` shows Free > 0.

**CL01:**
```powershell
ipconfig /renew
ipconfig /all | findstr /i "IPv4 DHCP"          # 10.10.10.50 · DHCP Server 10.10.10.10
Test-NetConnection dc01 -Port 445               # TcpTestSucceeded : True
```

## GLPI ticket record
| Entry | Content |
|---|---|
| **Task** (20 min) | APIPA on CL01. DHCP running and authorised; scope Free 0 / 100%; audit log ID 14. 5 unknown leases held the pool |
| **Task** (private) | Unknown clients not in GLPI inventory: possible DHCP starvation. Recommend switch-port trace, DHCP snooping |
| **Follow-up** | "Your network connection has been restored. Please let us know if any other PCs had the same problem." |
| **Solution** | Scope exhausted by 5 unknown clients. Leases removed, range and CL01 reservation restored; connectivity confirmed |

**Audit note:** a solution was added by mistake before the work was finished. It was **refused** (status back to Processing), and the final solution was added after verification. Both remain in the timeline: tickets are records, not drafts.

**Separate issue:** the user's missing F: drive existed **before** this incident, so it was logged as **ticket #5**. Mixing two faults in one ticket hides the root cause of each.

Evidence: `docs/img/ticket-04-apipa.png` · `ticket-04-scope-full.png` · `ticket-04-dhcp-audit-log.png` · `ticket-04-fixed.png` · `ticket-04-glpi.png`

## Prevention
- **Monitor scope usage.** Alert at ~80% (P4: Zabbix). Windows also logs a warning when a scope is nearly full.
- **Size scopes for growth**, and use **shorter leases** where devices come and go (guest Wi-Fi).
- **Reservations** for devices that must always get the same address.
- **DHCP snooping / port security** against starvation and rogue DHCP servers.
- **Back up** DHCP before changes (`Export-DhcpServer`).

**Skills:** DHCP (DORA, leases, reservations) · APIPA · layered troubleshooting · DHCP audit log · `Export-DhcpServer` · DHCP starvation awareness · change control · GLPI
