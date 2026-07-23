#Requires -Version 5.1
<#
.SYNOPSIS
  If the companion console dies without a graceful marker, close Chromium and sync profile.

.DESCRIPTION
  Started by run_chromium.ps1 while waiting on Chromium. When the parent PowerShell
  PID exits without writing the graceful-exit marker, this script force-closes the
  profile Chromium, uploads the profile to the repo path, and clears local AppData
  (same finish path as a normal companion exit).
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
    if ($SkipProfileSync) { return }
    if (-not (Test-LocalHasContent -Dir $Src)) { return }
    New-Item -ItemType Directory -Force -Path $Dst | Out-Null
    $excludeFiles = @(
        "SingletonLock"
        "SingletonCookie"
        "SingletonSocket"
        "lockfile"
        "DevToolsActivePort"
    )
    $args = @(
        $Src, $Dst, "/E", "/MIR", "/R:2", "/W:1",
        "/NFL", "/NDL", "/NJH", "/NJS", "/NC", "/NS", "/XF"
    ) + $excludeFiles
    & robocopy.exe @args | Out-Null
    foreach ($name in $excludeFiles) {
        $p = Join-Path $Dst $name
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
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
Write-Host "[watchdog] Parent gone without graceful marker - closing Chromium and syncing profile"
Stop-ProfileChrome -Dir $ProfileDir
Start-Sleep -Milliseconds 500
Sync-Upload -Src $ProfileDir -Dst $RepoProfileDir
Clear-Local -Dir $ProfileDir

$homePs1 = Join-Path (Split-Path -Parent $PSScriptRoot) "Go-IphoneHomeViaUsb.ps1"
if (-not $SkipGoHome -and (Test-Path -LiteralPath $homePs1)) {
    Write-Host "[watchdog] Pressing iPhone Home to background Loop Segments..."
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Command powershell.exe).Source
        $psi.Arguments = "-NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass -File `"$homePs1`""
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
