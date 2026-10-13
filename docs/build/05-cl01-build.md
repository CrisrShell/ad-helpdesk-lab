# CL01: the first client

**Q: How was the VM built, and why?**
A:
- Windows 11 needs UEFI, Secure Boot and a **TPM**. VMware adds a virtual TPM, which requires encrypting the VM's TPM files with a password.
- 1 socket × 2 cores, 4 GB RAM, 64 GB thin disk, NIC on **VMnet10**.
- I chose "Domain join instead" during setup. It creates a local admin account rather than a Microsoft account; that local account is used to join the domain.

### 1. Check the lease before joining 

```powershell
ipconfig /all
```
Expected:
```
IPv4 Address . . . : 10.10.10.100(Preferred)
Default Gateway  . : 10.10.10.254
DHCP Server  . . . : 10.10.10.10
DNS Servers  . . . : 10.10.10.10
Connection-specific DNS Suffix : ad.nebula.internal
Primary Dns Suffix . :            ← blank = not yet domain-joined
```
After the join, **Primary Dns Suffix** becomes `ad.nebula.internal`. That's an instant way to tell whether a machine is joined.

**Q: What must pass before joining?**
A:
```powershell
Resolve-DnsName dc01.ad.nebula.internal                              # DNS through the DC
Resolve-DnsName _ldap._tcp.dc._msdcs.ad.nebula.internal -Type SRV    # can locate a DC
Test-NetConnection dc01.ad.nebula.internal -Port 389                 # LDAP reachable
```
All three must pass before you join. Don't use ping to DC01 as a test: Windows Server blocks incoming ICMP by default.

### 2. Rename and join the domain

```powershell
Rename-Computer -NewName CL01 -Restart
```
**Q: Why rename before joining?**

A: So the computer account is created in AD with the right name.

**Q: How to join the domain, and what does that do?**
A:
```powershell
Add-Computer -DomainName ad.nebula.internal -Credential NEBULA\Administrator -Restart
```
1. It creates the `CL01` computer object in AD (in `CN=Computers` by default).
2. It sets up the **secure channel**: a machine password shared by CL01 and the DC. CL01 rotates it automatically every 30 days.
3. After the reboot, domain users can log on, and Group Policy applies.

### 3. First domain login and verification

```powershell
# On CL01
whoami                              # nebula\administrator
Test-ComputerSecureChannel          # True = trust with the domain is healthy
nltest /dsgetdc:ad.nebula.internal  # which DC the client found
```
### On DC01
```powershellGet-ADComputer CL01                 # the object exists
Resolve-DnsName cl01.ad.nebula.internal   # CL01 registered itself in DNS dynamically
```
### 4. Reserve CL01's address

```powershell
Add-DhcpServerv4Reservation -ScopeId 10.10.10.0 -IPAddress 10.10.10.50 -ClientId "00-0C-29-9F-87-11" -Name CL01
ipconfig /release; ipconfig /renew  # on CL01: now 10.10.10.50
```
**Q: Why a DHCP reservation instead of a static IP?**

A: The address is predictable, but the gateway and DNS are still managed centrally. If DNS ever changes, you edit the scope once, rather than every machine. `-ClientId` is the MAC address with dashes.

**On CL01, apply the new addess:**
```powershell
ipconfig /release; ipconfig /renew            # expect 10.10.10.50
```
### 5. RSAT (Remote Server Administration Tools) on CL01

```powershell
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0
Add-WindowsCapability -Online -Name Rsat.Dhcp.Tools~~~~0.0.1.0
```
**Q: Why install RSAT on CL01?** 

A: Admins manage AD from their workstation. Logging on to a DC interactively is rare, which reduces the attack surface.