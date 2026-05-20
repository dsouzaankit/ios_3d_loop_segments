#Requires -Version 5.1
<#
.SYNOPSIS
  Save the iPhone LAN IP for Windows scripts (e.g. Mount-LoopSegmentsRclone.ps1 -TestOnly).

.EXAMPLE
  .\Set-LoopSegmentsLANHost.ps1 192.168.1.42
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $PhoneHost
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\LoopSegments-Windows.ps1"
Initialize-LoopSegmentsWindowsConfig
$settings = Get-LoopSegmentsWindowsSettings
$settings.phoneLanHost = $PhoneHost.Trim()
Save-LoopSegmentsWindowsSettings -Settings $settings
Write-Host "Run: .\Set-LoopSegmentsWindows.ps1 -Show"
Write-Host "     .\Mount-LoopSegmentsRclone.ps1 -TestOnly"
