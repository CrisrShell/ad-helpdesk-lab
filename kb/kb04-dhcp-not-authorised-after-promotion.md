# 04 DHCP not working after DC promotion: missing groups, not authorised

| Field | Value |
|---|---|
| **Type** | Configuration fault: server role setup |
| **Priority** | P2: no client could get an IP address |
| **Status** | Resolved |
| **Affected** | DC01 (DHCP Server role) |
| **Related** | KB 03 (DHCP stops at boot: a later, separate timing issue) |

---

## Symptom
Right after promoting DC01 to a domain controller, the health check `dcdiag /q` failed the **SystemLog** test with DHCP errors:

| Event ID | Message (shortened) |
|---|---|
| `0x40B` (1035) | Unable to create or look up the **DHCP Users** local group |
| `0x40C` (1036) | Unable to create or look up the **DHCP Administrators** local group |
| `0x423` (1059) | The DHCP service failed to see a directory server for authorization |
| `0x416` (1046) | The DHCP server is **not authorized** to start; it has **stopped servicing clients** |

## Scope
- DC01 only. The DHCP role was installed **together with** AD DS, **before** promotion.
- Impact: no DHCP leases, so no new client could get an address.

## Key concepts
- **Domain controllers have no local groups.** After promotion, every group lives in Active Directory. The DHCP role's two management groups therefore have to be created **in the domain**.
- **DHCP authorisation.** In a domain, a Windows DHCP server refuses to hand out addresses until it's **authorised in Active Directory**. This stops an unknown ("rogue") DHCP server from giving clients wrong settings.

## Root cause
DHCP was installed **before** promotion. Its post-install setup (normally done by Server Manager's *"Complete DHCP configuration"* wizard) never ran, so:
1. The **DHCP Users** and **DHCP Administrators** groups didn't exist in the domain (events 1035/1036).
2. The server was **never authorised** in AD, so it stopped serving (events 1046/1059).

## Fix (DC01, PowerShell as Administrator)
```powershell
Add-DhcpServerSecurityGroup                                            # create DHCP Users / DHCP Administrators in AD
Add-DhcpServerInDC -DnsName dc01.ad.nebula.internal -IPAddress 10.10.10.10   # authorise this DHCP server in AD
Restart-Service DHCPServer                                             # apply both changes
Set-ItemProperty HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12 -Name ConfigurationState -Value 2
                                                                       # mark Server Manager's DHCP setup task as complete
```
These commands do exactly what the *Complete DHCP configuration* wizard would have done.

## Verification
```powershell
Get-DhcpServerInDC                                               # dc01.ad.nebula.internal  10.10.10.10
Get-ADGroup -Filter "Name -like 'DHCP*'" | Select-Object Name    # DHCP Administrators, DHCP Users
Get-Service DHCPServer                                           # Running
dcdiag /test:SystemLog /q                                        # clean once the old error events age out
```
Afterwards, the scope was created and CL01 received its lease (10.10.10.100, later reserved at .50).

**Note:** dcdiag's SystemLog test reports **recent** error events, so it can stay red for a while after the fix. Judge the fix by the live checks above, not by old events.

## Prevention
- Install DHCP **after** promotion, or complete the post-install configuration straight after promoting.
- After adding any server role, check **Server Manager** for its yellow ⚠️ *post-deployment configuration* flag.
- Run `dcdiag /q` after every DC change.

## Lessons
- **Order matters with server roles.** Something configured *before* a server joins or becomes a domain controller may need finishing *after*.
- **Read the event IDs, not just "failed test".** Each ID pointed to a specific missing piece (groups vs authorisation).
- **Authorisation is a security feature, not an obstacle:** it protects clients from rogue DHCP servers.

**Skills:** DHCP · Active Directory · dcdiag · Windows Event Log · role post-deployment configuration
