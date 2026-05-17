#Requires -Version 5.1
<#
.SYNOPSIS
  Copy 3d_op_00.mkv / 3d_op_01.mkv from iPhone Exports (USB) into the Windows DLNA segment folder.

.DESCRIPTION
  iPhone exports on cellular; PC receives files over USB only (no hotspot).
  DLNA playback uses the PC WLAN connection separately.

.PARAMETER DestinationDirectory
  DLNA library folder. Default matches Run-SegmentCopy.ps1.

.PARAMETER AppFolderName
  Display name of the iOS app in Files / Explorer (default: Loop Segments).

.PARAMETER SourceRoot
  Explicit folder containing 3d_op_00.mkv and 3d_op_01.mkv. Skips auto-discovery when set.

.PARAMETER WaitForDevice
  Poll until both segment files appear or timeout.

.PARAMETER WaitMinutes
  Used with -WaitForDevice. Default 15.

.PARAMETER DryRun
  List actions only.

.EXAMPLE
  .\Sync-IphoneSegments.ps1

.EXAMPLE
  .\Sync-IphoneSegments.ps1 -WaitForDevice

.EXAMPLE
  .\Sync-IphoneSegments.ps1 -SourceRoot 'D:\Internal Storage\Loop Segments\Exports'
#>
[CmdletBinding()]
param(
    [string] $DestinationDirectory = 'F:\f1_media\3d_fullsbs_trans',
    [string] $AppFolderName = 'Loop Segments',
    [string] $SourceRoot = '',
    [switch] $WaitForDevice,
    [int] $WaitMinutes = 15,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$SegmentNames = @('3d_op_00.mkv', '3d_op_01.mkv')

function Test-SegmentPairPresent {
    param([string] $Directory)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return $false }
    foreach ($n in $SegmentNames) {
        if (-not (Test-Path -LiteralPath (Join-Path $Directory $n) -PathType Leaf)) { return $false }
    }
    return $true
}

function Find-IphoneExportsOnDrives {
    param([string] $AppName)
    $relPaths = @(
        "$AppName\Exports",
        "Internal Storage\$AppName\Exports",
        "Apple Internal Storage\$AppName\Exports"
    )
    foreach ($letter in 68..90) {
        $root = ([char]$letter) + ':\'
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($rel in $relPaths) {
            $candidate = Join-Path $root $rel
            if (Test-SegmentPairPresent -Directory $candidate) { return $candidate }
        }
    }
    return $null
}

function Find-IphoneExportsRoot {
    param([string] $AppName)
    $candidates = [System.Collections.Generic.List[string]]::new()

    $fromDrive = Find-IphoneExportsOnDrives -AppName $AppName
    if ($fromDrive) { return $fromDrive }

    try {
        $shell = New-Object -ComObject Shell.Application
        $computer = $shell.NameSpace(0x11)
        if ($computer) {
            foreach ($item in @($computer.Items())) {
                $name = [string]$item.Name
                if ($name -notmatch 'iPhone|Apple iPhone') { continue }
                $phonePath = $item.Path
                if ([string]::IsNullOrWhiteSpace($phonePath)) { continue }
                [void]$candidates.Add((Join-Path $phonePath "$AppName\Exports"))
                [void]$candidates.Add((Join-Path $phonePath "Internal Storage\$AppName\Exports"))
            }
        }
    } catch { }

    try {
        Get-Volume -ErrorAction SilentlyContinue | Where-Object {
            $_.DriveLetter -and ($_.FileSystemLabel -match 'iPhone|APPLE')
        } | ForEach-Object {
            $root = $_.DriveLetter + ':\'
            [void]$candidates.Add((Join-Path $root "$AppName\Exports"))
            [void]$candidates.Add((Join-Path $root "Internal Storage\$AppName\Exports"))
        }
    } catch { }

    foreach ($root in $candidates) {
        if (Test-SegmentPairPresent -Directory $root) { return $root }
    }
    return $null
}

function Copy-SegmentIfNewer {
    param(
        [string] $SourcePath,
        [string] $DestPath,
        [switch] $DryRun
    )
    $copy = $true
    if ((Test-Path -LiteralPath $DestPath -PathType Leaf)) {
        $src = Get-Item -LiteralPath $SourcePath
        $dst = Get-Item -LiteralPath $DestPath
        if ($src.Length -eq $dst.Length -and $src.LastWriteTimeUtc -le $dst.LastWriteTimeUtc) {
            $copy = $false
        }
    }
    if (-not $copy) {
        Write-Host "Up to date: $DestPath"
        return
    }
    if ($DryRun) {
        Write-Host "Would copy: $SourcePath -> $DestPath"
        return
    }
    Copy-Item -LiteralPath $SourcePath -Destination $DestPath -Force
    Write-Host "Copied: $DestPath"
}

function Resolve-ExportsRoot {
    param(
        [string] $SourceRoot,
        [string] $AppFolderName,
        [switch] $WaitForDevice,
        [int] $WaitMinutes
    )
    if (-not [string]::IsNullOrWhiteSpace($SourceRoot)) {
        return [System.IO.Path]::GetFullPath($SourceRoot)
    }
    if (-not $WaitForDevice) {
        return Find-IphoneExportsRoot -AppName $AppFolderName
    }
    $deadline = [DateTime]::UtcNow.AddMinutes($WaitMinutes)
    Write-Host "Waiting for iPhone USB + both segment files (max $WaitMinutes min). Unlock phone and trust PC."
    while ([DateTime]::UtcNow -lt $deadline) {
        $found = Find-IphoneExportsRoot -AppName $AppFolderName
        if ($found) { return $found }
        Start-Sleep -Seconds 5
    }
    return $null
}

$exportsRoot = Resolve-ExportsRoot -SourceRoot $SourceRoot -AppFolderName $AppFolderName `
    -WaitForDevice:$WaitForDevice -WaitMinutes $WaitMinutes

if (-not $exportsRoot -or -not (Test-Path -LiteralPath $exportsRoot -PathType Container)) {
    Write-Error @"
Could not find iPhone Exports with both segment files.
- Export on iPhone (cellular OK) until 3d_op_00.mkv and 3d_op_01.mkv exist
- USB connect, unlock, Trust this computer
- Open Explorer: iPhone -> $AppFolderName -> Exports
- Or: .\Sync-IphoneSegments.ps1 -SourceRoot '<path from Explorer>'
"@
}

$destRoot = [System.IO.Path]::GetFullPath($DestinationDirectory)
if (-not $DryRun -and -not (Test-Path -LiteralPath $destRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
}

Write-Host "Source (USB / iPhone): $exportsRoot"
Write-Host "Destination (DLNA library): $destRoot"
Write-Host "Playback: PC DLNA server on WLAN (not iPhone hotspot)."

foreach ($name in $SegmentNames) {
    $src = Join-Path $exportsRoot $name
    $dst = Join-Path $destRoot $name
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        Write-Warning "Missing on phone: $src"
        continue
    }
    Copy-SegmentIfNewer -SourcePath $src -DestPath $dst -DryRun:$DryRun
}

Write-Host 'Done. Start or refresh your Windows DLNA library on WLAN.'
