#Requires -Version 7.0
<#
.SYNOPSIS
  If the companion console dies without a graceful marker, close Chromium/Skybox and sync profile.

.DESCRIPTION
  Started by run_chromium.ps1 while waiting on Chromium. When the parent PowerShell
  PID exits without writing the graceful-exit marker, this script force-closes the
  profile Chromium, quits SKYBOX VR if this companion session started it, uploads
  the profile zip to the repo path, and clears local AppData (same finish path as a
  normal companion exit).
#>
param(
    [Parameter(Mandatory = $true)] [int] $ParentPid,
    [Parameter(Mandatory = $true)] [string] $ProfileDir,
    [Parameter(Mandatory = $true)] [string] $RepoProfileDir,
    [Parameter(Mandatory = $true)] [string] $GracefulMarkerPath,
    [switch] $SkipProfileSync,
    [switch] $KeepLocalProfile,
    [Parameter(Mandatory = $false)]
    [switch] $SkipGoHome
)

$ErrorActionPreference = "Continue"

$WindowsLib = Join-Path (Split-Path -Parent $PSScriptRoot) "lib"
$PwshHelper = Join-Path $WindowsLib "Get-LoopSegmentsPwsh.ps1"
if (Test-Path -LiteralPath $PwshHelper) {
    . $PwshHelper
}
$SkyboxHelper = Join-Path $WindowsLib "Get-LoopSegmentsSkybox.ps1"
if (Test-Path -LiteralPath $SkyboxHelper) {
    . $SkyboxHelper
}
$ProfileSyncHelper = Join-Path $PSScriptRoot "_chromium_profile_sync.ps1"
if (Test-Path -LiteralPath $ProfileSyncHelper) {
    . $ProfileSyncHelper
}

function Test-LocalHasContent {
    param([string] $Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return $false }
    if (Test-Path -LiteralPath (Join-Path $Dir "Default")) { return $true }
    $any = @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)
    return ($any.Count -gt 0)
}

function Stop-ProfileChrome {
    param([string] $Dir)
    $needle = if ($Dir) { $Dir.Replace('/', '\') } else { "" }
    $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            if (-not $_.CommandLine) { return $false }
            $cmd = $_.CommandLine.Replace('/', '\')
            if ($needle -and ($cmd.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)) {
                return $true
            }
            return ($cmd -match '(?i)pcloud_web_companion[\\/]+chromium-profile')
        })
    foreach ($proc in $procs) {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($procs.Count -gt 0) {
        Start-Sleep -Seconds 1
    }
}

function Sync-Upload {
    param([string] $Src, [string] $Dst)
    if (-not (Get-Command Sync-LoopSegmentsChromiumProfile -ErrorAction SilentlyContinue)) {
        Write-Warning "[watchdog] Profile zip helper missing - skip upload"
        return
    }
    $zip = Join-Path (Split-Path -Parent $Dst) "chromium-profile.zip"
    Sync-LoopSegmentsChromiumProfile -Direction Upload `
        -LocalProfileDir $Src `
        -RepoProfileDir $Dst `
        -RepoProfileZip $zip `
        -Skip:$SkipProfileSync
}

function Clear-Local {
    param([string] $Dir)
    if ($KeepLocalProfile) { return }
    if (-not (Test-Path -LiteralPath $Dir)) {
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        return
    }
    Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
}

# Wait until parent console/script process is gone.
while ($true) {
    $alive = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
    if (-not $alive) { break }
    Start-Sleep -Milliseconds 500
}

# Brief pause so a graceful parent finish can write its marker after sync.
Start-Sleep -Seconds 2

if (Test-Path -LiteralPath $GracefulMarkerPath) {
    Remove-Item -LiteralPath $GracefulMarkerPath -Force -ErrorAction SilentlyContinue
    exit 0
}

# Ungraceful close (console X, kill, crash): finish the companion session.
Write-Host "[watchdog] Parent gone without graceful marker - closing Chromium, quitting Skybox if we started it, syncing profile"
Stop-ProfileChrome -Dir $ProfileDir
if (Get-Command Stop-LoopSegmentsSkybox -ErrorAction SilentlyContinue) {
    try { Stop-LoopSegmentsSkybox -OnlyIfCompanionStarted } catch {}
}
Start-Sleep -Milliseconds 500
Sync-Upload -Src $ProfileDir -Dst $RepoProfileDir
Clear-Local -Dir $ProfileDir

$homePs1 = Join-Path (Split-Path -Parent $PSScriptRoot) "usb\Go-IphoneHomeViaUsb.ps1"
if (-not $SkipGoHome -and (Test-Path -LiteralPath $homePs1)) {
    Write-Host "[watchdog] Pressing iPhone Home to background Loop Segments..."
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-LoopSegmentsPwshExe)
        $psi.Arguments = "-NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass -File `"$homePs1`" -NoWaitEnter"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $hp = [System.Diagnostics.Process]::Start($psi)
        if ($null -ne $hp) {
            if (-not $hp.WaitForExit(120000)) {
                try { & taskkill.exe /PID $hp.Id /T /F 2>&1 | Out-Null } catch {}
                try { $hp.Kill() } catch {}
            }
        }
    } catch {}
}
exit 0
