#Requires -Version 5.1
<#
.SYNOPSIS
  Background Loop Segments over USB (Home / SpringBoard / Settings).

.DESCRIPTION
  Background Loop Segments after Run-PCloudWebCompanion finishes so Keep Alive /
  LAN can keep running. Skips the Home simulation when the app is already not
  foreground (including lock screen). Prefer DVT --userspace (same path as USB
  launch). core-device hid --userspace often times out on the iOS 26 RSD
  handshake and dumps a typer traceback; that attempt is skipped unless
  -TryUserspaceHid.

  Each pymobiledevice3 attempt has a hard timeout (default 25s). Without that,
  hid/userspace can hang forever and leave the companion stuck on finish.

.EXITCODES
  0  Home pressed, or skipped (already backgrounded / lock screen)
  1  Tooling / generic failure
  2  No USB device
  3  Phone locked during a Home attempt (lock at start skips as 0)

.EXAMPLE
  .\Go-IphoneHomeViaUsb.ps1
#>
[CmdletBinding()]
param(
    [switch] $UseTunneld,
    [switch] $TryUserspaceHid,
    [int] $AttemptTimeoutSec = 25,
    [switch] $NoWaitEnter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Wait-EnterToClose {
    if ($NoWaitEnter) { return }
    Write-Host ""
    Write-Host "Press Enter to close..." -ForegroundColor Yellow
    try {
        [void][Console]::ReadLine()
    } catch {
        Read-Host | Out-Null
    }
}

function Exit-Home {
    param([int] $ExitCode)
    # 0 = ok, 2 = no USB (skip). Error/locked pause unless -NoWaitEnter (companion prompts).
    if ($ExitCode -ne 0 -and $ExitCode -ne 2) {
        Wait-EnterToClose
    }
    exit $ExitCode
}

$PythonHelper = Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Get-LoopSegmentsPython.ps1"
if (-not (Test-Path -LiteralPath $PythonHelper)) {
    throw "Missing shared Python helper: $PythonHelper"
}
. $PythonHelper

function Stop-ProcessTree {
    param([int] $ProcessId)
    if ($ProcessId -le 0) { return }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & taskkill.exe /PID $ProcessId /T /F 2>&1 | Out-Null
    } catch {}
    finally {
        $ErrorActionPreference = $prev
    }
}

function Invoke-PythonRuntimeTimed {
    param(
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] [string[]] $ArgumentList,
        [Parameter(Mandatory = $true)] [int] $TimeoutSec
    )

    $all = @($Runtime.Prefix) + $ArgumentList
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Runtime.Exe
    # Quote args that need it
    $psi.Arguments = (($all | ForEach-Object {
                $a = [string]$_
                if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
            }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $timeoutMs = [Math]::Max(1, $TimeoutSec) * 1000
    if (-not $proc.WaitForExit($timeoutMs)) {
        Write-Host "[home] Timed out after ${TimeoutSec}s - killing pymobiledevice3 (PID $($proc.Id))" -ForegroundColor Yellow
        Stop-ProcessTree -ProcessId $proc.Id
        try { [void]$proc.WaitForExit(5000) } catch {}
        return [pscustomobject]@{
            ExitCode = 124
            Lines    = @("[home] attempt timed out after ${TimeoutSec}s")
            TimedOut = $true
        }
    }
    $stdout = $outTask.GetAwaiter().GetResult()
    $stderr = $errTask.GetAwaiter().GetResult()
    $lines = @()
    foreach ($chunk in @($stdout, $stderr)) {
        if ([string]::IsNullOrWhiteSpace($chunk)) { continue }
        $lines += ($chunk -split "`r?`n" | Where-Object { $_ -ne "" })
    }
    return [pscustomobject]@{
        ExitCode = [int]$proc.ExitCode
        Lines    = $lines
        TimedOut = $false
    }
}

function Write-HomeCommandLines {
    param([string[]] $Lines)
    foreach ($line in $Lines) {
        if ($line) { Write-Host $line }
    }
}

function Write-HomeAttemptOutput {
    param(
        [string[]] $Lines,
        [switch] $CollapseIfFailed
    )
    if (-not $CollapseIfFailed) {
        Write-HomeCommandLines -Lines $Lines
        return
    }
    $blob = @($Lines) -join "`n"
    if ($blob -notmatch 'Traceback \(most recent call last\)') {
        Write-HomeCommandLines -Lines $Lines
        return
    }
    $err = @(
        $Lines | Where-Object { $_ -match '^(TimeoutError|ConnectionError|OSError|RuntimeError|ProtocolError)\b' }
    ) | Select-Object -Last 1
    if (-not $err -and $blob -match 'TimeoutError') { $err = 'TimeoutError' }
    if (-not $err) { $err = 'pymobiledevice3 error' }
    Write-Host ("  skipped ({0}) — trying next home method." -f $err.Trim()) -ForegroundColor DarkGray
}

function Test-IphonePasscodeLocked {
    param(
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] [int] $TimeoutSec
    )
    $probePy = Join-Path $PSScriptRoot "Probe-IphoneUnlock.py"
    if (-not (Test-Path -LiteralPath $probePy)) { return $null }
    $probe = Invoke-PythonRuntimeTimed -Runtime $Runtime -ArgumentList @(
        $probePy
    ) -TimeoutSec $TimeoutSec
    $blob = ($probe.Lines -join "`n")
    if ($probe.ExitCode -eq 3 -or $blob -match 'PHONE_LOCKED|PasswordRequired') { return $true }
    if ($probe.ExitCode -eq 0 -or $blob -match '(?m)^UNLOCKED\b') { return $false }
    return $null
}

function Test-LoopSegmentsStillForeground {
    param(
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] [int] $TimeoutSec
    )
    $probePy = Join-Path $PSScriptRoot "Probe-LoopSegmentsForeground.py"
    if (-not (Test-Path -LiteralPath $probePy)) { return $null }
    $probe = Invoke-PythonRuntimeTimed -Runtime $Runtime -ArgumentList @(
        $probePy, "com.loopsegments.app"
    ) -TimeoutSec $TimeoutSec
    $blob = ($probe.Lines -join "`n")
    if ($blob -match '(?m)^FOREGROUND\b') { return $true }
    if ($blob -match '(?m)^NOT_FOREGROUND\b') { return $false }
    return $null
}

$rt = Get-LoopSegmentsPythonRuntime
if (-not $rt) {
    throw @"
Python not found (need 3.9-3.13; prefer 3.12).

$(Get-LoopSegmentsPythonInstallHint)
"@
}

$importCheck = Invoke-PythonRuntimeTimed -Runtime $rt -ArgumentList @(
    "-c", "import pymobiledevice3; print('import-ok')"
) -TimeoutSec ([Math]::Min(20, $AttemptTimeoutSec))
if ($importCheck.ExitCode -ne 0 -or ($importCheck.Lines -join " ") -notmatch "import-ok") {
    throw "pymobiledevice3 not installed for $($rt.Display). $(Get-LoopSegmentsPythonInstallHint)"
}

$list = Invoke-PythonRuntimeTimed -Runtime $rt -ArgumentList @(
    "-m", "pymobiledevice3", "usbmux", "list"
) -TimeoutSec ([Math]::Min(20, $AttemptTimeoutSec))
$listText = ($list.Lines -join "`n")
if ($list.ExitCode -ne 0 -or $listText -match '(?s)^\s*\[\s*\]\s*$' -or $listText -match '(?i)no devices?') {
    Write-Host "[home] No USB iPhone - skip Home press" -ForegroundColor Yellow
    Exit-Home 2
}

$probeTimeout = [Math]::Min(20, $AttemptTimeoutSec)
$locked = Test-IphonePasscodeLocked -Runtime $rt -TimeoutSec $probeTimeout
if ($locked -eq $true) {
    Write-Host "[home] Phone locked (app already backgrounded) - skip Home press" -ForegroundColor DarkGray
    Exit-Home 0
}
$alreadyFg = Test-LoopSegmentsStillForeground -Runtime $rt -TimeoutSec $probeTimeout
if ($alreadyFg -eq $false) {
    Write-Host "[home] Loop Segments already backgrounded - skip Home press" -ForegroundColor DarkGray
    Exit-Home 0
}
if ($alreadyFg -eq $true) {
    Write-Host "[home] Loop Segments is foreground - simulating Home..."
}

# HID without --userspace/--tunnel requires tunneld (RSDServiceProviderDep).
# HID --userspace hits the same iOS 26 RSD handshake TimeoutError as
# core-device launch; DVT --userspace is the path that already works.
$attempts = @()
if ($UseTunneld) {
    $attempts += , @{
        Label   = "hid button home --tunnel ''"
        Kind    = "hid"
        CliArgs = @("developer", "core-device", "hid", "button", "home", "--tunnel", "")
    }
}
$attempts += , @{
    Label   = "dvt launch --userspace SpringBoard"
    Kind    = "dvt"
    CliArgs = @("developer", "dvt", "launch", "com.apple.springboard", "--no-kill-existing", "--userspace")
}
$attempts += , @{
    Label   = "dvt launch SpringBoard"
    Kind    = "dvt"
    CliArgs = @("developer", "dvt", "launch", "com.apple.springboard", "--no-kill-existing")
}
$attempts += , @{
    Label   = "dvt launch --userspace Settings (background Loop Segments)"
    Kind    = "dvt-settings"
    CliArgs = @("developer", "dvt", "launch", "com.apple.Preferences", "--no-kill-existing", "--userspace")
}
if ($TryUserspaceHid) {
    $attempts += , @{
        Label   = "hid button home --userspace"
        Kind    = "hid"
        CliArgs = @("developer", "core-device", "hid", "button", "home", "--userspace")
    }
}

foreach ($attempt in $attempts) {
    Write-Host "[home] Trying $($attempt.Label) (timeout ${AttemptTimeoutSec}s)..."
    $result = Invoke-PythonRuntimeTimed -Runtime $rt -ArgumentList (@("-m", "pymobiledevice3") + $attempt.CliArgs) -TimeoutSec $AttemptTimeoutSec
    $blob = ($result.Lines -join "`n")
    if ($blob -match "PasswordRequired|PasswordProtected|device is locked|phone is locked") {
        Write-HomeAttemptOutput -Lines $result.Lines
        Write-Host "[home] Phone locked - cannot press Home." -ForegroundColor Yellow
        Exit-Home 3
    }
    if ($result.TimedOut) {
        Write-HomeAttemptOutput -Lines $result.Lines -CollapseIfFailed
        continue
    }

    $launched = ($attempt.Kind -like "dvt*") -and ($blob -match "Process launched with pid")
    $hidOk = ($attempt.Kind -eq "hid") -and ($result.ExitCode -eq 0) -and ($blob -notmatch "Traceback|DTXNsError|CoreDeviceError|PasswordRequired")
    if (-not $launched -and -not $hidOk) {
        Write-HomeAttemptOutput -Lines $result.Lines -CollapseIfFailed
        continue
    }

    Write-HomeAttemptOutput -Lines $result.Lines
    $stillFg = Test-LoopSegmentsStillForeground -Runtime $rt -TimeoutSec ([Math]::Min(20, $AttemptTimeoutSec))
    if ($stillFg -eq $true) {
        Write-Host "[home] Loop Segments still foreground - trying next method." -ForegroundColor DarkGray
        continue
    }
    if ($attempt.Kind -eq "dvt-settings") {
        Write-Host "[home] Opened Settings to background Loop Segments (HID Home unavailable)." -ForegroundColor Green
    } else {
        Write-Host "[home] Home pressed - Loop Segments should be backgrounded." -ForegroundColor Green
    }
    Exit-Home 0
}

Write-Host "[home] Home press failed (USB / Developer Mode / tunnel / timeout). Leave the app as-is." -ForegroundColor Yellow
Exit-Home 1
