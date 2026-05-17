#Requires -Version 5.1
<#
.SYNOPSIS
  Poll the Apple Devices save folder and copy segments to the DLNA library automatically.

.DESCRIPTION
  Apple Devices only lets you pick a Windows output folder manually.
  This automates the NEXT step: copy from that folder to F:\f1_media\...

.PARAMETER RegisterLogonTask
  Start polling at Windows logon (background, every -PollSeconds).

.EXAMPLE
  .\Watch-LoopSegmentsIncoming.ps1 -RegisterLogonTask

.EXAMPLE
  .\Watch-LoopSegmentsIncoming.ps1 -PollSeconds 15
#>
[CmdletBinding()]
param(
    [string] $IncomingDirectory = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'LoopSegmentsIncoming'),
    [string] $DestinationDirectory = 'F:\f1_media\3d_fullsbs_trans',
    [int] $PollSeconds = 30,
    [switch] $RegisterLogonTask,
    [string] $TaskName = 'LoopSegments-WatchIncoming'
)

$ErrorActionPreference = 'Stop'
$copyScript = Join-Path $PSScriptRoot 'Copy-FromIncoming.ps1'

if (-not (Test-Path -LiteralPath $copyScript)) {
    throw "Missing: $copyScript"
}
if (-not (Test-Path -LiteralPath $IncomingDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $IncomingDirectory -Force | Out-Null
}

$incoming = [System.IO.Path]::GetFullPath($IncomingDirectory)

if ($RegisterLogonTask) {
    $arg = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', "`"$PSCommandPath`"",
        '-IncomingDirectory', "`"$incoming`"",
        '-DestinationDirectory', "`"$DestinationDirectory`"",
        '-PollSeconds', $PollSeconds
    ) -join ' '
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Write-Host "Registered: $TaskName (every $PollSeconds s at logon)"
    Write-Host "Save Apple Devices exports to: $incoming"
    Write-Host "Auto-copy to: $DestinationDirectory"
    return
}

Write-Host "Polling every $PollSeconds s"
Write-Host "Incoming: $incoming"
Write-Host "DLNA:     $DestinationDirectory"
Write-Host "Save from Apple Devices into incoming; Ctrl+C to stop."

while ($true) {
    & $copyScript -IncomingDirectory $incoming -DestinationDirectory $DestinationDirectory
    Start-Sleep -Seconds $PollSeconds
}
