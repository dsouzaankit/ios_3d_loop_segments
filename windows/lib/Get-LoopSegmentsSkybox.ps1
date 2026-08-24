#Requires -Version 5.1
<#
.SYNOPSIS
  Companion Skybox start/stop plus Add-folders mapping (phone rclone + Skybox_vr_pc AirScreen share).

.DESCRIPTION
  Dot-source from pcloud_web_companion\run_chromium.ps1.
  Process start / hide-to-tray / quit and the AirScreen share (p_cld_media by default)
  come from the Skybox_vr_pc submodule (SkyboxVrPc.UnmapPath.ps1). This file keeps the
  companion-started marker, maps/unmaps phone rclone pcld_ios_media, and does not touch
  3d_fullsbs_trans. Override with SKYBOX_VR_PC_ROOT; fallback is P:\all_scripts\Skybox_vr_pc.
#>

$script:LoopSegmentsSkyboxRcloneFolderName = 'pcld_ios_media'
$script:LoopSegmentsSkyboxVrPcImported = $false

function Get-LoopSegmentsSkyboxConfiguredExe {
    $envPath = [string]$env:LOOP_SEGMENTS_SKYBOX_EXE
    if (-not [string]::IsNullOrWhiteSpace($envPath) -and (Test-Path -LiteralPath $envPath.Trim() -PathType Leaf)) {
        return [System.IO.Path]::GetFullPath($envPath.Trim())
    }
    $jsonPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'loop-segments-windows.json'
    if (-not (Test-Path -LiteralPath $jsonPath)) { return $null }
    try {
        $obj = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $p = [string]$obj.skyboxExe
        if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p.Trim() -PathType Leaf)) {
            return [System.IO.Path]::GetFullPath($p.Trim())
        }
    } catch {}
    return $null
}

function Get-LoopSegmentsSkyboxVrPcRoot {
    $envRoot = [string]$env:SKYBOX_VR_PC_ROOT
    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($envRoot)) {
        [void]$candidates.Add($envRoot.Trim())
    }
    $windowsDir = Split-Path -Parent $PSScriptRoot
    $repoRoot = Split-Path -Parent $windowsDir
    if ($repoRoot) {
        [void]$candidates.Add((Join-Path $repoRoot 'Skybox_vr_pc'))
    }
    [void]$candidates.Add('P:\all_scripts\Skybox_vr_pc')
    $walk = $PSScriptRoot
    for ($i = 0; $i -lt 6 -and $walk; $i++) {
        $walk = Split-Path -Parent $walk
        if ($walk) {
            [void]$candidates.Add((Join-Path $walk 'Skybox_vr_pc'))
        }
    }
    foreach ($root in $candidates) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        try {
            $full = [System.IO.Path]::GetFullPath($root)
        } catch {
            continue
        }
        if (Test-Path -LiteralPath (Join-Path $full 'SkyboxVrPc.UnmapPath.ps1') -PathType Leaf) {
            return $full
        }
    }
    return $null
}

function Import-LoopSegmentsSkyboxVrPc {
    [bool]$script:LoopSegmentsSkyboxVrPcImported
}

$script:LoopSegmentsSkyboxVrPcRootResolved = Get-LoopSegmentsSkyboxVrPcRoot
if ($script:LoopSegmentsSkyboxVrPcRootResolved) {
    . (Join-Path $script:LoopSegmentsSkyboxVrPcRootResolved 'SkyboxVrPc.UnmapPath.ps1')
    $script:LoopSegmentsSkyboxVrPcImported = $true
} else {
    Write-Warning '[skybox] Skybox_vr_pc not found. git submodule update --init Skybox_vr_pc (or set SKYBOX_VR_PC_ROOT / P:\all_scripts\Skybox_vr_pc).'
}

function Initialize-LoopSegmentsSkyboxVrPcExeOverride {
    $configured = Get-LoopSegmentsSkyboxConfiguredExe
    if ($configured -and [string]::IsNullOrWhiteSpace([string]$env:SKYBOX_VR_PC_EXE)) {
        $env:SKYBOX_VR_PC_EXE = $configured
    }
}

# Virtual Desktop helper calls this when Skybox's file is already loaded.
function Start-LoopSegmentsDetachedProcess {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string] $Arguments = ''
    )
    if ($FilePath -notmatch '(?i)^steam:' -and [string]::IsNullOrWhiteSpace($Arguments) -and (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        $cmdArgs = '/c start "" "' + $FilePath + '"'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "$env:SystemRoot\System32\cmd.exe"
        $psi.Arguments = $cmdArgs
        $psi.UseShellExecute = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        [void][System.Diagnostics.Process]::Start($psi)
        return
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        $psi.Arguments = $Arguments
    }
    $psi.UseShellExecute = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    [void][System.Diagnostics.Process]::Start($psi)
}

function Get-LoopSegmentsSkyboxPath {
    $configured = Get-LoopSegmentsSkyboxConfiguredExe
    if ($configured) { return $configured }
    if ((Import-LoopSegmentsSkyboxVrPc) -and (Get-Command Get-SkyboxPcClientPath -ErrorAction SilentlyContinue)) {
        return (Get-SkyboxPcClientPath)
    }
    return $null
}

function Test-LoopSegmentsSkyboxRunning {
    if ((Import-LoopSegmentsSkyboxVrPc) -and (Get-Command Test-SkyboxPcClientRunning -ErrorAction SilentlyContinue)) {
        return [bool](Test-SkyboxPcClientRunning)
    }
    foreach ($n in @('SKYBOX', 'Skybox', 'SkyboxVR', 'SkyboxDesktop')) {
        if (@(Get-Process -Name $n -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
    }
    return $false
}

function Get-LoopSegmentsSkyboxStartedMarkerPath {
    Join-Path $env:LOCALAPPDATA 'pcloud_web_companion\skybox-started-by-companion.marker'
}

function Set-LoopSegmentsSkyboxStartedMarker {
    $p = Get-LoopSegmentsSkyboxStartedMarkerPath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
    Set-Content -LiteralPath $p -Value (Get-Date -Format o) -Encoding ascii
}

function Clear-LoopSegmentsSkyboxStartedMarker {
    $p = Get-LoopSegmentsSkyboxStartedMarkerPath
    if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
}

function Test-LoopSegmentsSkyboxStartedByCompanion {
    Test-Path -LiteralPath (Get-LoopSegmentsSkyboxStartedMarkerPath)
}

function Invoke-LoopSegmentsSkyboxVrPcMap {
    if (-not (Import-LoopSegmentsSkyboxVrPc)) { return $false }
    if (-not (Get-Command Map-SkyboxVrPcShare -ErrorAction SilentlyContinue)) { return $false }
    try {
        return [bool](Map-SkyboxVrPcShare)
    } catch {
        Write-Warning ("[skybox] Skybox_vr_pc AirScreen share not mapped: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Invoke-LoopSegmentsSkyboxVrPcUnmap {
    if (-not (Get-Command Unmap-SkyboxVrPcShare -ErrorAction SilentlyContinue)) {
        if (-not (Import-LoopSegmentsSkyboxVrPc)) { return }
    }
    if (-not (Get-Command Unmap-SkyboxVrPcShare -ErrorAction SilentlyContinue)) { return }
    try {
        [void](Unmap-SkyboxVrPcShare)
    } catch {
        Write-Warning ("[skybox] Skybox_vr_pc AirScreen share unmap failed: {0}" -f $_.Exception.Message)
    }
}

function Get-LoopSegmentsSkyboxRcloneLocalPath {
    param(
        [Parameter(Mandatory = $true)][string] $DriveRoot,
        [switch] $MountedAtPcldIosMedia
    )
    $root = $DriveRoot.Trim().TrimEnd('\')
    if ($MountedAtPcldIosMedia) { return $root }
    return (Join-Path $root 'pcld_ios_media')
}

function Resolve-LoopSegmentsSkyboxRcloneLocalPathFromDisk {
    param([Parameter(Mandatory = $true)][string] $DriveRoot)
    $root = $DriveRoot.Trim().TrimEnd('\') + '\'
    if (Test-Path -LiteralPath (Join-Path $root 'loop')) {
        return $root.TrimEnd('\')
    }
    $nested = Join-Path $root 'pcld_ios_media'
    if (Test-Path -LiteralPath $nested) {
        return $nested.TrimEnd('\')
    }
    return $root.TrimEnd('\')
}

function Sync-LoopSegmentsSkyboxRcloneFolder {
    <#
      Point Skybox Add folders at the live phone rclone path (pcld_ios_media / loopsegments).
      Does not change 3d_fullsbs_trans or the Skybox_vr_pc AirScreen share.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $LocalPath,
        [switch] $Removed
    )
    $expected = $LocalPath.Trim().TrimEnd('\')
    if (-not (Import-LoopSegmentsSkyboxVrPc) -or -not (Get-Command Sync-SkyboxVrPcShareMapping -ErrorAction SilentlyContinue)) {
        if (-not $Removed) {
            Write-Warning ("Skybox_vr_pc mapping helper missing. Could not map {0}." -f $expected)
        }
        return
    }
    if ($Removed) {
        [void](Sync-SkyboxVrPcShareMapping -ExpectedRoot $expected -ShareName $script:LoopSegmentsSkyboxRcloneFolderName -Removed)
        [void](Sync-SkyboxVrPcShareMapping -ExpectedRoot $expected -ShareName 'loopsegments' -Removed)
        return
    }
    [void](Sync-SkyboxVrPcShareMapping -ExpectedRoot $expected -ShareName 'loopsegments' -Removed)
    [void](Sync-SkyboxVrPcShareMapping -ExpectedRoot $expected -ShareName $script:LoopSegmentsSkyboxRcloneFolderName)
}

function Remove-LoopSegmentsSkyboxRcloneFolderMapping {
    try {
        Sync-LoopSegmentsSkyboxRcloneFolder -LocalPath 'pcld_ios_media' -Removed
    } catch {
        Write-Warning ("[skybox] Could not remove rclone Add-folders mapping: {0}" -f $_.Exception.Message)
    }
}

function Stop-LoopSegmentsSkybox {
    param([switch] $OnlyIfCompanionStarted)

    if (Get-Command Stop-SkyboxPcClientMinimizeWatch -ErrorAction SilentlyContinue) {
        try { Stop-SkyboxPcClientMinimizeWatch } catch {}
    }
    # Shares first while Skybox is still running (AirScreen + phone rclone).
    Invoke-LoopSegmentsSkyboxVrPcUnmap
    Remove-LoopSegmentsSkyboxRcloneFolderMapping

    if ($OnlyIfCompanionStarted -and -not (Test-LoopSegmentsSkyboxStartedByCompanion)) {
        return
    }
    if (Get-Command Stop-SkyboxVrPcProcess -ErrorAction SilentlyContinue) {
        Stop-SkyboxVrPcProcess
    }
    Clear-LoopSegmentsSkyboxStartedMarker
}

function Start-LoopSegmentsSkybox {
    param([int] $WaitSeconds = 3)
    $null = $WaitSeconds
    Initialize-LoopSegmentsSkyboxVrPcExeOverride
    if (-not (Import-LoopSegmentsSkyboxVrPc)) {
        return [pscustomobject]@{
            Installed = $false
            Running   = $false
            Path      = $null
            Started   = $false
        }
    }
    $wasRunning = Test-LoopSegmentsSkyboxRunning
    $api = Start-SkyboxVrPcProcess
    $started = $false
    if (-not $wasRunning -and (Get-Command Test-SkyboxVrPcStartedByThisSession -ErrorAction SilentlyContinue)) {
        $started = [bool](Test-SkyboxVrPcStartedByThisSession)
    }
    if ($started) {
        try { Set-LoopSegmentsSkyboxStartedMarker } catch {}
    }
    [void](Invoke-LoopSegmentsSkyboxVrPcMap)
    $path = Get-LoopSegmentsSkyboxPath
    return [pscustomobject]@{
        Installed = [bool]$path -or $api -or (Test-LoopSegmentsSkyboxRunning)
        Running   = [bool]$api -or (Test-LoopSegmentsSkyboxRunning)
        Path      = $path
        Started   = [bool]$started
    }
}

function Write-LoopSegmentsSkyboxNotice {
    param(
        [switch] $AlwaysStatus,
        [switch] $EnsureStarted
    )

    Initialize-LoopSegmentsSkyboxVrPcExeOverride
    [void](Import-LoopSegmentsSkyboxVrPc)
    $path = Get-LoopSegmentsSkyboxPath
    $running = Test-LoopSegmentsSkyboxRunning
    $steam = $false
    if (Get-Command Test-SkyboxSteamAppInstalled -ErrorAction SilentlyContinue) {
        $steam = [bool](Test-SkyboxSteamAppInstalled)
    }
    if (-not $path -and -not $running -and -not $steam) {
        Write-Host ""
        Write-Host '[skybox] NOT INSTALLED on this PC (optional for companion).' -ForegroundColor Yellow
        Write-Host 'Install SKYBOX VR Video Player, or set skyboxExe in loop-segments-windows.json / LOOP_SEGMENTS_SKYBOX_EXE.' -ForegroundColor Yellow
        return [pscustomobject]@{
            Installed = $false
            Running   = $false
            Path      = $null
            Started   = $false
        }
    }

    if ($EnsureStarted) {
        return Start-LoopSegmentsSkybox
    }
    if ($AlwaysStatus -or $running) {
        Write-Host ("[skybox] {0}{1}" -f $(if ($running) { 'Already running' } else { 'Installed, not running' }), $(if ($path) { ": $path" } else { '' }))
    }
    return [pscustomobject]@{
        Installed = [bool]$path -or $running
        Running   = $running
        Path      = $path
        Started   = $false
    }
}
