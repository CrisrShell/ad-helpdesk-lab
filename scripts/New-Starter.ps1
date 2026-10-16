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
    $sam = ($u.FirstName.Substring(0,1) + $u.LastName).ToLower()          # e.g. Ava Stone → astone
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
$results | Export-Csv .\output\new-starters.csv -NoTypeInformation
$results | Format-Table User, Department
