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
