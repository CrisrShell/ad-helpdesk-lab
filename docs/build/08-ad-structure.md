# 1.4: Active Directory structure – OUs, groups and a secured share

**Goal:** organise the domain like a real company: folders for people and computers, groups for roles, and a shared folder that only the right department can use.

**Domain:** `ad.nebula.internal` · **Tools used:** AD Administrative Center (`dsac.exe`), AD Users and Computers (`dsa.msc`), File Explorer, PowerShell for checks

---

## Key concepts

### Active Directory (AD)
A central **directory** (a database) of everything in the company network: users, computers and groups. Instead of each PC having its own accounts, everyone logs in with **one account** that AD checks. Think of it as the company's phone book combined with its key cabinet.

### Organizational Unit (OU)
A **folder inside AD** used to organise objects. OUs matter for two reasons:
1. **Order:** finding things in a large company.
2. **Policy:** Group Policy settings (step 1.5) are applied **per OU**. Put an object in an OU and it receives that OU's settings.

AD's built-in `Users` and `Computers` containers are **not OUs**, and **can't have Group Policy linked**. That's why the lab has its own `Nebula` OU tree.

### Group
A list of users (or other groups) treated as one. Permissions are given to the **group**, never to individual people. When someone changes role, you change their **group membership**, not dozens of permissions.

### Group scope: Global vs Domain Local

| Scope | Answers the question | Typically contains |
|---|---|---|
| **Global** | "**Who** are you?" (a role or department) | User accounts |
| **Domain Local** | "**What** can you access?" (a resource) | Global groups |

### AGDLP: Microsoft's standard pattern
**A**ccounts go into **G**lobal groups, which go into **D**omain **L**ocal groups, which get **P**ermissions.

```
User (Ava)  →  GG_Finance  →  DL_Share_Finance_RW  →  Modify on C:\Shares\Finance
 Account        Global          Domain Local            Permission
```
**Why:** new Finance starter? Add them to **one** group (`GG_Finance`), and they get **every** Finance permission automatically. Nobody edits folder permissions.

### Group naming convention

| Part | Meaning |
|---|---|
| `GG_` | **G**lobal **G**roup: a role or department |
| `DL_` | **D**omain **L**ocal group: access to one resource |
| `Share_Finance` | Which resource: the Finance shared folder |
| `_RW` | **R**ead/**W**rite access (a read-only group would end in `_RO`) |

A good name tells anyone **what the group is for** without opening it.

### Distinguished Name (DN)
An object's full **address** in AD, read **right to left**:
```
CN=CL01,OU=Computers,OU=Nebula,DC=ad,DC=nebula,DC=internal
          ↑ object   ↑ folder    ↑ folder  ↑ domain: ad.nebula.internal
```
`CN` = object name · `OU` = organizational unit · `DC` = a part of the domain name

### Share permissions vs NTFS permissions
A shared folder is protected by **two locks**:

| Layer | Applies when | Set in |
|---|---|---|
| **Share** permissions | Accessing over the network (`\\dc01\Finance`) | Properties → Sharing |
| **NTFS** permissions | Always, over the network **and** locally | Properties → Security |

Over the network, the **more restrictive of the two wins**. Best practice: keep the share permission broad (*Authenticated Users: Change*), and do the real control with NTFS.

---

## What was built

### 1. OU structure
```
ad.nebula.internal
└── Nebula
    ├── Users
    │   ├── IT
    │   ├── Finance
    │   └── Sales
    ├── Groups
    ├── Computers          ← CL01 moved here
    ├── ServiceAccounts    ← accounts used by applications, not people
    └── Disabled           ← leavers' accounts, kept for audit before deletion
```
**How:** ADAC → right-click the domain → **New → Organizational Unit**. New OUs are **protected from accidental deletion** by default; keep that setting on.

**Learning tip:** ADAC's **PowerShell History** pane (at the bottom) shows the command behind each click, e.g. `New-ADOrganizationalUnit`.

### 2. Groups (in `Nebula\Groups`)

| Global (who) | Domain Local (what) | Membership |
|---|---|---|
| `GG_IT` | `DL_Share_IT_RW` | `GG_IT` is a member of `DL_Share_IT_RW` |
| `GG_Finance` | `DL_Share_Finance_RW` | `GG_Finance` is a member of `DL_Share_Finance_RW` |
| `GG_Sales` | `DL_Share_Sales_RW` | `GG_Sales` is a member of `DL_Share_Sales_RW` |

All six are **Security** groups. That type can be given permissions; *Distribution* groups are for email lists only.

**How:** ADAC → `Nebula\Groups` → **New → Group** → set the name, scope and type. Then open the `DL_` group → **Members → Add** → its `GG_` group.

### 3. CL01 moved into `Nebula\Computers`
**How:** ADUC → right-click **CL01** → **Move…** → `Nebula\Computers`.
**Why:** CL01 will now receive the computer policies linked to that OU in step 1.5.

Drag and drop only works **within one console window**, not between ADUC and ADAC.

### 4. Finance shared folder (on DC01)
1. Create `C:\Shares\Finance`.
2. **Sharing:** Properties → Sharing → Advanced Sharing → share name `Finance` → Permissions: *Authenticated Users = Change*.
3. **Security (NTFS):** Properties → Security → Advanced → **Disable inheritance** → remove all inherited entries, then add:

| Who | Permission | Why |
|---|---|---|
| Administrators | Full control | Manage the folder |
| SYSTEM | Full control | Windows itself (backups, services) |
| `DL_Share_Finance_RW` | Modify | Finance staff can read, write and delete files, but **not** change permissions |

**Disable inheritance** stops the folder copying permissions from `C:\`, so only what you grant applies.

Lab shortcut: in production, file shares live on a **member server**, never on a domain controller.

---

## Verify (PowerShell on DC01)
```powershell
Get-ADOrganizationalUnit -Filter * | Select-Object Name, DistinguishedName   # the OU tree
Get-ADGroup -Filter 'Name -like "GG_*" -or Name -like "DL_*"' | Select-Object Name, GroupScope
Get-ADGroupMember DL_Share_Finance_RW                     # → GG_Finance
Get-ADComputer CL01 | Select-Object DistinguishedName     # → …OU=Computers,OU=Nebula…
Get-SmbShare Finance                                      # the share exists
icacls C:\Shares\Finance                                  # Administrators F · SYSTEM F · DL_Share_Finance_RW M
```
In `icacls` output: **F** = Full control · **M** = Modify · **(OI)(CI)** = applies to files and subfolders.

---

## Result
- [x] `Nebula` OU tree, ready for Group Policy
- [x] Six security groups following AGDLP
- [x] CL01 in `Nebula\Computers`
- [x] Finance share protected by NTFS through `DL_Share_Finance_RW`

**Next (1.5–1.6):** Group Policy for the OUs, and PowerShell scripts that create users and place them in these groups.
