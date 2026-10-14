# 1.5: Group Policy – central control of users and computers

**Goal:** apply company rules automatically (password rules, mapped drives, restrictions, updates) to the right users and computers, without touching each PC.

**Tools:** Group Policy Management (`gpmc.msc`) to create policies · `gpupdate` and `gpresult` on CL01 to apply and check them

---

## Key concepts

| Term | Simple meaning |
|---|---|
| **Group Policy** | Windows' built-in way to push settings from the domain to many users and computers at once |
| **GPO** (Group Policy Object) | One named bundle of settings, e.g. "map the Finance drive" |
| **Link** | A GPO does nothing until it's **linked** to the domain or an OU. It then applies to the users or computers **in that OU** |
| **Computer Configuration** | Settings for the **machine**; applied at startup, whoever logs on |
| **User Configuration** | Settings for the **person**; applied at logon, on whichever PC they use |
| **Policies vs Preferences** | *Policies* are enforced and locked (the user can't change them). *Preferences* set a starting value the user could change, e.g. drive maps |
| **Item-level targeting** | A filter inside a preference: "only apply this to members of group X" |
| **LSDOU** | The order policies apply: **L**ocal → **S**ite → **D**omain → **O**U. If two settings conflict, the **last applied wins** (the OU closest to the object) |
| `gpupdate /force` | Apply policies now (normally they refresh about every 90 minutes) |
| `gpresult` | Show which policies applied to a user or computer, and which were filtered out |

**Naming convention used:** `U-` = user policy · `C-` = computer policy. The purpose is clear from the name alone.

---

## Before starting: Finance share corrected

Verification (`Get-SmbShare`, `icacls`) showed that step 1.4's share settings hadn't applied as intended:
- The folder **wasn't shared**.
- Its permissions were **inherited** (`(I)` in `icacls`), so every user could read it.

On a later attempt, the permissions were set on the **parent** `C:\Shares`, which would have leaked Finance access to future IT and Sales folders.

**Corrected state**

| Folder | Permissions | Inheritance |
|---|---|---|
| `C:\Shares` (parent) | Administrators: Full · SYSTEM: Full | Admin baseline only |
| `C:\Shares\Finance` | Administrators: Full · SYSTEM: Full · `DL_Share_Finance_RW`: Modify | **Disabled.** Finance has its own permissions |

Shared as `\\dc01\Finance` (share permission: Authenticated Users = Change; NTFS does the real control).

**Lesson:** a change isn't done until it's verified. Permissions belong on **each department folder**, given to **groups**, never to individual accounts.

---

## Step 1 – Test users (ADUC)

| User | Logon | OU | Group |
|---|---|---|---|
| Ava Stone | `astone` | `Nebula\Users\Finance` | `GG_Finance` |
| Liam Park | `lpark` | `Nebula\Users\Sales` | `GG_Sales` |

Created with *"User must change password at next logon"*, the normal practice for new accounts. Step 1.6 automates this process.

---

## Step 2 – The four policies

### Policy 1: password and lockout rules (domain-wide)
**Where:** edit the existing **Default Domain Policy**. Domain password rules only take effect at **domain level**.
**Path:** Computer Configuration → Policies → Windows Settings → Security Settings → Account Policies

| Setting | Value | Why |
|---|---|---|
| Minimum password length | 12 | Longer passwords resist guessing |
| Account lockout threshold | 5 attempts | Stops password-guessing attacks |
| Lockout duration | 15 min | The account unlocks itself |
| Reset lockout counter after | 15 min | The bad-attempt count clears |

### Policy 2: `U-DriveMap-Finance`, linked to `Nebula\Users`
**Path:** User Configuration → Preferences → Windows Settings → Drive Maps → New Mapped Drive
- Action **Update** · Location `\\dc01\Finance` · Label `Finance` · Letter **F:**
- **Item-level targeting:** security group `NEBULA\GG_Finance`

One GPO covers all users; targeting means **only Finance** gets the drive.

### Policy 3: `U-Restrict-Sales`, linked to `Nebula\Users\Sales`
**Path:** User Configuration → Policies → Administrative Templates → Control Panel
- **Prohibit access to Control Panel and PC settings:** Enabled

This stops users changing system settings, which cuts down on accidental breakage and support tickets.

### Policy 4: `C-WindowsUpdate`, linked to `Nebula\Computers`
**Path:** Computer Configuration → Policies → Administrative Templates → Windows Components → Windows Update → Manage end user experience
- **Configure Automatic Updates:** Enabled · option **4**: auto-download and schedule the install

Keeps every company PC patched without relying on users.

---

## Step 3 – Testing on CL01

| Test | Logged on as | Command or action | Result |
|---|---|---|---|
| Computer policy applied | Administrator | `gpupdate /force` → `gpresult /r /scope computer` | `C-WindowsUpdate` listed ✅ |
| Finance drive | `astone` | File Explorer | **F: Finance** present; can create files ✅ |
| Drive targeting | `lpark` | File Explorer | No F: drive (filtered out by targeting) ✅ |
| Control Panel blocked | `lpark` | Open Control Panel | Blocked by policy ✅ |
| Share security | `lpark` | `\\dc01\Finance` | **Access denied:** not in `DL_Share_Finance_RW` ✅ |

The last test proves the whole **AGDLP** chain from step 1.4: user → `GG_Finance` → `DL_Share_Finance_RW` → Modify.

---

## Evidence: the gpresult report

```powershell
gpresult /user NEBULA\astone /h C:\gp-report-astone.html     # run as Administrator on CL01
```
- `gpresult` reports on **the user who runs it**, unless `/user` says otherwise.
- Run as Ava, it failed with *access denied*: standard users can't write to `C:\`. That's correct Windows behaviour.
- Running it elevated **without** `/user` would have reported the **Administrator's** policies, not Ava's.

**Lesson:** when troubleshooting a user's problem, run diagnostics **as that user**, or point them **at that user**. Otherwise you're measuring the wrong account.

---

## Result
- [x] Finance share corrected and verified
- [x] Two test users in the correct OUs and groups
- [x] Four GPOs created, linked and tested
- [x] Evidence: `gp-report-astone.html` (Ava's user policies + CL01's computer policies)
- [x] Snapshots taken

**Next (1.6):** PowerShell scripts to automate new starters, leavers and stale-account reporting.
