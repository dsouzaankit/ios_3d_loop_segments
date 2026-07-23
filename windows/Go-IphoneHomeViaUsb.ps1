#Requires -Version 5.1
<#
.SYNOPSIS
  Press the iPhone Home button over USB (background / "minimize" the foreground app).

.DESCRIPTION
  Uses pymobiledevice3 developer core-device hid button home.
  Intended after Run-PCloudWebCompanion finishes so Loop Segments leaves the
  foreground while Keep Alive / LAN can keep running.

  Each pymobiledevice3 attempt has a hard timeout (default 25s). Without that,
  hid/userspace can hang forever and leave the companion stuck on finish.

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
    [switch] $UseTunneld,
    [int] $AttemptTimeoutSec = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PythonHelper = Join-Path $PSScriptRoot "Get-LoopSegmentsPython.ps1"
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
    exit 2
}

$attempts = @()
if ($UseTunneld) {
    $attempts += , @{ Label = "hid button home --tunnel ''"; CliArgs = @("developer", "core-device", "hid", "button", "home", "--tunnel", "") }
}
$attempts += , @{ Label = "hid button home --userspace"; CliArgs = @("developer", "core-device", "hid", "button", "home", "--userspace") }
$attempts += , @{ Label = "hid button home"; CliArgs = @("developer", "core-device", "hid", "button", "home") }

foreach ($attempt in $attempts) {
    Write-Host "[home] Trying $($attempt.Label) (timeout ${AttemptTimeoutSec}s)..."
    $result = Invoke-PythonRuntimeTimed -Runtime $rt -ArgumentList (@("-m", "pymobiledevice3") + $attempt.CliArgs) -TimeoutSec $AttemptTimeoutSec
    foreach ($line in $result.Lines) { if ($line) { Write-Host $line } }
    $blob = ($result.Lines -join "`n")
    if ($result.TimedOut) { continue }
    if ($result.ExitCode -eq 0 -and $blob -notmatch "Traceback|DTXNsError|CoreDeviceError|PasswordRequired") {
        Write-Host "[home] Home pressed - Loop Segments should be backgrounded." -ForegroundColor Green
        exit 0
    }
    if ($blob -match "PasswordRequired|PasswordProtected|device is locked|phone is locked") {
        Write-Host "[home] Phone locked - cannot press Home." -ForegroundColor Yellow
        exit 3
    }
}

Write-Host "[home] Home press failed (USB / Developer Mode / tunnel / timeout). Leave the app as-is." -ForegroundColor Yellow
exit 1
