#Requires -Version 5.1
<#
.SYNOPSIS
  Save the iPhone LAN IP for Mount-LoopSegmentsRclone.ps1.

.EXAMPLE
  .\Set-LoopSegmentsLANHost.ps1 192.168.1.42
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $PhoneHost
)

$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'loop-segments-lan-host.txt'
$PhoneHost.Trim() | Set-Content -LiteralPath $path -Encoding UTF8 -NoNewline
Write-Host "Saved LAN host: $PhoneHost"
Write-Host "Config: $path"
Write-Host "Run: .\Mount-LoopSegmentsRclone.ps1"
Write-Host "Legacy copy scripts: .\archive\"
