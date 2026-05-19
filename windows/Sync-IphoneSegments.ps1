#Requires -Version 5.1
<#
.SYNOPSIS
  Copy op_00.mp4 / op_01.mp4 from iPhone Exports (USB) into the Windows DLNA segment folder.

.PARAMETER Discover
  List iPhone / Exports paths Windows can see (use when auto-detect fails).

.PARAMETER LogsOnly
  Only copy export logs; do not require segment MP4s on the phone.

.PARAMETER AllowPartial
  Sync when at least one segment exists (default if -LogsOnly).

.PARAMETER SourceRoot
  Exports folder from Explorer address bar, e.g.:
  '\\?\...\Apple iPhone\Internal Storage\Loop Segments\Exports'

.EXAMPLE
  .\Sync-IphoneSegments.ps1 -Discover

.EXAMPLE
  .\Sync-IphoneSegments.ps1 -SourceRoot 'D:\Apple iPhone\Internal Storage\Loop Segments\Exports'

.EXAMPLE
  .\Sync-IphoneSegments.ps1 -LogsOnly -SourceRoot '...\Loop Segments\Exports'
#>
[CmdletBinding()]
param(
    [string] $DestinationDirectory = 'F:\f1_media\3d_fullsbs_trans',
    [string] $AppFolderName = 'Loop Segments',
    [string] $SourceRoot = '',
    [switch] $WaitForDevice,
    [int] $WaitMinutes = 15,
    [string] $LogDestination = '',
    [switch] $SkipLogs,
    [switch] $Discover,
    [switch] $LogsOnly,
    [switch] $AllowPartial,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$SegmentNames = @('op_00.mp4', 'op_01.mp4')
$SourceConfigFile = Join-Path $PSScriptRoot 'loop-segments-source.txt'

if ([string]::IsNullOrWhiteSpace($SourceRoot) -and (Test-Path -LiteralPath $SourceConfigFile -PathType Leaf)) {
    $SourceRoot = (Get-Content -LiteralPath $SourceConfigFile -Raw).Trim()
    if ($SourceRoot) {
        Write-Host "Using saved source: $SourceRoot"
    }
}

if ($LogsOnly) { $AllowPartial = $true }

function Get-SegmentStatus {
    param([string] $Directory)
    $found = @()
    foreach ($n in $SegmentNames) {
        if (Test-Path -LiteralPath (Join-Path $Directory $n) -PathType Leaf) { $found += $n }
    }
    return $found
}

function Test-SegmentPairPresent {
    param([string] $Directory)
    return (Get-SegmentStatus -Directory $Directory).Count -eq 2
}

function Test-ExportsFolder {
    param([string] $Directory)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return $false }
    $status = Get-SegmentStatus -Directory $Directory
    if ($status.Count -gt 0) { return $true }
    foreach ($name in @('export_latest.txt', 'export_latest.log')) {
        if (Test-Path -LiteralPath (Join-Path $Directory $name) -PathType Leaf) { return $true }
    }
    if (Test-Path -LiteralPath (Join-Path $Directory 'logs') -PathType Container) { return $true }
    return $false
}

function Get-ExportsRelativePaths {
    param([string] $AppName)
    @(
        "$AppName\Exports",
        "Internal Storage\$AppName\Exports",
        "Apple Internal Storage\$AppName\Exports",
        "Internal Storage\Apple iPhone\$AppName\Exports",
        "$AppName\Documents\Exports"
    )
}

function Add-Candidate {
    param(
        [System.Collections.Generic.HashSet[string]] $Set,
        [string] $Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        $full = [System.IO.Path]::GetFullPath($Path.TrimEnd('\'))
    } catch { return }
    if (Test-Path -LiteralPath $full -PathType Container) {
        [void]$Set.Add($full)
    }
}

function Find-ExportsCandidates {
    param([string] $AppName)

    $candidates = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $relPaths = Get-ExportsRelativePaths -AppName $AppName

    foreach ($letter in 68..90) {
        $root = ([char]$letter) + ':\'
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($rel in $relPaths) {
            Add-Candidate -Set $candidates -Path (Join-Path $root $rel)
        }
        try {
            Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Name -match 'iPhone|Apple|Internal Storage') {
                    foreach ($rel in $relPaths) {
                        Add-Candidate -Set $candidates -Path (Join-Path $_.FullName ($rel -replace "^$([regex]::Escape($AppName))\\", ''))
                        Add-Candidate -Set $candidates -Path (Join-Path $_.FullName "$AppName\Exports")
                        Add-Candidate -Set $candidates -Path (Join-Path $_.FullName "Internal Storage\$AppName\Exports")
                    }
                }
            }
        } catch { }
    }

    try {
        $shell = New-Object -ComObject Shell.Application
        $computer = $shell.NameSpace(0x11)
        if ($computer) {
            foreach ($phoneItem in @($computer.Items())) {
                if ([string]$phoneItem.Name -notmatch 'iPhone|Apple') { continue }
                $phoneFolder = $phoneItem.GetFolder()
                if (-not $phoneFolder) { continue }
                foreach ($child in @($phoneFolder.Items())) {
                    $childPath = [string]$child.Path
                    $childName = [string]$child.Name
                    if ($childName -eq 'Exports' -and $childPath) {
                        Add-Candidate -Set $candidates -Path $childPath
                    }
                    if ($childName -eq $AppName -and $childPath) {
                        Add-Candidate -Set $candidates -Path (Join-Path $childPath 'Exports')
                    }
                    if ($child.IsFolder) {
                        $sub = $child.GetFolder()
                        if ($sub) {
                            foreach ($grand in @($sub.Items())) {
                                $gPath = [string]$grand.Path
                                $gName = [string]$grand.Name
                                if ($gName -eq 'Exports' -and $gPath) {
                                    Add-Candidate -Set $candidates -Path $gPath
                                }
                                if ($gName -eq $AppName -and $gPath) {
                                    Add-Candidate -Set $candidates -Path (Join-Path $gPath 'Exports')
                                }
                            }
                        }
                    }
                }
                foreach ($rel in $relPaths) {
                    Add-Candidate -Set $candidates -Path (Join-Path ([string]$phoneItem.Path) $rel)
                }
            }
        }
    } catch { }

    try {
        Get-Volume -ErrorAction SilentlyContinue | Where-Object {
            $_.DriveLetter -and ($_.FileSystemLabel -match 'iPhone|APPLE|Apple')
        } | ForEach-Object {
            $root = $_.DriveLetter + ':\'
            foreach ($rel in $relPaths) {
                Add-Candidate -Set $candidates -Path (Join-Path $root $rel)
            }
        }
    } catch { }

    return @($candidates) | Sort-Object
}

function Select-BestExportsRoot {
    param(
        [string[]] $Candidates,
        [switch] $RequirePair,
        [switch] $AllowPartial
    )
    $withPair = @()
    $withAny = @()
    $withFolder = @()
    foreach ($c in $Candidates) {
        if (-not (Test-Path -LiteralPath $c -PathType Container)) { continue }
        [void]$withFolder.Add($c)
        $seg = Get-SegmentStatus -Directory $c
        if ($seg.Count -eq 2) { [void]$withPair.Add($c) }
        if ($seg.Count -ge 1) { [void]$withAny.Add($c) }
    }
    if ($withPair.Count -ge 1) { return $withPair[0] }
    if ($AllowPartial -and $withAny.Count -ge 1) { return $withAny[0] }
    if ($AllowPartial -and $withFolder.Count -ge 1) {
        foreach ($c in $withFolder) {
            if (Test-ExportsFolder -Directory $c) { return $c }
        }
    }
    if (-not $RequirePair -and $withFolder.Count -ge 1) { return $withFolder[0] }
    return $null
}

function Show-DiscoverReport {
    param([string] $AppName)
    Write-Host ''
    Write-Host '=== Sync-IphoneSegments -Discover ===' -ForegroundColor Cyan
    Write-Host "Looking for '$AppName\Exports' and segment MP4s..."
    Write-Host ''

    $candidates = Find-ExportsCandidates -AppName $AppName
    if ($candidates.Count -eq 0) {
        Write-Host 'No Exports folders found on fixed drives or under This PC -> iPhone.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Checklist:'
        Write-Host '  1. USB cable, iPhone unlocked, Trust This Computer'
        Write-Host '  2. On iPhone: Files -> On My iPhone -> Loop Segments -> Exports (op_*.mp4)'
        Write-Host '  3. Folders like 202605_a under Internal Storage are PHOTOS only — not this app'
        Write-Host '  4. On PC: open Apple Devices app -> iPhone -> Files / File Sharing -> Loop Segments'
        Write-Host '  5. If Explorer shows Loop Segments\Exports, copy address bar path:'
        Write-Host "     .\Sync-IphoneSegments.ps1 -SourceRoot '<that path>'"
        Write-Host '  6. Else: Share MP4s from iPhone Files app to cloud/email, then copy to F:\f1_media\...'
        return
    }

    foreach ($c in $candidates) {
        $seg = Get-SegmentStatus -Directory $c
        $segLabel = if ($seg.Count -eq 0) { 'no segments' } else { ($seg -join ', ') }
        $logs = @()
        foreach ($n in @('export_latest.txt', 'export_latest.log')) {
            if (Test-Path -LiteralPath (Join-Path $c $n)) { $logs += $n }
        }
        $logLabel = if ($logs.Count) { "logs: $($logs -join ', ')" } else { 'no export_latest log in Exports' }
        Write-Host "FOUND: $c"
        Write-Host "       $segLabel | $logLabel"
        try {
            Get-ChildItem -LiteralPath $c -Force -ErrorAction SilentlyContinue |
                Select-Object -First 12 Name, Length, LastWriteTime |
                Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_.TrimEnd() }
        } catch {
            Write-Host '       (folder listed in Explorer but not readable from PowerShell — use -SourceRoot with Explorer path)'
        }
        Write-Host ''
    }

    $best = Select-BestExportsRoot -Candidates $candidates -AllowPartial
    if ($best) {
        Write-Host "Suggested -SourceRoot:" -ForegroundColor Green
        Write-Host "  .\Sync-IphoneSegments.ps1 -SourceRoot '$best'"
    }
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

function Copy-ExportLogs {
    param(
        [string] $ExportsRoot,
        [string] $LogDestination,
        [switch] $DryRun
    )
    if ([string]::IsNullOrWhiteSpace($LogDestination)) {
        $LogDestination = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'LoopSegmentsLogs'
    }
    $logDestRoot = [System.IO.Path]::GetFullPath($LogDestination)
    if (-not $DryRun -and -not (Test-Path -LiteralPath $logDestRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $logDestRoot -Force | Out-Null
    }

    $appRoot = Split-Path -LiteralPath $ExportsRoot -Parent
    $logSources = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('export_latest.txt', 'export_latest.log')) {
        [void]$logSources.Add((Join-Path $ExportsRoot $name))
    }
    $exportsLogsDir = Join-Path $ExportsRoot 'logs'
    if (Test-Path -LiteralPath $exportsLogsDir -PathType Container) {
        Get-ChildItem -LiteralPath $exportsLogsDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.log', '.txt' } |
            ForEach-Object { [void]$logSources.Add($_.FullName) }
    }
    $legacyLogsDir = Join-Path $appRoot 'Logs'
    if (Test-Path -LiteralPath $legacyLogsDir -PathType Container) {
        Get-ChildItem -LiteralPath $legacyLogsDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.log', '.txt' } |
            ForEach-Object { [void]$logSources.Add($_.FullName) }
    }

    Write-Host "Log destination (PC): $logDestRoot"
    $seen = @{}
    foreach ($src in $logSources) {
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
        $leaf = Split-Path -Leaf $src
        if ($seen.ContainsKey($leaf)) { continue }
        $seen[$leaf] = $true
        $dst = Join-Path $logDestRoot $leaf
        Copy-SegmentIfNewer -SourcePath $src -DestPath $dst -DryRun:$DryRun
    }
    if ($seen.Count -eq 0) {
        Write-Host 'No export logs found in Exports or Logs on phone.'
    }
}

function Resolve-ExportsRoot {
    param(
        [string] $SourceRoot,
        [string] $AppFolderName,
        [switch] $WaitForDevice,
        [int] $WaitMinutes,
        [switch] $AllowPartial,
        [switch] $LogsOnly
    )
    if (-not [string]::IsNullOrWhiteSpace($SourceRoot)) {
        $full = [System.IO.Path]::GetFullPath($SourceRoot)
        if (-not (Test-Path -LiteralPath $full -PathType Container)) {
            throw "SourceRoot is not a folder: $full"
        }
        return $full
    }

    $tryFind = {
        $candidates = Find-ExportsCandidates -AppName $AppFolderName
        Select-BestExportsRoot -Candidates $candidates -RequirePair:(-not $AllowPartial -and -not $LogsOnly) -AllowPartial:($AllowPartial -or $LogsOnly)
    }

    if (-not $WaitForDevice) {
        return & $tryFind
    }

    $deadline = [DateTime]::UtcNow.AddMinutes($WaitMinutes)
    Write-Host "Waiting for iPhone USB + Exports (max $WaitMinutes min). Unlock phone and trust PC."
    while ([DateTime]::UtcNow -lt $deadline) {
        $found = & $tryFind
        if ($found) { return $found }
        Start-Sleep -Seconds 5
    }
    return $null
}

if ($Discover) {
    Show-DiscoverReport -AppName $AppFolderName
    return
}

$exportsRoot = Resolve-ExportsRoot -SourceRoot $SourceRoot -AppFolderName $AppFolderName `
    -WaitForDevice:$WaitForDevice -WaitMinutes $WaitMinutes -AllowPartial:$AllowPartial -LogsOnly:$LogsOnly

if (-not $exportsRoot) {
    Write-Host ''
    Write-Host 'Auto-detect failed. Run discovery:' -ForegroundColor Yellow
    Write-Host '  .\Sync-IphoneSegments.ps1 -Discover'
    Write-Host ''
    $candidates = Find-ExportsCandidates -AppName $AppFolderName
    if ($candidates.Count -gt 0) {
        Write-Host 'Folders seen but missing both segment MP4s. Use -AllowPartial or finish export on phone.'
        foreach ($c in $candidates) {
            $seg = Get-SegmentStatus -Directory $c
            Write-Host "  $c  ->  $($seg.Count) segment(s): $($seg -join ', ')"
        }
    }
    Write-Error @"
Could not find iPhone Exports folder (or both segment files).
- Run: .\Sync-IphoneSegments.ps1 -Discover
- In Explorer: This PC -> Apple iPhone -> Internal Storage -> $AppFolderName -> Exports
- Copy address bar path: .\Sync-IphoneSegments.ps1 -SourceRoot '<path>'
- Logs only: .\Sync-IphoneSegments.ps1 -LogsOnly -SourceRoot '<Exports path>'
"@
}

if (-not $LogsOnly) {
    $destRoot = [System.IO.Path]::GetFullPath($DestinationDirectory)
    if (-not $DryRun -and -not (Test-Path -LiteralPath $destRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
    }

    Write-Host "Source (USB / iPhone): $exportsRoot"
    Write-Host "Destination (DLNA library): $destRoot"

    foreach ($name in $SegmentNames) {
        $src = Join-Path $exportsRoot $name
        $dst = Join-Path $destRoot $name
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            Write-Warning "Missing on phone: $name"
            continue
        }
        Copy-SegmentIfNewer -SourcePath $src -DestPath $dst -DryRun:$DryRun
    }
} else {
    Write-Host "Source (USB / iPhone): $exportsRoot"
    Write-Host 'LogsOnly: skipping segment copy.'
}

if (-not $SkipLogs) {
    Copy-ExportLogs -ExportsRoot $exportsRoot -LogDestination $LogDestination -DryRun:$DryRun
}

Write-Host 'Done.'
