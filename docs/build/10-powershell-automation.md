# PowerShell automation: joiners, leavers, stale accounts

**Goal:** automate the three most common account tasks a service desk handles, safely and repeatably, and measure the time saved.

| Script | Does |
|---|---|
| `New-Starter.ps1` | Creates user accounts from a CSV list and puts each in their department OU and group |
| `Remove-Leaver.ps1` | Safely disables a leaver: blocks logon, removes access, records why, moves the account to `Disabled` |
| `Get-StaleAccounts.ps1` | Reports accounts nobody has used recently: a security and licensing check |

**Where to run:** CL01, logged on as `NEBULA\Administrator`. RSAT is already installed there; managing AD from a workstation rather than logging on to the DC is best practice.
**Time:** about 2 hours across sessions.

---

## Key concepts

| Term | Meaning |
|---|---|
| **Joiner / Mover / Leaver (JML)** | The account lifecycle: create for new starters, change for role moves, disable for leavers |
| **CSV** | A simple table in a text file; one row per person |
| **`-WhatIf`** | A dry run: shows what *would* happen, changes nothing. Always run it first |
| **`SupportsShouldProcess`** | The line in a script that adds `-WhatIf` and `-Confirm` support |
| **Comment-based help** | The `<# .SYNOPSIS … #>` block, so `Get-Help .\Script.ps1` explains the script |
| **Execution policy** | Windows' safety setting that controls whether scripts may run |

---

## 0. Prepare (CL01, PowerShell as Administrator)

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser    # allow your own local scripts to run
Import-Module ActiveDirectory                          # AD commands (from RSAT)
New-Item -ItemType Directory -Force C:\Scripts\output | Out-Null
cd C:\Scripts
```
`RemoteSigned` lets locally written scripts run, but blocks unsigned scripts downloaded from the internet. If a script copied from the laptop is refused, run `Unblock-File .\<script>.ps1`.

---

## 1. Fake starter data: `starters.csv`

Create `C:\Scripts\starters.csv`. **Fake names only**: this file goes on GitHub. `Department` must exactly match an OU name: `IT`, `Finance` or `Sales`.

```
FirstName,LastName,Department,Title
Noah,Reed,IT,Support Analyst
Mia,Clarke,IT,Systems Administrator
Ethan,Hughes,Finance,Accountant
Grace,Patel,Finance,Payroll Officer
Oscar,Ward,Sales,Account Manager
Lily,Shaw,Sales,Sales Executive
```
Extend it to **25 rows**: more rows make the time saved more measurable.

---

## 2. `New-Starter.ps1`

```powershell
<#
.SYNOPSIS  Joiner process: creates AD users from a CSV and adds them to their department group.
.EXAMPLE   .\New-Starter.ps1 -CsvPath .\starters.csv -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [string]$Domain = 'ad.nebula.internal',
    [string]$BaseOU = 'OU=Users,OU=Nebula,DC=ad,DC=nebula,DC=internal'
)
Import-Module ActiveDirectory

$results = foreach ($u in Import-Csv $CsvPath) {
    $sam = ($u.FirstName.Substring(0,1) + $u.LastName).ToLower()          # e.g. Ava Stone -> astone
    if (Get-ADUser -Filter "SamAccountName -eq '$sam'") {
        Write-Warning "$sam already exists - skipped"; continue            # never overwrite an existing account
    }
    # Temporary password: 12 random letters/digits + a fixed tail that meets every complexity rule
    $pw = (-join ((65..90)+(97..122)+(48..57) | Get-Random -Count 12 | ForEach-Object {[char]$_})) + '#7aZ'

    $params = @{
        Name                  = "$($u.FirstName) $($u.LastName)"
        GivenName             = $u.FirstName
        Surname               = $u.LastName
        SamAccountName        = $sam
        UserPrincipalName     = "$sam@$Domain"
        Department            = $u.Department
        Title                 = $u.Title
        Path                  = "OU=$($u.Department),$BaseOU"
        AccountPassword       = (ConvertTo-SecureString $pw -AsPlainText -Force)
        ChangePasswordAtLogon = $true
        Enabled               = $true
    }
    if ($PSCmdlet.ShouldProcess($sam, 'Create user')) {
        New-ADUser @params
        Add-ADGroupMember -Identity "GG_$($u.Department)" -Members $sam
        [pscustomobject]@{ User = $sam; Department = $u.Department; TempPassword = $pw }
    }
}
# LAB ONLY: in production, temporary passwords go to the manager through a secure channel, never into a file
$outDir = Join-Path $PSScriptRoot 'output'                              # always next to the script, wherever it's run from
New-Item -ItemType Directory -Force $outDir | Out-Null
$results | Export-Csv (Join-Path $outDir 'new-starters.csv') -NoTypeInformation
$results | Format-Table User, Department
```

| Part | Meaning |
|---|---|
| `$params = @{…}` + `New-ADUser @params` | **Splatting:** passes a table of settings as parameters, which is easier to read than one long line |
| `Path = "OU=$($u.Department),$BaseOU"` | Places each user in their department's OU, so the right GPOs apply |
| `ChangePasswordAtLogon = $true` | The user must set their own password; IT never knows it |
| `continue` | Skip this row and move on to the next |
| `$PSScriptRoot` | The script's own folder. Without it, `.\output` points at the **current** folder: run from ISE, that was `C:\Windows\System32`, and the export failed |

**Run it:**
```powershell
.\New-Starter.ps1 -CsvPath .\starters.csv -WhatIf                   # dry run: read the output
Measure-Command { .\New-Starter.ps1 -CsvPath .\starters.csv }       # real run, timed
```
Note `TotalSeconds` for your CV bullet. For comparison, time yourself creating **one** user by hand in ADUC (including the group), and multiply by 25.

**Check:**
```powershell
Get-ADUser -Filter * -SearchBase 'OU=Users,OU=Nebula,DC=ad,DC=nebula,DC=internal' | Select-Object Name, DistinguishedName
Get-ADGroupMember GG_Finance | Select-Object Name
```

---

## 3. `Remove-Leaver.ps1`

```powershell
<#
.SYNOPSIS  Leaver process: disable, scramble password, remove groups, record reason, move to Disabled OU.
.EXAMPLE   .\Remove-Leaver.ps1 -SamAccountName oward -Ticket 12 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SamAccountName,
    [Parameter(Mandatory)][string]$Ticket,
    [string]$DisabledOU = 'OU=Disabled,OU=Nebula,DC=ad,DC=nebula,DC=internal'
)
Import-Module ActiveDirectory
$u = Get-ADUser $SamAccountName -Properties MemberOf

if ($PSCmdlet.ShouldProcess($SamAccountName, 'Offboard leaver')) {
    Disable-ADAccount $u                                                   # 1. block new logons immediately
    $random = ConvertTo-SecureString ([guid]::NewGuid().ToString() + 'aA1!') -AsPlainText -Force
    Set-ADAccountPassword $u -Reset -NewPassword $random                  # 2. invalidate any known password
    $u.MemberOf | ForEach-Object {
        Remove-ADGroupMember -Identity $_ -Members $u -Confirm:$false }   # 3. remove all access
    Set-ADUser $u -Description "Leaver $(Get-Date -Format yyyy-MM-dd) - GLPI ticket $Ticket"   # 4. audit trail
    Move-ADObject $u.DistinguishedName -TargetPath $DisabledOU            # 5. park it, don't delete
    Write-Output "$SamAccountName offboarded (ticket $Ticket)"
}
```

**Why disable, not delete?** A deleted account can't be audited, and its files and mailbox are harder to recover. Companies keep disabled accounts for a set period (e.g. 30–90 days), then delete them.

**Run it:**
```powershell
.\Remove-Leaver.ps1 -SamAccountName oward -Ticket 12 -WhatIf
.\Remove-Leaver.ps1 -SamAccountName oward -Ticket 12
Get-ADUser oward -Properties Description, MemberOf | Select-Object Enabled, Description, MemberOf, DistinguishedName
```
Expected: `Enabled False`, the description with the date and ticket, `MemberOf` empty, and the account in `OU=Disabled`.

---

## 4. `Get-StaleAccounts.ps1`

```powershell
<#
.SYNOPSIS  Reports enabled users who haven't logged on for N days, never logged on, or whose passwords never expire.
.EXAMPLE   .\Get-StaleAccounts.ps1 -Days 30
#>
param([int]$Days = 30)
Import-Module ActiveDirectory
$cutoff = (Get-Date).AddDays(-$Days)

Get-ADUser -Filter 'Enabled -eq $true' -Properties LastLogonDate, PasswordNeverExpires |
    Where-Object { -not $_.LastLogonDate -or $_.LastLogonDate -lt $cutoff -or $_.PasswordNeverExpires } |
    Select-Object Name, SamAccountName, LastLogonDate, PasswordNeverExpires |
    Tee-Object -Variable report |
    Export-Csv .\output\stale-accounts.csv -NoTypeInformation
$report | Format-Table
```

| Part | Meaning |
|---|---|
| `-not $_.LastLogonDate` | Never logged on: e.g. starters who never started, or forgotten test accounts |
| `PasswordNeverExpires` | A risky setting, often found on old service accounts |
| `Tee-Object` | Saves the results **and** passes them on, so you get the CSV and the screen output |

`LastLogonDate` only updates across DCs every 9–14 days by design. That's fine for a stale-account report, but not for real-time checks.

---

## 5. Save to the repo

Copy into `scripts\` in the repo (drag from CL01 to the laptop, or paste into VS Code):
- `New-Starter.ps1` · `Remove-Leaver.ps1` · `Get-StaleAccounts.ps1`
- `starters.csv` (fake names)
- **Not** `output\`: it contains temporary passwords, and `.gitignore` already excludes it.

```powershell
git status
gitleaks dir .
git add scripts
git commit -m "Add joiner, leaver and stale-account PowerShell scripts"
git push
```

**CV bullet (fill in your measured numbers):**
> Automated joiner/leaver processes in PowerShell, cutting onboarding of 25 users from [x] minutes (manual) to [y] seconds.
