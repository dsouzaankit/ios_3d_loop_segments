#Requires -Version 5.1
<#
.SYNOPSIS
  Start integrated pcloud_web_companion Chromium helper (USB-launches Loop Segments first).

.DESCRIPTION
  Wrapper around windows\pcloud_web_companion\run_chromium.ps1.
  Before Chromium starts, runs Launch-LoopSegmentsViaUsb.ps1.
  Exit code 3 (phone locked) or other USB launch failures abort Chromium.

.EXAMPLE
  .\Run-PCloudWebCompanion.ps1

.EXAMPLE
  .\Run-PCloudWebCompanion.ps1 -SkipUsbLaunch
#>
[CmdletBinding()]
param(
    [switch] $RecreateVenv,
    [switch] $ForceDeps,
    [switch] $NoLaunch,
    [switch] $SkipUsbLaunch,
    [switch] $UsbLaunchMount,
    [switch] $SkipProfileSync,
    [switch] $DetachChromium,
    [string] $StartUrl = "https://my.pcloud.com"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$target = Join-Path $PSScriptRoot "pcloud_web_companion\run_chromium.ps1"
if (-not (Test-Path -LiteralPath $target)) {
    throw "Missing $target"
}

$forward = @{
    RecreateVenv     = $RecreateVenv
    ForceDeps        = $ForceDeps
    NoLaunch         = $NoLaunch
    SkipUsbLaunch    = $SkipUsbLaunch
    UsbLaunchMount   = $UsbLaunchMount
    SkipProfileSync  = $SkipProfileSync
    DetachChromium   = $DetachChromium
    StartUrl         = $StartUrl
}

& $target @forward
exit $LASTEXITCODE
