# DC01 pre-promotion prep in 5 steps

Q&A notes on preparing a fresh Windows Server 2025 VM before promoting it to a domain controller.
Lab context: corp LAN `10.10.10.0/24` on VMnet10, gateway EDGE01 `10.10.10.254`, domain to be `ad.astral.internal`.

---

## Why prepare before promotion?

**Q: Why do the IP, name and time zone come before promoting the server to a DC?**
A: Promotion bakes the server's identity (name, IP, DNS records) into Active Directory. Changing these afterwards is risky and multi-step, while changing them now takes one command each.

**Q: What does "promotion" mean?**
A: Installing the AD DS role and running `Install-ADDSForest`, which turns a normal server into a domain controller.

---

## Step 0 · Identify the adapter

**Q: How do I find the network adapter's name?**
A:
```powershell
Get-NetAdapter        # lists adapters: Name, Status (must be "Up"), MAC address, link speed
```
Result in this lab: `Ethernet0`. Every network cmdlet that follows targets it with `-InterfaceAlias`.

---

## Step 1 · Static IP

**Q: Which command sets the static IP?**
A:
```powershell
New-NetIPAddress -InterfaceAlias "Ethernet0" -IPAddress 10.10.10.10 -PrefixLength 24 -DefaultGateway 10.10.10.254
```

| Parameter | Meaning |
|---|---|
| `-InterfaceAlias "Ethernet0"` | Which adapter to configure |
| `-IPAddress 10.10.10.10` | The DC's fixed address (servers sit in the low range of the plan) |
| `-PrefixLength 24` | CIDR for mask 255.255.255.0 |
| `-DefaultGateway 10.10.10.254` | EDGE01, the only route out of the lab |

**Q: Why must a DC have a static IP?**
A: Clients find the DC by address: it's their DNS server, and DNS records point at it. If the address changed, every client would lose name resolution and authentication. Infrastructure servers (DCs, DNS, DHCP, gateways) never use DHCP.

---

## Step 2 · Temporary DNS

**Q: Which command sets the DNS server?**
A:
```powershell
Set-DnsClientServerAddress -InterfaceAlias "Ethernet0" -ServerAddresses 1.1.1.1
```

**Q: Why use a public resolver now, and why only temporarily?**
A: There's no internal DNS server yet, and DC01 needs to resolve Microsoft's servers for Windows Update. After promotion, DC01 runs DNS itself and must point to its **own** IP. A DC that resolves through a public DNS server can't find its own AD SRV records, so AD breaks.

**Q: Does the temporary DNS server always work?**
A: No. It depends on the network the laptop is on, because some networks block external DNS (see KB 00, eduroam). On the home network, 1.1.1.1 works.

---

## Step 3 · Verify, layer by layer

**Q: How do I verify connectivity, in what order, and why that order?**
A:
```powershell
Get-NetIPConfiguration                   # IP, gateway and DNS in one view; check all three first
Test-Connection 10.10.10.254 -Count 2    # can I reach my gateway? (local network)
Test-Connection 1.1.1.1 -Count 2         # can I get beyond it? (routing + NAT)
Resolve-DnsName microsoft.com            # can I resolve names? (DNS)
```
Each test depends on the previous one, so the first failure pinpoints the layer:

| First failing test | Where to look |
|---|---|
| Gateway | DC01's adapter or VMnet, or EDGE01's `eth1` |
| 1.1.1.1 (gateway OK) | EDGE01's NAT or WAN, VMware NAT, or the host network |
| DNS only | The DNS server setting, or DNS being blocked upstream |

This is **divide-and-conquer** troubleshooting: test the middle of the path, then move up or down depending on the result.

**Q: Ping is blocked somewhere. How else can I prove connectivity?**
A: Test a TCP port instead. ICMP is often filtered when TCP isn't.
```powershell
Test-NetConnection 1.1.1.1 -Port 443     # TcpTestSucceeded : True = routing and NAT work
```

**Q: How do I prove Layer 2 works when ping is blocked by a firewall?**
A: Check ARP. Firewalls filter ICMP, but ARP sits below them.
```powershell
Get-NetNeighbor -IPAddress 10.10.10.254  # Reachable/Stale + MAC = L2 OK; Incomplete = nobody answered
```
On VyOS: `show arp`.

**Q: What does "Error due to lack of resources" from `Test-Connection` mean?**
A: Nothing is short of resources. It's Windows PowerShell 5.1's misleading message for **no reply**. Classic `ping` shows the same failure as `Request timed out`.

**Q: Why does `tracert` show `* * *` after the VMware NAT gateway (192.168.136.2)?**
A: VMware's NAT doesn't pass back traceroute's "TTL exceeded" replies, so hops beyond it always look dead. Don't treat a tracert through VMware NAT as proof of failure; use ping or a TCP test.

**Q: Why can't I ping DC01 from EDGE01 or the laptop?**
A: Windows Server's firewall blocks inbound ICMP echo by default. A failed ping *to* a Windows host proves nothing on its own.

---

## Step 4 · Time zone

**Q: Which commands check and set the time zone?**
A:
```powershell
Get-TimeZone                              # check the current zone
Set-TimeZone -Id "GMT Standard Time"      # UK time (handles BST automatically); only if it's wrong
```

**Q: Why does time matter so much on a DC?**
A: Kerberos rejects authentication when the clocks differ by more than **5 minutes**, and the DC is the domain's time source. Correct timestamps are also essential when correlating logs during troubleshooting.

---

## Step 5 · Rename and restart

**Q: Which command renames the server?**
A:
```powershell
Rename-Computer -NewName DC01 -Restart    # the new name only takes effect after a reboot
```

**Q: Why rename before promotion?**
A: The computer name gets embedded in AD objects, DNS records and service registrations. Renaming an existing DC is a multi-step procedure that can break things, so the name must be final before promotion.

**Q: Why "DC01"?**
A: Role plus number: **D**omain **C**ontroller #01. Production networks normally run at least two DCs (DC02) for redundancy. Structured names let anyone identify a server's role from an alert or ticket.

---

## Remote access notes

**Q: Why did `ssh administrator@10.10.10.10` time out?**
A: Two reasons:
1. Windows Server 2025 includes OpenSSH Server but it's **disabled** by default.
2. Before joining a domain, the network is classed as **Public**, which is the strictest firewall profile.

Windows servers are normally managed with **RDP or PowerShell remoting**, which I'll enable later on purpose.

**Q: How do I copy output from the VM?**
A: VMware Tools shares the clipboard. Either highlight the text and press Enter, or pipe it:
```powershell
<command> 2>&1 | Out-String | Set-Clipboard   # 2>&1 includes the error text
```

---

## Checklist (before promotion)

- [ ] `Get-NetIPConfiguration` shows 10.10.10.10/24, gateway .254, temporary DNS
- [ ] Gateway reachable; TCP 443 to the internet succeeds; `Resolve-DnsName` works
- [ ] Time zone is GMT Standard Time
- [ ] Hostname is DC01 (`hostname`)
- [ ] Windows Update shows no pending updates
- [ ] Snapshot `02-prepped-static-ip-renamed-patched` taken
