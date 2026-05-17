#Requires -Version 5.1
<#
.SYNOPSIS
  Register a logon scheduled task to sync iPhone segment MKVs over USB into the DLNA folder.

.NOTES
  Run once as your user. After logon, plug in iPhone (trusted), unlock, and the task
  waits up to 10 minutes for both MKVs then copies to F:\f1_media\3d_fullsbs_trans.
#>
[CmdletBinding()]
param(
    [string] $DestinationDirectory = 'F:\f1_media\3d_fullsbs_trans',
    [string] $TaskName = 'LoopSegments-UsbSync'
)

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'Sync-IphoneSegments.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Missing: $scriptPath"
}

$arg = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -WaitForDevice -WaitMinutes 10 -DestinationDirectory `"$DestinationDirectory`""
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Write-Host "Registered scheduled task: $TaskName"
Write-Host "On logon, sync runs when iPhone USB + Exports are available."
