# 00 – Lab has no internet name resolution on eduroam (plus: ping fails from lab VMs)

**Type:** Lab infrastructure fault · **Priority:** P3 (blocks patching, not the whole lab) · **Status:** DNS worked around; ICMP from lab VMs fails (known VMware NAT limitation, accepted)
**Affected:** DC01 (10.10.10.10) and, by design, every lab VM

## Symptom
During DC01 pre-promotion prep, the internet checks failed:
- `Test-Connection 1.1.1.1` → `Error due to lack of resources` (PowerShell 5.1's wording for no reply)
- `Resolve-DnsName microsoft.com` → `This operation returned because the timeout period expired`

Without name resolution, Windows Update can't run.

## Scope
- Every lab VM depends on the same path, so all of them are affected
- The gateway (EDGE01) was reachable
- **What had changed:** the laptop was connected to eduroam
- **Host network:** a VPN was active on the laptop

## Path
```
DC01 → EDGE01 (NAT) → VMware NAT 192.168.136.2 (vmnat.exe on host) → laptop → home router / eduroam → internet
```

## Hypotheses (most likely first)
1. EDGE01's source NAT is missing or wrong
2. VMware NAT or the host has no internet
3. The upstream network filters some protocols

## Tests
| # | Network | Command | Result | Conclusion |
|---|---|---|---|---|
| 1 | eduroam | `Get-NetNeighbor -IPAddress 10.10.10.254` (DC01) | Resolved MAC | L2 to the gateway works |
| 2 | eduroam | `tracert -d 1.1.1.1` (DC01) | Hop 1 .254, hop 2 192.168.136.2, then `* * *` | Traffic reaches VMware NAT. Stars beyond it are inconclusive, because VMware NAT doesn't relay TTL-exceeded |
| 3 | eduroam | `show configuration commands \| match nat` (EDGE01) | Rule 100: eth0, 10.10.10.0/24, masquerade | NAT configured → **H1 rejected** |
| 4 | eduroam | `show ip route 0.0.0.0/0` (EDGE01) | Default via 192.168.136.2 on eth0 | Routing correct |
| 5 | eduroam | `Test-NetConnection 1.1.1.1 -Port 443` (DC01) | `TcpTestSucceeded : True` | TCP egress works end to end → **H2 rejected** |
| 6 | eduroam | `Resolve-DnsName microsoft.com` via 1.1.1.1 (DC01) | Timeout | External DNS dropped |
| 7 | **home** | `Resolve-DnsName microsoft.com` via 1.1.1.1 (DC01) | Answers returned | Only the network changed → **eduroam blocks external DNS** |
| 8 | home | `Test-NetConnection www.microsoft.com -Port 443` (DC01) | `True` | Full internet access for applications |
| 9 | home | `ping 1.1.1.1` (DC01) | No reply | ICMP fails on **both** networks, so it isn't an eduroam issue |
| 10 | home | `ping 192.168.136.2` (EDGE01) | Replies, TTL 128 | EDGE01 → VMware NAT is fine (TTL 128 = a Windows-hosted service) |
| 11 | home | `ping 1.1.1.1` (EDGE01, its own WAN IP, no lab NAT) | 100% loss | ICMP is lost at or beyond VMware NAT |
| 12 | home | `ping 1.1.1.1` (laptop) | Replies, TTL 56 | Host and home path pass ICMP → **lost inside VMware NAT** |
| 13 | home | Host firewall (Private profile) disabled briefly; `ping 1.1.1.1` (EDGE01) | 100% loss | Windows Defender Firewall is **not** the cause (firewall re-enabled immediately) |
| 14 | home | Host VPN disconnected; `ping 1.1.1.1` (EDGE01) | 100% loss | The VPN is **not** the cause |

## Root cause
Two independent issues:
1. **DNS:** eduroam's policy blocks DNS to external resolvers; only campus resolvers are allowed. The lab hard-coded a public resolver (1.1.1.1), so lab name resolution depended on the host network allowing external DNS. Proven by test 7: the same config works at home.
2. **ICMP:** VMware Workstation's NAT service (`vmnat.exe`) relays TCP and UDP but doesn't pass ICMP echo out to the internet in this setup, on any network. Tests 10–12 locate the loss inside VMware NAT: ping from the host works, and ping from VMs dies there. Tests 13–14 rule out the host firewall and the VPN. **Conclusion: a VMware NAT limitation; ping from lab VMs to the internet fails.**

The lab itself (routing, EDGE01 NAT, TCP/UDP egress) is healthy.

## Fix / workaround
- **DNS, applied:** build on the home network, where external DNS is allowed.
- **DNS, designed (permanent; not yet applied):** make EDGE01 a DNS forwarder to VMware's NAT DNS proxy, which uses the host's resolver, so the lab works on any network:
  ```powershell
  configure
  delete system name-server 1.1.1.1
  set system name-server 192.168.136.2  # EDGE01's own lookups via VMware NAT
  set service dns forwarding name-server 192.168.136.2  # where client queries are forwarded
  set service dns forwarding listen-address 10.10.10.254  # answer on the LAN side only
  set service dns forwarding allow-from 10.10.10.0/24 # lab only: not an open resolver
  comit
  save
  exit

  ```
- **ICMP, accepted as a known limitation:** ping from lab VMs to the internet fails, and no lab function needs it. Test internet reachability from lab VMs with TCP instead (`Test-NetConnection <host> -Port 443`). No firewall or VPN changes were made: both were ruled out, and loosening them would add risk for no gain.

## Verification
On the home network:
- `Resolve-DnsName microsoft.com` returns addresses ✅
- `Test-NetConnection www.microsoft.com -Port 443` succeeds ✅
- Windows Update runs ✅

## Prevention / lessons
- **"Ping fails" ≠ "no connectivity."** Always test the protocol the application uses (TCP 443, UDP 53).
- **Change one variable to prove a cause.** Moving networks with the same config isolated the DNS cause.
- **Test hop by hop from the edge device itself** (EDGE01 → its gateway → the internet) to localise where a protocol dies.
- **Don't let one test explain two symptoms.** On eduroam, DNS and ICMP failed together and looked like a single cause. Testing at home showed they were separate issues.
- Don't hard-code public resolvers into infrastructure; forward through a component that follows the environment.
- Tracert through VMware NAT always stops after the VMware gateway. That's expected, not a fault.
- **Rule out suspects one at a time and record the negatives.** Disabling the firewall, then the VPN, each with a single re-test, proved where the fault was *not*. That's as valuable as finding where it is.
- Never leave a security control disabled after a test. Re-enable it immediately and verify (`Get-NetFirewallProfile`).
- On shared networks, the acceptable-use policy applies: scanning stays inside the lab.

**Time to diagnose:** ~<fill in> min · **Skills:** layered troubleshooting, ARP, NAT verification, ICMP vs TCP/UDP testing, DNS, variable isolation, elimination testing
