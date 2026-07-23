#Requires -Version 5.1
<#
.SYNOPSIS
  Force-open Loop Segments on a USB-connected iPhone via pymobiledevice3.

.DESCRIPTION
  Uses Apple lockdown / DVT (same family of tooling as Xcode), not LAN and not
  pcloud_web_companion. Phone must be plugged in over USB, trusted, and visible to
  iTunes / Apple Mobile Device Support.

  Bundle ID: com.loopsegments.app (AltStore/Sideloadly may append a team
  suffix, e.g. com.loopsegments.app.5FYG76BYQL - this script auto-detects).

  Prefer Python 3.9-3.12 (prebuilt wheels). Python 3.14 often fails to install
  pymobiledevice3 without Microsoft C++ Build Tools.

  One-time phone setup (iOS 16+):
    Settings -> Privacy & Security -> Developer Mode -> On (reboot if prompted)
    Then from this PC (USB connected):
      py -3.12 -m pymobiledevice3 amfi enable-developer-mode
      py -3.12 -m pymobiledevice3 mounter auto-mount

  Install tool once:
      py -3.12 -m pip install -U pymobiledevice3

  iOS 17+: launch tries --userspace tunnel first (no admin). If that fails,
  start an elevated tunneld in another window:
      py -3.12 -m pymobiledevice3 remote tunneld
  then re-run this script with -UseTunneld.

.PARAMETER BundleId
  App bundle id (default com.loopsegments.app).

.PARAMETER SkipMount
  Do not run mounter auto-mount before launch.

.PARAMETER UseTunneld
  Pass --tunnel '' so DVT uses a running pymobiledevice3 remote tunneld.

.PARAMETER ListOnly
  Only list USB devices; do not launch.

.PARAMETER SkipUnlockProbe
  Do not run Probe-IphoneUnlock.py before launch.

.EXITCODES
  0  Launched (or ListOnly ok)
  1  Launch/trust/generic failure
  2  No USB device / app not found
  3  Phone is passcode-locked (unlock and retry)

.EXAMPLE
  .\Launch-LoopSegmentsViaUsb.ps1

.EXAMPLE
  .\Launch-LoopSegmentsViaUsb.ps1 -UseTunneld
#>
[CmdletBinding()]
param(
    [string] $BundleId = "com.loopsegments.app",
    [switch] $SkipMount,
    [switch] $UseTunneld,
    [switch] $ListOnly,
    [switch] $SkipUnlockProbe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PythonHelper = Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Get-LoopSegmentsPython.ps1"
if (-not (Test-Path -LiteralPath $PythonHelper)) {
    throw "Missing shared Python helper: $PythonHelper"
}
. $PythonHelper

$AltServerHelper = Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Get-LoopSegmentsAltServer.ps1"
if (-not (Test-Path -LiteralPath $AltServerHelper)) {
    throw "Missing shared AltServer helper: $AltServerHelper"
}
. $AltServerHelper

function Get-PythonRuntime {
    Get-LoopSegmentsPythonRuntime
}

function Invoke-PythonRuntime {
    param(
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] [string[]] $ArgumentList
    )
    Invoke-LoopSegmentsPythonRuntime -Runtime $Runtime -ArgumentList $ArgumentList
}

function Write-CommandLines {
    param([string[]] $Lines)
    foreach ($line in $Lines) {
        if ($line) { Write-Host $line }
    }
}

function Invoke-Pymobile {
    param(
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] [string[]] $CliArgs,
        [switch] $AllowFail
    )
    Write-Host ("> $($Runtime.Display) -m pymobiledevice3 " + ($CliArgs -join " ")) -ForegroundColor DarkGray
    $result = Invoke-PythonRuntime -Runtime $Runtime -ArgumentList (@("-m", "pymobiledevice3") + $CliArgs)
    Write-CommandLines -Lines $result.Lines
    if (-not $AllowFail -and $result.ExitCode -ne 0) {
        throw "pymobiledevice3 exited $($result.ExitCode)"
    }
    return $result.ExitCode
}

$rt = Get-PythonRuntime
if (-not $rt) {
    throw @"
Python not found (need 3.9-3.13; prefer 3.12).

$(Get-LoopSegmentsPythonInstallHint)
"@
}

Write-Host "Using $($rt.Display) ($($rt.Exe))"
$importCheck = Invoke-PythonRuntime -Runtime $rt -ArgumentList @(
    "-c",
    "import pymobiledevice3; print('import-ok')"
)
if ($importCheck.ExitCode -ne 0 -or ($importCheck.Lines -join " ") -notmatch "import-ok") {
    Write-CommandLines -Lines $importCheck.Lines
    throw @"
pymobiledevice3 not installed for $($rt.Display).

$(Get-LoopSegmentsPythonInstallHint)
"@
}
Write-Host "pymobiledevice3 import OK"

# Always surface AltServer install status (7-day AltStore cert depends on it).
[void](Write-LoopSegmentsAltServerNotice -AlwaysStatus)

function Invoke-UsbmuxList {
    Write-Host "Listing USB / usbmux devices..."
    Write-Host ("> $($rt.Display) -m pymobiledevice3 usbmux list") -ForegroundColor DarkGray
    $result = Invoke-PythonRuntime -Runtime $rt -ArgumentList @("-m", "pymobiledevice3", "usbmux", "list")
    Write-CommandLines -Lines $result.Lines
    return $result
}

$list = Invoke-UsbmuxList
if (-not (Test-LoopSegmentsUsbmuxListHasDevice -ExitCode $list.ExitCode -Lines $list.Lines)) {
    Write-Host ""
    Write-Host "iPhone USB detection failed (no usbmux device)." -ForegroundColor Yellow
    Write-Host "Trying AltServer start/ensure, then one retry..." -ForegroundColor Yellow
    [void](Start-LoopSegmentsAltServer -WaitSeconds 4)
    Start-Sleep -Seconds 2
    $list = Invoke-UsbmuxList
    if (-not (Test-LoopSegmentsUsbmuxListHasDevice -ExitCode $list.ExitCode -Lines $list.Lines)) {
        Write-Host @"

usbmux still empty. Plug in USB, unlock, Trust This Computer, keep Apple Mobile Device Support running.
If AltServer is missing, install it from https://altstore.io — without weekly AltStore refresh,
Loop Segments (free/Personal Team) stops working after ~7 days.

$(Get-LoopSegmentsAppUnavailableResolution)

"@ -ForegroundColor Yellow
        [void](Write-LoopSegmentsAltServerNotice)
        exit 2
    }
    Write-Host "USB device visible after AltServer recovery." -ForegroundColor Green
}

if ($ListOnly) { return }

if (-not $SkipUnlockProbe) {
    $probeScript = Join-Path $PSScriptRoot "Probe-IphoneUnlock.py"
    if (Test-Path -LiteralPath $probeScript) {
        Write-Host "Checking phone unlock state..."
        $probe = Invoke-PythonRuntime -Runtime $rt -ArgumentList @($probeScript)
        Write-CommandLines -Lines $probe.Lines
        if ($probe.ExitCode -eq 3 -or (($probe.Lines -join "`n") -match "PHONE_LOCKED|PasswordRequired")) {
            Write-Host @"

Phone is LOCKED (passcode). Unlock the iPhone, leave it on the Home Screen, then retry.
Chromium / pcloud_web_companion will not start until this succeeds (exit code 3).

"@ -ForegroundColor Yellow
            exit 3
        }
        if ($probe.ExitCode -eq 2) {
            exit 2
        }
    }
}

# Resolve installed bundle id (AltStore appends .TEAMID to CFBundleIdentifier).
$resolveScript = Join-Path $PSScriptRoot "Resolve-LoopSegmentsBundleId.py"
if (-not (Test-Path -LiteralPath $resolveScript)) {
    throw "Missing $resolveScript"
}

Write-Host "Resolving installed bundle id for '$BundleId'..."
$resolve = Invoke-PythonRuntime -Runtime $rt -ArgumentList @($resolveScript, $BundleId)
Write-CommandLines -Lines $resolve.Lines
if ($resolve.ExitCode -ne 0) {
    Write-Host "Loop Segments not found on device. Install/refresh via AltStore, then retry." -ForegroundColor Yellow
    Write-Host (Get-LoopSegmentsAppUnavailableResolution) -ForegroundColor Yellow
    [void](Write-LoopSegmentsAltServerNotice -AlwaysStatus)
    exit 2
}
$resolvedBundleId = (
    $resolve.Lines |
        Where-Object { $_ -and ($_ -notmatch "^(CANDIDATE|NOT_FOUND|Traceback|  File )") -and ($_ -match '^[\w.]+$') } |
        Select-Object -Last 1
)
if (-not $resolvedBundleId) {
    throw "Could not resolve bundle id."
}
if ($resolvedBundleId -ne $BundleId) {
    Write-Host "Using installed id: $resolvedBundleId (AltStore/Sideloadly suffix)" -ForegroundColor Cyan
}
$BundleId = $resolvedBundleId

if (-not $SkipMount) {
    $mounted = $false
    $listMount = Invoke-PythonRuntime -Runtime $rt -ArgumentList @(
        "-m", "pymobiledevice3", "mounter", "list"
    )
    $mountText = $listMount.Lines -join "`n"
    if ($listMount.ExitCode -eq 0 -and $mountText -match '"IsMounted"\s*:\s*true') {
        $mounted = $true
        Write-Host "Developer Disk Image already mounted - skipping auto-mount."
    }
    if (-not $mounted) {
        Write-Host "Mounting Developer Disk Image (auto-mount)..."
        $mountResult = Invoke-PythonRuntime -Runtime $rt -ArgumentList @(
            "-m", "pymobiledevice3", "mounter", "auto-mount"
        )
        Write-CommandLines -Lines $mountResult.Lines
        $mountBlob = $mountResult.Lines -join "`n"
        if ($mountBlob -match "already mounted") {
            Write-Host "Developer Disk Image already mounted (ok)."
        } elseif ($mountResult.ExitCode -ne 0) {
            Write-Host "auto-mount failed (exit $($mountResult.ExitCode)); continuing - try -SkipMount if DDI is up." -ForegroundColor Yellow
        }
    }
}

$launchAttempts = @()
if ($UseTunneld) {
    $launchAttempts += , @{
        Label   = "core-device launch-application --tunnel ''"
        CliArgs = @("developer", "core-device", "launch-application", $BundleId, "_", "--tunnel", "")
    }
    $launchAttempts += , @{
        Label   = "dvt launch --tunnel ''"
        CliArgs = @("developer", "dvt", "launch", $BundleId, "--tunnel", "")
    }
}
$launchAttempts += , @{
    Label   = "core-device launch-application --userspace"
    CliArgs = @("developer", "core-device", "launch-application", $BundleId, "_", "--userspace")
}
$launchAttempts += , @{
    Label   = "dvt launch --userspace"
    CliArgs = @("developer", "dvt", "launch", $BundleId, "--userspace")
}
$launchAttempts += , @{
    Label   = "dvt launch"
    CliArgs = @("developer", "dvt", "launch", $BundleId)
}

$ok = $false
$lastErr = 0
$allOutput = New-Object System.Collections.Generic.List[string]
foreach ($attempt in $launchAttempts) {
    Write-Host "Trying $($attempt.Label)..."
    $result = Invoke-PythonRuntime -Runtime $rt -ArgumentList (@("-m", "pymobiledevice3") + $attempt.CliArgs)
    Write-CommandLines -Lines $result.Lines
    foreach ($line in $result.Lines) { [void]$allOutput.Add($line) }
    $lastErr = $result.ExitCode
    $joined = ($result.Lines -join "`n")
    if ($result.ExitCode -eq 0 -and $joined -notmatch "Traceback|DTXNsError|CoreDeviceError|failed to launch|RequestDenied|Request to launch") {
        $ok = $true
        break
    }
    if ($joined -match "Process launched with pid") {
        $ok = $true
        break
    }
}

if (-not $ok) {
    $blob = $allOutput -join "`n"
    Write-Host ""
    if ($blob -match "PasswordRequired|PasswordProtected|enter password|device is locked|phone is locked|please unlock") {
        Write-Host @"
Phone appears LOCKED during launch. Unlock the iPhone and retry.
Exit code 3 (pcloud_web_companion / Chromium will not start).

Bundle id used: $BundleId
"@ -ForegroundColor Yellow
        exit 3
    }
    if ($blob -match "not been explicitly trusted|invalid code signature|inadequate entitlements|FBSOpenApplicationErrorDomain|RequestDenied") {
        Write-Host @"
Launch blocked by iOS trust/signature (not a USB/script bug). App may be past the ~7-day sideload window.

$(Get-LoopSegmentsAppUnavailableResolution)

Bundle id used: $BundleId
"@ -ForegroundColor Yellow
        [void](Write-LoopSegmentsAltServerNotice -AlwaysStatus)
    } else {
        Write-Host @"
Launch failed (last exit $lastErr). Check:

  1. Phone unlocked; USB Trusted.
  2. Developer Mode On (Settings -> Privacy & Security).
  3. Developer cert trusted (Settings -> General -> VPN & Device Management).
  4. If the app became unavailable (~7-day expiry), use the resolution below.
  5. iOS 17+: elevated $($rt.Display) -m pymobiledevice3 remote tunneld
     then .\Launch-LoopSegmentsViaUsb.ps1 -UseTunneld -SkipMount

$(Get-LoopSegmentsAppUnavailableResolution)

Bundle id used: $BundleId
"@ -ForegroundColor Yellow
        [void](Write-LoopSegmentsAltServerNotice -AlwaysStatus)
    }
    exit 1
}

Write-Host "Launched $BundleId." -ForegroundColor Green
