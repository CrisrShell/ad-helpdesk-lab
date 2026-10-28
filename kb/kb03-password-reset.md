# 06 – Forgotten password: reset with identity verification

| Field | Value |
|---|---|
| **Type** | Service request: account access |
| **GLPI ticket** | #2 |
| **Category** | Account |
| **Priority** | Low (Impact: Low · Urgency: Medium, one user) |
| **SLA** | TTO 30 min · TTR 8 h → **met** |
| **Affected user** | Ethan Hughes (`ehughes`), Finance |
| **Status** | Closed |

---

## Symptom
The user phoned the service desk: they had forgotten their password and couldn't log on to CL01. The account wasn't locked out.

## Request or incident?
Nothing was broken: the user needed an action done for them. So this is a **service request**, not an incident (compare KB 05, where a security control blocked the account).

## Step 1: Verify identity, always first
Password resets are the **most common social-engineering target**. An attacker who phones pretending to be the user gets the account if the identity check is skipped.

| Method | How |
|---|---|
| **Callback** | Call the number in the HR record, **not** the number the caller gives |
| **Manager confirmation** | By email or Teams, from the manager's own account |
| **Employee ID + known detail** | Something only the real employee would know |

Lab record: *Identity verified by callback to the registered number + manager confirmation (simulated).*

**If verification fails:** refuse politely, don't reset, and log it in the ticket, because it may be an attack attempt.

## Step 2: Check the account (DC01, before)
```powershell
Get-ADUser ehughes -Properties PasswordExpired, PasswordLastSet, LockedOut |
  Select-Object Enabled, PasswordExpired, PasswordLastSet, LockedOut
```
```
Enabled PasswordExpired PasswordLastSet     LockedOut
------- --------------- ---------------     ---------
   True           False 28/10/2026 21:22:06     False
```
The account is enabled and not locked, so a reset (not an unlock) is the right fix.

## Step 3: Reset
**GUI (ADUC):** right-click the user → **Reset Password…** → temporary password → ✅ *User must change password at next logon* → ✅ *Unlock the user's account* → OK.

**PowerShell (used for this ticket):**
```powershell
Set-ADAccountPassword ehughes -Reset -NewPassword (Read-Host -AsSecureString "Temporary password")
Set-ADUser ehughes -ChangePasswordAtLogon $true
Unlock-ADAccount ehughes
```

| Part | Meaning |
|---|---|
| `-Reset` | Set a new password **without** knowing the old one (an admin action) |
| `Read-Host -AsSecureString` | The password is hidden: it never shows on screen or in the command history |
| `ChangePasswordAtLogon` | The user picks their own password, so IT never knows it |
| `Unlock-ADAccount` | Harmless if not locked; clears any lockout from the user's failed attempts |

## Step 4: Verify (after)
```
Enabled PasswordExpired PasswordLastSet LockedOut
------- --------------- --------------- ---------
   True            True                     False
```
- `PasswordExpired True` + `PasswordLastSet` **empty** = AD will force a password change at next logon ✅
- `LockedOut False` ✅

The user then logged on to CL01 with the temporary password, was forced to set a new one, and reached the desktop ✅.

## GLPI ticket record
| Entry | Content |
|---|---|
| **Task** (internal, 5 min) | Identity verified (callback + manager) |
| **Task** (internal, 5 min) | Reset with `Set-ADAccountPassword -Reset`; `ChangePasswordAtLogon` set; unlocked. Verified `PasswordExpired=True` |
| **Follow-up** (to user) | "Your password has been reset. The temporary password was given to you by phone; you'll be asked to set your own at logon." |
| **Solution** | Password reset after identity verification; user logged on and set a new password |
| **Status** | Solved → Closed |

Evidence: `docs/img/ticket-02-password-reset.png`

## Rules
- **Never write a password in a ticket.** Tickets are read by many people and kept for years. Give the temporary password through a **separate channel** (phone or SMS), and record only that it was given.
- **Unlock vs reset:** if the user knows their password, unlock only (KB 05). Reset only if it's forgotten.
- **Disabled is different:** "Your account has been disabled" means an admin or the leaver process turned it off. Don't re-enable without HR or manager approval. Check the account's `Description` first.

## Prevention
- **Self-service password reset (SSPR)**, e.g. Microsoft Entra SSPR, lets users reset their own passwords after MFA, which removes this ticket type almost entirely.
- Encourage a **password manager** or passphrases that are easier to remember.

**Skills:** Active Directory · social-engineering awareness · `Set-ADAccountPassword` · service request vs incident · GLPI ticket lifecycle · secure communication
