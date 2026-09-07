#Requires -Version 5.1
<#
.SYNOPSIS
  Super-config: before companion startup, choose phone LAN IP from saved config vs current Wi-Fi (USB).

.DESCRIPTION
  Writes phoneLanHostSource ("usb" | "config") in loop-segments-windows.json.
  Companion reads this at startup for lan_config + gateway/recover. Does not change
  phoneLanHost itself.

  Bare run / double-click = toggle usb ↔ config (then wait for Enter).
  usb    = keep the phone's current Wi-Fi IPv4 (USB pcapd); config IP stays as fallback
  config = force saved phoneLanHost (default; PC may be aligned to that subnet)

.EXAMPLE
  .\Set-LoopSegmentsPhoneLanHostSource.ps1
  # toggle

.EXAMPLE
  .\Set-LoopSegmentsPhoneLanHostSource.ps1 -Show

.EXAMPLE
  .\Set-LoopSegmentsPhoneLanHostSource.ps1 -Usb

.EXAMPLE
  .\Set-LoopSegmentsPhoneLanHostSource.ps1 -Config
#>
[CmdletBinding(DefaultParameterSetName = 'Toggle')]
param(
    [Parameter(ParameterSetName = 'Usb')]
    [switch] $Usb,

    [Parameter(ParameterSetName = 'Config')]
    [switch] $Config,

    [Parameter(ParameterSetName = 'Toggle')]
    [switch] $Toggle,

    [Parameter(ParameterSetName = 'Show')]
    [switch] $Show,

    # Skip Enter wait (callers / automation). Direct run / double-click waits by default.
    [switch] $NoWaitEnter
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\lib\Get-LoopSegmentsPwsh.ps1"
Ensure-LoopSegmentsPwshHost -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

. "$PSScriptRoot\..\lib\LoopSegments-Windows.ps1"
Initialize-LoopSegmentsWindowsConfig

function Wait-EnterIfNeeded {
    if ($NoWaitEnter) { return }
    Write-Host ""
    Write-Host 'Press Enter to close...' -ForegroundColor Yellow
    try {
        [void][Console]::ReadLine()
    } catch {
        Read-Host | Out-Null
    }
}

$current = Get-LoopSegmentsPhoneLanHostSource
$didChange = $false

if ($PSCmdlet.ParameterSetName -eq 'Usb' -or $Usb) {
    [void](Set-LoopSegmentsPhoneLanHostSourcePreference -Source usb)
    $current = 'usb'
    $didChange = $true
} elseif ($PSCmdlet.ParameterSetName -eq 'Config' -or $Config) {
    [void](Set-LoopSegmentsPhoneLanHostSourcePreference -Source config)
    $current = 'config'
    $didChange = $true
} elseif ($PSCmdlet.ParameterSetName -eq 'Show' -or $Show) {
    # print only
} else {
    # Default / -Toggle / bare run / double-click
    $next = if ($current -eq 'usb') { 'config' } else { 'usb' }
    [void](Set-LoopSegmentsPhoneLanHostSourcePreference -Source $next)
    $current = $next
    $didChange = $true
}

$settings = Get-LoopSegmentsWindowsSettings
if ($didChange) {
    Write-Host "phoneLanHostSource -> $current" -ForegroundColor Cyan
} else {
    Write-Host "phoneLanHostSource = $current"
}
Write-Host ("  saved phoneLanHost = {0}" -f $(if ($settings.phoneLanHost) { $settings.phoneLanHost } else { '(empty)' }))
if ($current -eq 'usb') {
    Write-Host '  companion startup: use phone current Wi-Fi IP via USB pcapd (does not rewrite phoneLanHost)'
} else {
    Write-Host '  companion startup: force saved phoneLanHost (gateway/recover may align PC to that subnet)'
}
Write-Host 'Options: (bare=toggle) | -Usb | -Config | -Show | -NoWaitEnter'
Wait-EnterIfNeeded
