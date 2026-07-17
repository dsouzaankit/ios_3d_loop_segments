#Requires -Version 5.1
<#
.SYNOPSIS
  Press the iPhone Home button over USB (background / "minimize" the foreground app).

.DESCRIPTION
  Uses pymobiledevice3 developer core-device hid button home.
  Intended after Run-PCloudWebCompanion finishes so Loop Segments leaves the
  foreground while Keep Alive / LAN can keep running.

  By default, skips Home when phone LAN status.json reports an active export
  (backgrounding without a healthy Keep Alive session can pause/interrupt export).
  Use -ForceGoHome to press anyway.

.EXITCODES
  0  Home pressed (or best-effort succeeded)
  1  Tooling / generic failure
  2  No USB device
  3  Phone locked
  4  Skipped — export active on LAN (use -ForceGoHome to override)

.EXAMPLE
  .\Go-IphoneHomeViaUsb.ps1

.EXAMPLE
  .\Go-IphoneHomeViaUsb.ps1 -ForceGoHome
#>
[CmdletBinding()]
param(
    [switch] $UseTunneld,
    [switch] $ForceGoHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PythonHelper = Join-Path $PSScriptRoot "Get-LoopSegmentsPython.ps1"
if (-not (Test-Path -LiteralPath $PythonHelper)) {
    throw "Missing shared Python helper: $PythonHelper"
}
. $PythonHelper

function Invoke-PythonRuntime {
    param(
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] [string[]] $ArgumentList
    )
    Invoke-LoopSegmentsPythonRuntime -Runtime $Runtime -ArgumentList $ArgumentList
}

function Get-PhoneLanEndpoint {
    $candidates = @(
        (Join-Path $PSScriptRoot "pcloud_web_companion\lan_config.json"),
        (Join-Path $env:LOCALAPPDATA "pcloud_web_companion\extension\lan_config.json"),
        (Join-Path $PSScriptRoot "loop-segments-windows.json")
    )
    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $cfg = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        } catch {
            continue
        }
        $hostName = [string]$cfg.phoneLanHost
        if ([string]::IsNullOrWhiteSpace($hostName)) { continue }
        $port = 8765
        if ($null -ne $cfg.lanPort -and [int]$cfg.lanPort -gt 0) {
            $port = [int]$cfg.lanPort
        }
        return @{ Host = $hostName.Trim(); Port = $port; Source = $path }
    }
    return $null
}

function Test-ShouldSkipHomeForActiveExport {
    param([hashtable] $Endpoint)
    if ($null -eq $Endpoint) { return $false }
    $uri = "http://$($Endpoint.Host):$($Endpoint.Port)/status.json"
    try {
        $resp = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 3
        if ($resp.StatusCode -lt 200 -or $resp.StatusCode -ge 500) { return $false }
        $j = $resp.Content | ConvertFrom-Json
    } catch {
        return $false
    }

    $names = @($j.PSObject.Properties.Name)
    $exportActive = $false
    if ($names -contains "exportActive" -and $j.exportActive -eq $true) { $exportActive = $true }
    elseif ($names -contains "manualRefresh" -and $j.manualRefresh -eq $true) { $exportActive = $true }
    elseif ($null -ne $j.lanLive) { $exportActive = $true }
    elseif ($null -ne $j.exportSource -and [string]$j.exportSource.phase -eq "running") { $exportActive = $true }

    if (-not $exportActive) { return $false }

    # Build 273+: Home is OK when Keep Alive audio is actually playing.
    if ($names -contains "keepAliveActive" -and $j.keepAliveActive -eq $true) {
        Write-Host "[home] Export active and Keep Alive playing — Home is OK"
        return $false
    }
    return $true
}

$rt = Get-LoopSegmentsPythonRuntime
if (-not $rt) {
    throw @"
Python not found (need 3.9-3.13; prefer 3.12).

$(Get-LoopSegmentsPythonInstallHint)
"@
}

$importCheck = Invoke-PythonRuntime -Runtime $rt -ArgumentList @(
    "-c", "import pymobiledevice3; print('import-ok')"
)
if ($importCheck.ExitCode -ne 0 -or ($importCheck.Lines -join " ") -notmatch "import-ok") {
    throw "pymobiledevice3 not installed for $($rt.Display). $(Get-LoopSegmentsPythonInstallHint)"
}

if (-not $ForceGoHome) {
    $endpoint = Get-PhoneLanEndpoint
    if ($null -ne $endpoint -and (Test-ShouldSkipHomeForActiveExport -Endpoint $endpoint)) {
        Write-Host "[home] Export active on $($endpoint.Host):$($endpoint.Port) — skip Home (Keep Alive not confirmed playing)." -ForegroundColor Yellow
        Write-Host "[home] Leave Loop Segments foreground, install build 273+, or use -ForceGoHome." -ForegroundColor Yellow
        exit 4
    }
}

$list = Invoke-PythonRuntime -Runtime $rt -ArgumentList @("-m", "pymobiledevice3", "usbmux", "list")
$listText = ($list.Lines -join "`n")
if ($list.ExitCode -ne 0 -or $listText -match '(?s)^\s*\[\s*\]\s*$' -or $listText -match '(?i)no devices?') {
    Write-Host "[home] No USB iPhone - skip Home press" -ForegroundColor Yellow
    exit 2
}

$attempts = @()
if ($UseTunneld) {
    $attempts += , @{ Label = "hid button home --tunnel ''"; CliArgs = @("developer", "core-device", "hid", "button", "home", "--tunnel", "") }
}
$attempts += , @{ Label = "hid button home --userspace"; CliArgs = @("developer", "core-device", "hid", "button", "home", "--userspace") }
$attempts += , @{ Label = "hid button home"; CliArgs = @("developer", "core-device", "hid", "button", "home") }

foreach ($attempt in $attempts) {
    Write-Host "[home] Trying $($attempt.Label)..."
    $result = Invoke-PythonRuntime -Runtime $rt -ArgumentList (@("-m", "pymobiledevice3") + $attempt.CliArgs)
    foreach ($line in $result.Lines) { if ($line) { Write-Host $line } }
    $blob = ($result.Lines -join "`n")
    if ($result.ExitCode -eq 0 -and $blob -notmatch "Traceback|DTXNsError|CoreDeviceError|PasswordRequired") {
        Write-Host "[home] Home pressed - Loop Segments should be backgrounded." -ForegroundColor Green
        exit 0
    }
    if ($blob -match "PasswordRequired|PasswordProtected|device is locked|phone is locked") {
        Write-Host "[home] Phone locked - cannot press Home." -ForegroundColor Yellow
        exit 3
    }
}

Write-Host "[home] Home press failed (USB / Developer Mode / tunnel). Leave the app as-is." -ForegroundColor Yellow
exit 1
