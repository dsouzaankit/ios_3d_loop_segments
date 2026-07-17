#Requires -Version 5.1
<#
.SYNOPSIS
  Press the iPhone Home button over USB (background / "minimize" the foreground app).

.DESCRIPTION
  Uses pymobiledevice3 developer core-device hid button home.
  Intended after Run-PCloudWebCompanion finishes so Loop Segments leaves the
  foreground while Keep Alive / LAN can keep running.

.EXITCODES
  0  Home pressed (or best-effort succeeded)
  1  Tooling / generic failure
  2  No USB device
  3  Phone locked

.EXAMPLE
  .\Go-IphoneHomeViaUsb.ps1
#>
[CmdletBinding()]
param(
    [switch] $UseTunneld
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
