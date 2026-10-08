# DC01 promotion 

Installing the roles and promote DC01 to the first domain controller of a new forest. Command are issued in PowerShell as Administrator on DC01. 


Lab context: corp LAN `10.10.10.0/24` on VMnet10, gateway EDGE01 `10.10.10.254`, domain to be `ad.astral.internal`.

---

**Q: What is a forest in AD context?**
A: AD allows administrators to organise obects of a network (such as users, computer and devices) into hierarchical collection of containers knows as the logical structure. The top-level logical container in this hierarchy is the **forest**. Within a forest are domain containers, and within domain are organisational units.


---

## 1 · Install the roles 

**Q: Why should I install the roles**
A: The promotion process relies on the binaries and components installed by the roles to configure the server as a DC. Once the those main files are installed, the DC promotion stage uses them to create the actual database, setup replication, and build the domain environment. 

```powershell
Install-WindowsFeature AD-Domain-Services, DNS, DHCP -IncludeManagementTools
```
Roles installed:

| Role | Purpose |
|---|---|
| `AD-Domain-Services` | The binaries needed to become a DC (installing them changes nothing yet) |
| `DNS` | Hosts the AD zone and SRV records |
| `DHCP` | Hands out addresses (configured after promotion) |
| `-IncludeManagementTools` | Consoles (ADUC, DNS Manager, DHCP) plus the PowerShell modules |

The outpus should show `Success: True`

---

## 2 · Test before promoting

```powershell
Test-ADDSForestInstallation -DomainName "ad.nebula.internal" -DomainNetbiosName "NEBULA" -InstallDns
```

Expected output:
```
Message                          Status
Operation completed successfully Success
```

## 3 · DC01 Promotion

```powershell
Install-ADDSForest -DomainName "ad.nebula.internal" -DomainNetbiosName "NEBULA" -InstallDns `
  -SafeModeAdministratorPassword (Read-Host -AsSecureString "DSRM password")
```

| Parameter | Meaning |
|---|---|
| `Install-ADDSForest` | Creates a **new forest**; DC01 becomes its first DC |
| `-DomainName` | The forest root domain's DNS name |
| `-DomainNetbiosName` | Short name, maximum 15 characters |
| `-InstallDns` | DC01 becomes the authoritative DNS for the domain (an AD-integrated zone) |
| `-SafeModeAdministratorPassword` | **DSRM** password: the recovery login used when AD itself is broken. Store it in a password manager |

The server restarts on its own. Log back in as `NEBULA\Administrator`; the first login is slow.


---

## 4 · Post-promotion configuration

**Q: How did I point DC01's DNS at itself?**
A:
```powershell
Set-DnsClientServerAddress -InterfaceAlias "Ethernet0" -ServerAddresses 10.10.10.10, 127.0.0.1
```
Its own IP comes first and loopback is the fallback. Leaving 1.1.1.1 configured would break AD: queries for AD records would go to a server that has never heard of `ad.nebula.internal`.

**Q: How does DC01 resolve internet names?**
A:
```powershell
Set-DnsServerForwarder -IPAddress 1.1.1.1, 9.9.9.9
```
Names DC01 doesn't own (such as microsoft.com) are forwarded to public resolvers.

| Who | DNS server used |
|---|---|
| Clients | DC01 (10.10.10.10) |
| DC01 for internal names | Itself |
| DC01 for internet names | Forwards to 1.1.1.1 / 9.9.9.9 |

**Q: Why the reverse lookup zone?**
A:
```powershell
Add-DnsServerPrimaryZone -NetworkId "10.10.10.0/24" -ReplicationScope Forest
ipconfig /registerdns
```
- The zone `10.10.10.in-addr.arpa` answers IP-to-name (PTR) lookups. Logs, `nslookup` and monitoring tools show names instead of bare IPs.
- `-ReplicationScope Forest` stores the zone in AD, so it replicates with AD to future DCs.
- `ipconfig /registerdns` makes DC01 re-register its own records, including its new PTR record.

## 5 · Time Source
The first DC is the domain's master clock (it holds the PDC Primary Domain Controller emulator role). Point it at a reliable external time source:

```powershell
w32tm /config /manualpeerlist:"0.uk.pool.ntp.org 1.uk.pool.ntp.org" /syncfromflags:manual /reliable:yes /update
Restart-Service w32time
w32tm /resync
w32tm /query /status
```
- The PDC emulator (DC01) syncs from external NTP servers.
- Every other domain member syncs from the domain hierarchy, which leads back to DC01.
- `/manualpeerlist`: the UK NTP pool servers.
- `/reliable:yes` advertises DC01 as a trustworthy time source.
- Expected: `Source: 0.uk.pool.ntp.org`. If it says `Local CMOS Clock`, it isn't syncing externally.

---

## 6. Verifying the domain

**Q: Which checks prove the DC is healthy?**
A:

| Command | Proves | Expected |
|---|---|---|
| `Get-ADDomain \| Select DNSRoot, NetBIOSName, PDCEmulator` | Domain exists | `ad.nebula.internal`, `NEBULA`, `DC01.ad.nebula.internal` |
| `Resolve-DnsName dc01.ad.nebula.internal` | Internal A record | 10.10.10.10 |
| `Resolve-DnsName _ldap._tcp.dc._msdcs.ad.nebula.internal -Type SRV` | **Clients can locate a DC** | Target `dc01.ad.nebula.internal`, port 389 |
| `Resolve-DnsName 10.10.10.10` | Reverse zone | `dc01.ad.nebula.internal` |
| `Resolve-DnsName microsoft.com` | Forwarders | Public addresses |
| `Get-SmbShare SYSVOL, NETLOGON` | DC is advertising itself | Both shares exist |
| `dcdiag /q` | Overall DC health | Prints **nothing** when healthy |

**Q: What is SYSVOL?**
A: A shared folder on every DC holding **Group Policy files and logon scripts**. DFSR replicates it between DCs. If the SYSVOL and NETLOGON shares don't exist, the DC isn't fully working.

---

## 7. DHCP

**Q: Why did dcdiag fail SystemLog right after promotion?**
A: DHCP was installed **before** promotion, which caused these events:

| Event | Meaning |
|---|---|
| `0x40B` / `0x40C`: can't create DHCP Users / DHCP Administrators | DCs have no local groups; the groups must be created in the domain |
| `0x423`: failed to see a directory server for authorisation | DHCP hasn't been authorised in AD |
| `0x416`: not authorised to start, stopped servicing clients | Domain-member DHCP servers refuse to lease until authorised. This protects against **rogue DHCP** servers |

**Q: How did I fix it?**
A:
```powershell
Add-DhcpServerSecurityGroup                      # create DHCP Users / DHCP Administrators as domain groups
Add-DhcpServerInDC -DnsName dc01.ad.nebula.internal -IPAddress 10.10.10.10   # authorise the server in AD
Restart-Service DHCPServer                       # pick up both changes
Set-ItemProperty HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12 -Name ConfigurationState -Value 2
                                                 # mark Server Manager's DHCP post-install task as done
```
Verify:
```powershell
Get-DhcpServerInDC                                              # dc01.ad.nebula.internal  10.10.10.10
Get-ADGroup -Filter "Name -like 'DHCP*'" | Select-Object Name   # DHCP Administrators, DHCP Users
Get-Service DHCPServer                                          # Running
```

**Q: Why did dcdiag also fail DFSREvent?**
A: The test flags *any* DFSR warning from the last 24 hours. A brand-new DC logs some while SYSVOL initialises. If both SYSVOL and NETLOGON are shared and Event **4602** ("SYSVOL initialized") is present, it's healthy. The test clears within 24 hours.
```powershell
Get-WinEvent -LogName "DFS Replication" -MaxEvents 10 | Select TimeCreated, Id, LevelDisplayName
dcdiag /test:DFSREvent /q
dcdiag /test:SystemLog /q
```

**Q: How did I create the scope?**
A:
```powershell
Add-DhcpServerv4Scope -Name "Corp-LAN" -StartRange 10.10.10.100 -EndRange 10.10.10.199 `
  -SubnetMask 255.255.255.0 -LeaseDuration 8.00:00:00 -State Active
```
- The pool `.100–.199` sits apart from static addresses (.10, .20), reservations (.50) and the gateway (.254), so nothing is handed out twice.
- 8 days is the Windows default for stable wired LANs. Short leases suit guest Wi-Fi.

**Q: Which options do clients receive?**
A:
```powershell
Set-DhcpServerv4OptionValue -ScopeId 10.10.10.0 -Router 10.10.10.254 -DnsServer 10.10.10.10 -DnsDomain ad.nebula.internal
```

| Option | Value | Why |
|---|---|---|
| 3, Router | 10.10.10.254 | Default gateway (EDGE01) |
| 6, DNS | 10.10.10.10 | **Must be the DC**, or the client can't find AD |
| 15, Domain name | ad.nebula.internal | Short names work (`dc01` becomes `dc01.ad.nebula.internal`) |

**Q: How does a client get an address (DORA)?**
A:
1. **D**iscover: the client broadcasts.
2. **O**ffer: the server offers an address.
3. **R**equest: the client requests it.
4. **A**cknowledge: the server confirms.

DHCP uses UDP 67 (server) and 68 (client).

**Q: How do I check the scope?**
A:
```powershell
Get-DhcpServerv4Scope                         # State Active, range
Get-DhcpServerv4OptionValue -ScopeId 10.10.10.0
Get-DhcpServerv4ScopeStatistics               # Free / InUse / PercentageInUse
Get-DhcpServerv4Lease -ScopeId 10.10.10.0     # who has which address, and their MAC
```

---

## 8. CL01: the first client

**Q: What do "CL01" and the other names mean?**
A: Role plus number: **CL**ient #01. Likewise **DC**01 is Domain Controller, **UBU**01 is the Ubuntu server, and **EDGE**01 is the edge router.

**Q: How was the VM built, and why?**
A:
- Windows 11 needs UEFI, Secure Boot and a **TPM**. VMware adds a virtual TPM, which requires encrypting the VM's TPM files with a password.
- 1 socket × 2 cores, 4 GB RAM, 64 GB thin disk, NIC on **VMnet10**.
- I chose "Domain join instead" during setup. It creates a local admin account rather than a Microsoft account; that local account is used to join the domain.

**Q: How do I check the DHCP lease before joining?**
A:
```powershell
ipconfig /all
```
Healthy output (what CL01 showed):
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
Don't ping DC01 as a test: Windows Server blocks inbound ICMP by default.

**Q: Why rename before joining?**
A: Joining creates the computer object in AD under the current name. Renaming afterwards also renames that object, which works but adds risk for nothing.
```powershell
Rename-Computer -NewName CL01 -Restart
```

**Q: How did I join the domain, and what does that do?**
A:
```powershell
Add-Computer -DomainName ad.nebula.internal -Credential NEBULA\Administrator -Restart
```
1. It creates the `CL01` computer object in AD (in `CN=Computers` by default).
2. It sets up the **secure channel**: a machine password shared by CL01 and the DC. CL01 rotates it automatically every 30 days.
3. After the reboot, domain users can log on, and Group Policy applies.

**Q: How do I verify the join?**
A:
```powershell
# On CL01
whoami                              # nebula\administrator
Test-ComputerSecureChannel          # True = trust with the domain is healthy
nltest /dsgetdc:ad.nebula.internal  # which DC the client found
# On DC01
Get-ADComputer CL01                 # the object exists
Resolve-DnsName cl01.ad.nebula.internal   # CL01 registered itself in DNS dynamically
```

**Q: Why a DHCP reservation instead of a static IP?**
A:
```powershell
Add-DhcpServerv4Reservation -ScopeId 10.10.10.0 -IPAddress 10.10.10.50 -ClientId "00-0C-29-9F-87-11" -Name CL01
ipconfig /release; ipconfig /renew  # on CL01: now 10.10.10.50
```
The address is predictable, but the gateway and DNS are still managed centrally. If DNS ever changes, you edit the scope once, rather than every machine. `-ClientId` is the MAC address with dashes.

**Q: Why install RSAT on CL01?**
A:
```powershell
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0
Add-WindowsCapability -Online -Name Rsat.Dhcp.Tools~~~~0.0.1.0
```
Admins manage AD from their workstation. Logging on to a DC interactively is rare, which reduces the attack surface.

---

## 9. Troubleshooting reference

| Symptom / output | Likely cause | Check / fix |
|---|---|---|
| Client IP `169.254.x.x` | APIPA: no DHCP reply | NIC on VMnet10? `Get-DhcpServerv4Scope` Active? `Get-DhcpServerInDC` lists DC01? Then `ipconfig /renew` |
| `ipconfig` shows DNS 1.1.1.1 on a client | Wrong scope option 6 | `Get-DhcpServerv4OptionValue -ScopeId 10.10.10.0` |
| `Add-Computer`: *"The specified domain either does not exist or could not be contacted"* | Client isn't using the DC for DNS | `ipconfig /all`, then the SRV lookup |
| SRV lookup fails on DC01 | DC isn't using itself for DNS, or Netlogon hasn't registered | `Get-DnsClientServerAddress`, then `Restart-Service Netlogon` (re-registers SRV records) |
| `Test-ComputerSecureChannel` = False | Broken trust (snapshot revert, password out of sync) | `Test-ComputerSecureChannel -Repair -Credential NEBULA\Administrator` |
| *"The trust relationship … failed"* at logon | Same as above | Log on with the local admin account, then repair |
| Logon fails, clocks differ | Kerberos 5-minute skew | `w32tm /query /status`, `w32tm /resync` |
| `w32tm` source = `Local CMOS Clock` (on DC01) | Not syncing externally | Re-run the `w32tm /config` line, then `/resync` |
| dcdiag SystemLog: DHCP `0x416`/`0x423` | DHCP not authorised | `Add-DhcpServerInDC`, restart the service |
| dcdiag DFSREvent right after promotion | Startup warnings | SYSVOL/NETLOGON shared + event 4602 = healthy; clears within 24 h |
| `Resolve-DnsName microsoft.com` times out | Forwarders blocked (eduroam) or no internet | `Get-DnsServerForwarder`; test from the host network (KB 00) |
| Ping to the internet fails but HTTPS works | VMware NAT doesn't relay ICMP | Expected; test with `Test-NetConnection -Port 443` |

---

## 10. Differences from the original Build Guide

| Build Guide | What was actually done | Why |
|---|---|---|
| `ad.astral.internal` / `ASTRAL` | `ad.nebula.internal` / `NEBULA` | Fictional company name chosen; read `nebula` wherever the guide says `astral` |
| — | Time zone, Windows Update and snapshot before promotion | Kerberos timing; patch before the DC exists |
| — | `Test-ADDSForestInstallation` | Dry-run the promotion before committing |
| DNS client `10.10.10.10` | `10.10.10.10, 127.0.0.1` | Loopback fallback |
| — | `ipconfig /registerdns` | Creates the DC's PTR record in the new reverse zone |
| — | `w32tm` external time configuration | The PDC emulator must have an authoritative time source |
| — | Verification set: SRV, PTR, SYSVOL, `dcdiag` | Proves the DC works, not just that the commands ran |
| `Add-DhcpServerInDC` then `Add-DhcpServerSecurityGroup` | Groups first, plus the `ConfigurationState` flag | Fixes the dcdiag errors; clears the Server Manager warning |
| Scope name "Corp" | "Corp-LAN" | Cosmetic |
| Join, no prior checks | Pre-join DNS/SRV/LDAP checks; rename **before** join | Catch DNS problems first; create the AD object with the right name |
| — | `Test-ComputerSecureChannel`, `nltest` | Verify the trust after joining |
| RSAT: AD + GPO | + DHCP tools | Manage DHCP from CL01 too |

---

## 11. Snapshot log

| VM | Snapshot | State |
|---|---|---|
| DC01 | `01-clean-os` | Fresh install + VMware Tools |
| DC01 | `02-prepped-static-ip-renamed-patched` | Ready to promote |
| DC01 | `03-ad-ds-promoted` | Forest created, DNS and time configured |
| DC01 | `04-dhcp-scope` | DHCP authorised, scope live, CL01 reserved |
| CL01 | `01-domain-joined` | Joined to ad.nebula.internal |

**Never revert DC01 casually.** In a real multi-DC network, restoring an old DC snapshot causes **USN rollback**, which corrupts replication. In this single-DC lab, a revert also breaks CL01's secure channel. That's useful practice later (ticket 6), but do it on purpose.

**Next:** step 1.3, UBU01 + GLPI.

