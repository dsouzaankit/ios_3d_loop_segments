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
    [switch] $KeepLocalProfile
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
    $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine.IndexOf($Dir, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
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

# Give the parent a moment to write the graceful marker / finish itself.
Start-Sleep -Seconds 2

if (Test-Path -LiteralPath $GracefulMarkerPath) {
    Remove-Item -LiteralPath $GracefulMarkerPath -Force -ErrorAction SilentlyContinue
    exit 0
}

# Ungraceful close (console X, kill, crash): finish the companion session.
Stop-ProfileChrome -Dir $ProfileDir
Start-Sleep -Milliseconds 500
Sync-Upload -Src $ProfileDir -Dst $RepoProfileDir
Clear-Local -Dir $ProfileDir
exit 0
