## 7. DHCP on DC01

### 1. Confirm the authorisation worked

```powershell
Get-DhcpServerInDC                                              # expect: dc01.ad.nebula.internal  10.10.10.10
Get-ADGroup -Filter "Name -like 'DHCP*'" | Select-Object Name   # expect: DHCP Administrators, DHCP Users
Get-Service DHCPServer                                          # expect: Running
```

### 2. Create the scope

```powershell
Add-DhcpServerv4Scope -Name "Corp-LAN" -StartRange 10.10.10.100 -EndRange 10.10.10.199 `
  -SubnetMask 255.255.255.0 -LeaseDuration 8.00:00:00 -State Active
```

- The pool `.100–.199` sits apart from static addresses (.10, .20), reservations (.50) and the gateway (.254), so nothing is handed out twice.
- 8 days is the Windows default for stable wired LANs. Short leases suit guest Wi-Fi.

### 3. Set the scope options

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

### 4. Verify 

```powershell
Get-DhcpServerv4Scope                         # State Active, range
Get-DhcpServerv4OptionValue -ScopeId 10.10.10.0         # options 3, 6, 15 listed
Get-DhcpServerv4ScopeStatistics               # Free / InUse / PercentageInUse
Get-DhcpServerv4Lease -ScopeId 10.10.10.0     # who has which address, and their MAC
```