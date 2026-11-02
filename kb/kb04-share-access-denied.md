# 07 – Access denied to the Finance share: user removed from group

| Field | Value |
|---|---|
| **Type** | Incident: access |
| **GLPI ticket** | #3 |
| **Category** | Access |
| **Priority** | Medium (Impact: Low · Urgency: High, one user can't work) |
| **SLA** | TTO 30 min · TTR 8 h → `<met / missed>` |
| **Affected user** | Grace Patel (`gpatel`), Finance |
| **Status** | Closed |

---

## Symptom
The user couldn't open the **F:** drive or `\\dc01\Finance`; Windows showed **access denied**. It had worked before.

## Scope
- One user. Another Finance user (`astone`) still had access.
- So the server and share were fine, and the problem was **specific to this user's account**.

## Diagnosis: layer by layer
Client checks ran **on CL01 as `gpatel`** in normal (non-admin) PowerShell: always test from where the user's problem is.

| # | Layer | Where | Command / action | Result |
|---|---|---|---|---|
| 1 | Scope | – | Does another Finance user have access? | Yes → user-specific |
| 2 | Network | CL01 | `Test-NetConnection dc01 -Port 445` | `TcpTestSucceeded : True` ✅ |
| 3 | DNS | CL01 | `Resolve-DnsName dc01` | `10.10.10.10` ✅ |
| 4 | Share | DC01 | `Get-SmbShare Finance` · `Get-SmbShareAccess Finance` | Present; Authenticated Users = Change ✅ |
| 5 | NTFS | DC01 | `icacls C:\Shares\Finance` | `DL_Share_Finance_RW:(OI)(CI)(M)` ✅ |
| 6 | Effective access | DC01 GUI | Folder → Security → Advanced → **Effective Access** → `gpatel` | Mostly ❌: **clue** |
| 7 | Group membership | DC01 | `Get-ADPrincipalGroupMembership gpatel \| Select-Object Name` | **No `GG_Finance`**: root cause |

`Test-NetConnection` tests a **TCP port** (445 = SMB file sharing). `Test-Connection` is only ping and has no `-Port` option in Windows PowerShell 5.1.

**NTFS codes:** `(OI)` files inherit · `(CI)` subfolders inherit · `(M)` Modify = read, write, delete, but not change permissions (least privilege).

## Who made the change? (Security log, DC01)
```powershell
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4729} -MaxEvents 3 | Format-List TimeCreated, Message
```
```
TimeCreated : 02/11/2026 10:50:51
Message     : A member was removed from a security-enabled global group.
  Subject:  Account Name: Administrator   Account Domain: NEBULA   (SID …-500)
  Member:   CN=Grace Patel,OU=Finance,OU=Users,OU=Nebula,DC=ad,DC=nebula,DC=internal
  Group:    GG_Finance
```
- **Event 4729** = member removed from a security-enabled global group.
- The change wasn't linked to any ticket or HR request.
- **Finding:** SID **-500** is the **built-in** Administrator. The log shows *which account* made the change, not *which person*.

## Root cause
Grace was removed from `GG_Finance`. Because of **AGDLP**, she lost `DL_Share_Finance_RW`, and with it the Modify permission:
`gpatel` ✗→ `GG_Finance` → `DL_Share_Finance_RW` → Modify on `C:\Shares\Finance`

## Approval before the fix
The removal might have been **deliberate** (a role change, an investigation or a leaver), so access wasn't restored without asking.
- An approval was requested in GLPI from the user's manager (`tech`, given approval rights in GLPI) → **Granted**.
- **Segregation of duties:** the technician doing the work doesn't approve their own request.

## Fix
ADUC → `GG_Finance` → Members → **Add** → `gpatel`
```powershell
Get-ADGroupMember GG_Finance | Select-Object Name      # Grace Patel listed
```

## The logon token: why the fix didn't work straight away
Still logged on, Grace **still got access denied**.

**Why:** Windows builds a user's list of groups (the **token**) **once, at sign-in**. It's like a festival wristband: the door checks the wristband, not the guest list. Changing the guest list (AD) doesn't change a wristband she's already wearing.

| Attempt | Result |
|---|---|
| `klist purge` (clears Kerberos tickets) | ❌ Still denied. CL01 kept its existing connection to `\\dc01`. (Running it on DC01, or in an admin window, clears the **wrong user's** tickets) |
| **Sign out → sign in** | ✅ Access restored, F: back |

After signing in again, `whoami /groups` (as `nebula\gpatel`):
```
NEBULA\GG_Finance   Group   S-1-5-21-…-1106   Mandatory group, Enabled by default, Enabled group
```
`DL_Share_Finance_RW` does **not** appear on CL01, and that's normal. **Domain local** groups are added when she connects to a resource **on the domain's servers** (DC01), not to her token on the workstation. Seeing `GG_Finance` in her token proves the fix.

## GLPI ticket record
| Entry | Content |
|---|---|
| **Task** (15 min) | Layered check: port 445 OK, DNS OK, share OK, NTFS OK. Effective Access + group check: user missing from `GG_Finance` |
| **Task** (10 min, private) | Event 4729: removed 02/11/2026 10:50:51 by built-in Administrator; no related ticket. Approval requested |
| **Approval** | Requested from `tech` (manager) → Granted |
| **Follow-up** (to user) | "Your access has been restored. Please sign out and back in if you still see 'access denied'." |
| **Solution** | Removed from `GG_Finance` (event 4729, built-in Administrator, no request). Manager approved; membership restored; new logon token confirmed access. Recommend named admin accounts |
| **Status** | Solved → Closed |

Evidence: `docs/img/ticket-03-share-access.png` · `docs/img/ticket-03-effective-access.png` · `docs/img/ticket-03-whoami-groups.png`

## Prevention
- **Named admin accounts** (e.g. `adm-creyes`) instead of the shared built-in Administrator, so every change is traceable to a person.
- **Group changes only through tickets**, with approval for access to sensitive data.
- After any group change, tell the user: **"Please sign out and back in."**

## Lessons
- **Prove it works before calling it broken**, and test as the affected user, from their machine.
- **Work through the layers in order** (network → DNS → share → NTFS → groups). Each ✅ removes a suspect.
- **Effective Access** answers "what can this user actually do?" faster than reading every permission.
- **Restoring access is still an access change:** confirm and record approval.

**Skills:** SMB/NTFS troubleshooting · AGDLP · Effective Access · Security event log (4729) · Kerberos and logon tokens · approval workflow and segregation of duties · GLPI
