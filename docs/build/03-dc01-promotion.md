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

The SRV lookup is the most important check. If it fails, no client can join the domain. `dcdiag /q` printing nothing means healthy.