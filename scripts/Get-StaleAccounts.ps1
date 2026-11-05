<#
.SYNOPSIS  Reports enabled users who haven't logged on for N days, never logged on, or whose passwords never expire.
.EXAMPLE   .\Get-StaleAccounts.ps1 -Days 30
#>
param([int]$Days = 30)
Import-Module ActiveDirectory
$cutoff = (Get-Date).AddDays(-$Days)
$outDir = Join-Path $PSScriptRoot 'output'
New-Item -ItemType Directory -Force $outDir | Out-Null

Get-ADUser -Filter 'Enabled -eq $true' -Properties LastLogonDate, PasswordNeverExpires |
    Where-Object { -not $_.LastLogonDate -or $_.LastLogonDate -lt $cutoff -or $_.PasswordNeverExpires } |
    Select-Object Name, SamAccountName, LastLogonDate, PasswordNeverExpires |
    Tee-Object -Variable report |
    Export-Csv (Join-Path $outDir 'stale-accounts.csv') -NoTypeInformation
$report | Format-Table
