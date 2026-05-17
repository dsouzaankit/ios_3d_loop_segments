#Requires -Version 5.1
<#
.SYNOPSIS
  Register a logon scheduled task to copy iPhone segments into the DLNA folder.

.NOTES
  Apple Devices does not auto-sync app folders. This task runs Sync-IphoneSegments.ps1
  at Windows logon (waits for USB + Exports). Save the Exports path first:

    .\Set-LoopSegmentsSource.ps1 '<path from Apple Devices / Explorer>'

  Or pass -SourceRoot here once (writes the config file).
#>
[CmdletBinding()]
param(
    [string] $DestinationDirectory = 'F:\f1_media\3d_fullsbs_trans',
    [string] $SourceRoot = '',
    [string] $TaskName = 'LoopSegments-UsbSync',
    [int] $WaitMinutes = 10
)

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'Sync-IphoneSegments.ps1'
$setSourcePath = Join-Path $PSScriptRoot 'Set-LoopSegmentsSource.ps1'

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Missing: $scriptPath"
}

if (-not [string]::IsNullOrWhiteSpace($SourceRoot)) {
    & $setSourcePath -ExportsPath $SourceRoot
}

$configFile = Join-Path $PSScriptRoot 'loop-segments-source.txt'
if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
    Write-Warning @"
No saved Exports path ($configFile).
Run once (phone connected, Exports visible in Apple Devices):

  .\Set-LoopSegmentsSource.ps1

Then re-run:

  .\Register-UsbSyncTask.ps1
"@
}

$arg = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -WaitForDevice -WaitMinutes $WaitMinutes -DestinationDirectory `"$DestinationDirectory`""
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Write-Host "Registered scheduled task: $TaskName"
Write-Host "On logon: waits up to $WaitMinutes min for iPhone USB + Exports, then copies to $DestinationDirectory"
Write-Host "Manual run anytime: .\Sync-IphoneSegments.ps1 -WaitForDevice"
