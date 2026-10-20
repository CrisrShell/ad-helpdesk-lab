# 05  User account locked out

| Field | Value |
|---|---|
| **Type** | Incident: account access |
| **GLPI ticket** | # `1` |
| **Category** | Account |
| **Priority** | `Low` |
| **SLA** | TTO 30 min · TTR 8 h → `met` |
| **Affected user** | Ava Stone (`astone`), Finance |
| **Status** | Resolved |

---

## Symptom
The user couldn't log on to CL01. After several attempts, Windows showed:
```
The referenced account is currently locked out and may not be logged on to.
```

## Scope
- One user, one PC (CL01).
- Other users could log on normally, so this wasn't a domain-wide or network problem.

## Background: why accounts lock
The domain's **Account Lockout Policy** (Default Domain Policy, step 1.5) blocks an account after **5 wrong passwords**, for **15 minutes**. It's a security control: it stops attackers guessing passwords. Its side effect is that genuine users get locked out by typos or old saved passwords.

```powershell
Get-ADDefaultDomainPasswordPolicy | Select-Object LockoutThreshold, LockoutDuration, LockoutObservationWindow
# 5 · 00:15:00 · 00:15:00
```

## Diagnosis (DC01, PowerShell as Administrator)

**1. Does the account exist, and what's its exact logon name?**
```powershell
Get-ADUser astone | Select-Object Name, SamAccountName, Enabled
```
`<paste output>`

**2. Is it locked?**
```powershell
Search-ADAccount -LockedOut | Select-Object Name, SamAccountName
Get-ADUser astone -Properties LockedOut, BadLogonCount, LastBadPasswordAttempt, LockoutTime |
  Select-Object LockedOut, BadLogonCount, LastBadPasswordAttempt, LockoutTime
```
`<paste output>`. Expect `LockedOut : True` and `BadLogonCount : 5`.

**3. Where did the bad passwords come from?**
```powershell
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4740} -MaxEvents 5 | Format-List TimeCreated, Message
```
**Event 4740** = "a user account was locked out". **Caller Computer Name** shows the machine that sent the bad passwords: `<CL01 / not logged>`.

> If no 4740 events appear, account-management auditing isn't recording on the DC. Note it as a finding; steps 1–2 are enough to confirm the lockout.

## Root cause
Five incorrect passwords entered at CL01 within 15 minutes triggered the lockout policy, working **as designed**.

## Resolution
```powershell
Unlock-ADAccount astone
Get-ADUser astone -Properties LockedOut | Select-Object LockedOut      # False
```
The user then logged on to CL01 with their correct password ✅.

**Unlock vs reset.** If the user **knows** their password, **unlock only**. Reset the password only if they've forgotten it, and **verify their identity first** (see KB 06). Resetting when it isn't needed creates extra work for the user and an extra security risk.

## GLPI ticket record
| Entry | Content |
|---|---|
| **Task** (internal, 10 min) | Confirmed lockout with `Search-ADAccount`; source CL01; unlocked with `Unlock-ADAccount` |
| **Follow-up** (to user) | "Your account has been unlocked. It was locked after 5 incorrect passwords from CL01. Please check Caps Lock and any saved passwords." |
| **Solution** | Account unlocked after lockout policy triggered; user confirmed access |
| **Status** | Solved → Closed |

Evidence: `docs/img/ticket-01-lockout.png`

## Prevention / advice to the user
- Check **Caps Lock** and the **keyboard layout** before retrying.
- Repeated lockouts with no user mistake usually mean an **old password saved somewhere**: a phone's email app, a mapped drive, or a scheduled task. Event 4740's caller computer points to it.
- The lockout clears itself after 15 minutes, but an unlock is faster for the user.

## Lesson from the test itself
The first test targeted `lpark`, an account that **didn't exist**. No lockout occurred, and Windows showed only a generic "invalid credentials" message. Windows deliberately doesn't reveal whether a username exists, which prevents **username enumeration** by attackers.

**First diagnostic step for any "can't log in" ticket: confirm the account exists and check its exact logon name.** Verify against the system, not against documentation.

**Skills learned:** Active Directory · account lockout policy · `Search-ADAccount` · Security event log (4740) · GLPI ticket lifecycle · user communication
