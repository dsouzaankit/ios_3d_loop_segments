#Requires -Version 5.1
<#
.SYNOPSIS
  Copy the newest iPhone Photos video (MTP) into the older of the PC DLNA pair (op_00 / op_01).

.DESCRIPTION
  For Loop Segments with "Save segments to Photos" enabled. The phone keeps one segment file
  (op_00.mp4 in Exports); each minute overwrites it and adds a new Photos clip (often IMG_*.mp4
  under the latest month folder, e.g. 202605_a).

  Each run: take the **newest** video in the scan, always copy it, and **overwrite** the older of
  the two PC DLNA slots (or op_00, then op_01, if a slot is missing). No dedup — backward
  jumps in an endlessly looping DLNA player are expected.

  Uses Shell.Application + CopyHere (MTP-safe). Do NOT use Copy-Item on COM .Path values.

.PARAMETER Discover
  List iPhone MTP folders and newest video candidates.

.PARAMETER LegacyDualMap
  Old behavior: copy the two newest phone videos to op_00 and op_01 by date order.

.PARAMETER Watch
  Repeat sync every -PollSeconds until you press Enter (run from a console window).

.PARAMETER PollSeconds
  Interval between syncs when -Watch is set (default 60).

.PARAMETER AllMonthFolders
  Search every YYYYMM_x folder. Default: only DCIM + the latest month folder.

.EXAMPLE
  .\Sync-FromIPhonePhotos.ps1 -Discover

.EXAMPLE
  .\Set-LoopSegmentsDestination.ps1 'D:\media\3d_fullsbs_trans'
  .\Sync-FromIPhonePhotos.ps1 -Watch
#>
[CmdletBinding()]
param(
    [string] $DestinationDirectory = '',
    [string] $DeviceNameMatch = 'iPhone|Apple',
    [string] $StagingDirectory = '',
    [int] $PollSeconds = 60,
    [switch] $Discover,
    [switch] $Watch,
    [switch] $AllMonthFolders,
    [switch] $LegacyDualMap,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\LoopSegments-Config.ps1"
if ([string]::IsNullOrWhiteSpace($DestinationDirectory)) {
    $DestinationDirectory = Get-LoopSegmentsDestinationDirectory
}

$VideoExtensions = @('.mp4', '.mov', '.m4v')
$SegmentNames = @('op_00.mp4', 'op_01.mp4')
$SegmentExportNamePattern = '^op_\d{2}\.mp4$'

# Shell FileOperation flags (FOF_*)
$CopyHereFlags = 0x14  # FOF_NOCONFIRMATION | FOF_NOERRORUI

function Get-ShellFolderItemDate {
    param($Item)
    try {
        if ($null -ne $Item.ModifyDate -and $Item.ModifyDate -is [datetime]) {
            return $Item.ModifyDate
        }
    } catch { }
    try {
        if ($null -ne $Item.DateModified -and $Item.DateModified -is [datetime]) {
            return $Item.DateModified
        }
    } catch { }
    return [datetime]::MinValue
}

function Get-IPhoneRootFolder {
    param([string] $NameMatch)
    $shell = New-Object -ComObject Shell.Application
    $computer = $shell.NameSpace(0x11)  # CSIDL_DRIVES / This PC
    if (-not $computer) { return $null, $shell }
    foreach ($item in @($computer.Items())) {
        if ([string]$item.Name -match $NameMatch) {
            $folder = $item.GetFolder()
            if ($folder) { return $folder, $shell }
        }
    }
    return $null, $shell
}

function Get-ChildFolderByName {
    param($ParentFolder, [string[]] $Names)
    foreach ($child in @($ParentFolder.Items())) {
        if (-not $child.IsFolder) { continue }
        if ($Names -contains [string]$child.Name) {
            return $child.GetFolder()
        }
    }
    return $null
}

function Get-MonthlyFolderItems {
    param($InternalFolder)
    return @($InternalFolder.Items() | Where-Object {
        $_.IsFolder -and [string]$_.Name -match '^\d{6}_[a-z]$'
    })
}

function Get-LatestMonthlyFolderItem {
    param($InternalFolder)
    $monthly = Get-MonthlyFolderItems -InternalFolder $InternalFolder
    if ($monthly.Count -eq 0) { return $null }
    return $monthly | Sort-Object { [string]$_.Name } -Descending | Select-Object -First 1
}

function Get-PhotoMediaFolders {
    param(
        $PhoneFolder,
        [switch] $AllMonthFolders
    )
    $internal = Get-ChildFolderByName -ParentFolder $PhoneFolder -Names @('Internal Storage')
    if (-not $internal) {
        return @(), @('Internal Storage not found under iPhone')
    }

    $notes = [System.Collections.Generic.List[string]]::new()
    $mediaRoots = [System.Collections.Generic.List[object]]::new()

    $dcim = Get-ChildFolderByName -ParentFolder $internal -Names @('DCIM')
    if ($dcim) {
        [void]$mediaRoots.Add($dcim)
        [void]$notes.Add('Using Internal Storage\DCIM')
    }

    if ($AllMonthFolders) {
        foreach ($child in @($internal.Items())) {
            if (-not $child.IsFolder) { continue }
            $name = [string]$child.Name
            if ($name -eq 'DCIM') { continue }
            if ($name -match '^\d{6}_[a-z]$' -or $name -match 'APPLE$') {
                $sub = $child.GetFolder()
                if ($sub) {
                    [void]$mediaRoots.Add($sub)
                    [void]$notes.Add("Using Internal Storage\$name")
                }
            }
        }
    } else {
        $latestMonth = Get-LatestMonthlyFolderItem -InternalFolder $internal
        if ($latestMonth) {
            $sub = $latestMonth.GetFolder()
            if ($sub) {
                [void]$mediaRoots.Add($sub)
                [void]$notes.Add("Using latest month folder Internal Storage\$($latestMonth.Name) (Photos export target)")
            }
        } else {
            [void]$notes.Add('No YYYYMM_x month folder found — only DCIM will be scanned')
        }
    }

    if ($mediaRoots.Count -eq 0) {
        [void]$notes.Add('No DCIM or monthly photo folders found. Unlock iPhone; open Photos once.')
    }

    return @($mediaRoots), @($notes)
}

function Get-VideoItemsRecursive {
    param($Folder)
    $videos = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Folder.Items())) {
        if ($item.IsFolder) {
            $sub = $item.GetFolder()
            if ($sub) {
                Get-VideoItemsRecursive -Folder $sub | ForEach-Object { [void]$videos.Add($_) }
            }
            continue
        }
        $ext = [System.IO.Path]::GetExtension([string]$item.Name)
        if ($VideoExtensions -contains $ext.ToLowerInvariant()) {
            [void]$videos.Add($item)
        }
    }
    return $videos
}

function Select-NewestVideo {
    param([System.Collections.Generic.List[object]] $AllVideos)
    if ($AllVideos.Count -eq 0) { return $null }
    return @($AllVideos | Sort-Object { Get-ShellFolderItemDate $_ } -Descending | Select-Object -First 1)[0]
}

function Select-NewestVideosForSegments {
    param(
        [System.Collections.Generic.List[object]] $AllVideos,
        [int] $Count
    )
    $segmentExports = @($AllVideos | Where-Object {
        [string]$_.Name -match $script:SegmentExportNamePattern
    })
    if ($segmentExports.Count -gt 0) {
        return @($segmentExports |
            Sort-Object { Get-ShellFolderItemDate $_ } -Descending |
            Select-Object -First $Count)
    }
    return @($AllVideos |
        Sort-Object { Get-ShellFolderItemDate $_ } -Descending |
        Select-Object -First $Count)
}

function Select-DlnaOverwriteTarget {
    param([string] $DestinationRoot)
    $paths = @(
        (Join-Path $DestinationRoot $SegmentNames[0]),
        (Join-Path $DestinationRoot $SegmentNames[1])
    )
    $exists = @(
        (Test-Path -LiteralPath $paths[0] -PathType Leaf),
        (Test-Path -LiteralPath $paths[1] -PathType Leaf)
    )
    if (-not $exists[0]) { return $paths[0], $SegmentNames[0], 'op_00 missing — initial slot' }
    if (-not $exists[1]) { return $paths[1], $SegmentNames[1], 'op_01 missing — second slot' }
    $t0 = (Get-Item -LiteralPath $paths[0]).LastWriteTimeUtc
    $t1 = (Get-Item -LiteralPath $paths[1]).LastWriteTimeUtc
    if ($t0 -le $t1) {
        return $paths[0], $SegmentNames[0], 'overwrite older PC slot (op_00)'
    }
    return $paths[1], $SegmentNames[1], 'overwrite older PC slot (op_01)'
}

function Invoke-MtpCopyHere {
    param(
        $Shell,
        [string] $DestFolderPath,
        $SourceItem
    )
    $destNs = $Shell.NameSpace($DestFolderPath)
    if (-not $destNs) { throw "Cannot open destination namespace: $DestFolderPath" }
    $destNs.CopyHere($SourceItem, $CopyHereFlags)
}

function Wait-ForStagedFile {
    param(
        [string] $Directory,
        [string] $LeafName,
        [int] $TimeoutSeconds = 120
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $path = Join-Path $Directory $LeafName
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $f = Get-Item -LiteralPath $path -ErrorAction Stop
                if ($f.Length -gt 0) { return $path }
            } catch { }
        }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

function Copy-MtpVideoToPath {
    param(
        $Shell,
        [string] $StagingDirectory,
        $SourceItem,
        [string] $FinalPath,
        [switch] $DryRun
    )
    $leaf = [string]$SourceItem.Name
    if ($DryRun) {
        Write-Host "  Would copy to $FinalPath"
        return
    }
    Get-ChildItem -LiteralPath $StagingDirectory -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Invoke-MtpCopyHere -Shell $Shell -DestFolderPath $StagingDirectory -SourceItem $SourceItem
    $staged = Wait-ForStagedFile -Directory $StagingDirectory -LeafName $leaf
    if (-not $staged) {
        throw "Timed out waiting for MTP copy of $leaf"
    }
    Copy-Item -LiteralPath $staged -Destination $FinalPath -Force
    Write-Host "  -> $FinalPath"
}

function Show-DiscoverReport {
    param(
        [string] $NameMatch,
        [switch] $AllMonthFolders
    )
    Write-Host ''
    Write-Host '=== Sync-FromIPhonePhotos -Discover ===' -ForegroundColor Cyan
    $phoneFolder, $shell = Get-IPhoneRootFolder -NameMatch $NameMatch
    if (-not $phoneFolder) {
        Write-Host 'No iPhone under This PC. USB + unlock + Trust This Computer.' -ForegroundColor Yellow
        return
    }
    Write-Host "Device: $($phoneFolder.Title)"
    $roots, $notes = Get-PhotoMediaFolders -PhoneFolder $phoneFolder -AllMonthFolders:$AllMonthFolders
    foreach ($n in $notes) { Write-Host $n }
    if ($roots.Count -eq 0) { return }

    $all = [System.Collections.Generic.List[object]]::new()
    foreach ($root in $roots) {
        Get-VideoItemsRecursive -Folder $root | ForEach-Object { [void]$all.Add($_) }
    }
    Write-Host "Video files found: $($all.Count)"
    $sorted = $all | Sort-Object { Get-ShellFolderItemDate $_ } -Descending
    $sorted | Select-Object -First 8 | ForEach-Object {
        $d = Get-ShellFolderItemDate $_
        $size = ''
        try { $size = "{0:N0} bytes" -f [int64]$_.Size } catch { }
        Write-Host ("  {0:yyyy-MM-dd HH:mm}  {1,-28}  {2}" -f $d, $_.Name, $size)
    }
    Write-Host ''
    $newest = Select-NewestVideo -AllVideos $all
    if ($newest) {
        Write-Host "Sync target: newest file $($newest.Name) -> older of PC op_00 / op_01 (always overwrite)."
    }
    Write-Host 'DLNA player can wait ~60s until both PC slots exist.'
    Write-Host 'Use -LegacyDualMap for old two-newest-phone-files behavior.'
    $dest = Get-LoopSegmentsDestinationDirectory -Override $DestinationDirectory
    Write-Host "DLNA destination: $dest"
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
}

function Test-EnterPressed {
    if (-not [Console]::KeyAvailable) { return $false }
    $key = [Console]::ReadKey($true)
    return ($key.Key -eq 'Enter')
}

function Wait-ForEnterOrSeconds {
    param([int] $Seconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-EnterPressed) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Invoke-PhotoSegmentSync {
    param(
        [string] $DestinationDirectory,
        [string] $DeviceNameMatch,
        [string] $StagingDirectory,
        [switch] $AllMonthFolders,
        [switch] $LegacyDualMap,
        [switch] $DryRun,
        [switch] $VerboseNotes
    )

    $phoneFolder, $shell = Get-IPhoneRootFolder -NameMatch $DeviceNameMatch
    if (-not $phoneFolder) {
        throw 'Apple iPhone not found under This PC. Plug in USB, unlock, trust PC.'
    }

    try {
        $roots, $notes = Get-PhotoMediaFolders -PhoneFolder $phoneFolder -AllMonthFolders:$AllMonthFolders
        if ($VerboseNotes) {
            foreach ($n in $notes) { Write-Host $n }
        }
        if ($roots.Count -eq 0) {
            throw 'No photo folders on iPhone MTP tree. Your device may only show monthly folders — re-run -Discover.'
        }

        $allVideos = [System.Collections.Generic.List[object]]::new()
        foreach ($root in $roots) {
            Get-VideoItemsRecursive -Folder $root | ForEach-Object { [void]$allVideos.Add($_) }
        }
        if ($allVideos.Count -eq 0) {
            throw 'No .mp4/.mov files found. Enable Save segments to Photos and finish at least one 60s segment.'
        }

        $destRoot = Get-LoopSegmentsDestinationDirectory -Override $DestinationDirectory
        Test-LoopSegmentsDestinationReady -Directory $destRoot
        Write-Host "DLNA destination: $destRoot"
        if (-not $DryRun -and -not (Test-Path -LiteralPath $destRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
        }

        if ([string]::IsNullOrWhiteSpace($StagingDirectory)) {
            $StagingDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'LoopSegmentsMtpStaging'
        }
        $staging = [System.IO.Path]::GetFullPath($StagingDirectory)
        if (-not $DryRun -and -not (Test-Path -LiteralPath $staging -PathType Container)) {
            New-Item -ItemType Directory -Path $staging -Force | Out-Null
        }

        if ($LegacyDualMap) {
            $pick = Select-NewestVideosForSegments -AllVideos $allVideos -Count 2
            if ($pick.Count -lt 2) {
                Write-Warning "Only $($pick.Count) video(s) found; legacy mode expects 2."
            }
            $ordered = @($pick | Sort-Object { Get-ShellFolderItemDate $_ })
            for ($i = 0; $i -lt $ordered.Count; $i++) {
                $item = $ordered[$i]
                $segmentName = $SegmentNames[$i]
                $finalPath = Join-Path $destRoot $segmentName
                Write-Host "MTP (legacy): $($item.Name) -> $segmentName"
                Copy-MtpVideoToPath -Shell $shell -StagingDirectory $staging -SourceItem $item -FinalPath $finalPath -DryRun:$DryRun
            }
            return
        }

        $newest = Select-NewestVideo -AllVideos $allVideos
        if (-not $newest) {
            throw 'No video selected from iPhone scan.'
        }

        $finalPath, $segmentName, $reason = Select-DlnaOverwriteTarget -DestinationRoot $destRoot
        Write-Host "MTP: $($newest.Name) -> $segmentName ($reason)"
        Copy-MtpVideoToPath -Shell $shell -StagingDirectory $staging -SourceItem $newest -FinalPath $finalPath -DryRun:$DryRun
    } finally {
        if ($shell) {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        }
    }
}

if ($Discover) {
    Show-DiscoverReport -NameMatch $DeviceNameMatch -AllMonthFolders:$AllMonthFolders
    return
}

if ($Watch) {
    if ($PollSeconds -lt 5) { throw 'PollSeconds must be at least 5.' }
    $destLabel = [System.IO.Path]::GetFullPath($DestinationDirectory)
    Write-Host "Watch mode: newest phone clip -> older PC DLNA slot every $PollSeconds s -> $destLabel"
    Write-Host 'Press Enter to stop (keep this window open; iPhone unlocked on USB).'
    Write-Host ''

    $iteration = 0
    while ($true) {
        $iteration++
        Write-Host "--- Sync #$iteration  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ---" -ForegroundColor Cyan
        try {
            Invoke-PhotoSegmentSync `
                -DestinationDirectory $DestinationDirectory `
                -DeviceNameMatch $DeviceNameMatch `
                -StagingDirectory $StagingDirectory `
                -AllMonthFolders:$AllMonthFolders `
                -LegacyDualMap:$LegacyDualMap `
                -DryRun:$DryRun `
                -VerboseNotes:($iteration -eq 1)
        } catch {
            Write-Warning $_.Exception.Message
        }

        Write-Host "Next sync in $PollSeconds s (Enter to stop)..."
        if (Wait-ForEnterOrSeconds -Seconds $PollSeconds) {
            Write-Host 'Stopped.'
            break
        }
    }
    return
}

Invoke-PhotoSegmentSync `
    -DestinationDirectory $DestinationDirectory `
    -DeviceNameMatch $DeviceNameMatch `
    -StagingDirectory $StagingDirectory `
    -AllMonthFolders:$AllMonthFolders `
    -LegacyDualMap:$LegacyDualMap `
    -DryRun:$DryRun `
    -VerboseNotes
Write-Host 'Done.'
