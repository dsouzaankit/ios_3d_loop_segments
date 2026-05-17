#Requires -Version 5.1
<#
.SYNOPSIS
  Copy the newest iPhone camera-roll videos (MTP) into the DLNA segment folder as 3d_op_00/01.

.DESCRIPTION
  For Loop Segments v1.2+ with "Save segments to Photos" enabled. Photos land in DCIM or
  monthly folders (e.g. 202605_a) under Internal Storage — not as 3d_op_*.mp4.

  Uses Shell.Application + CopyHere (MTP-safe). Do NOT use Copy-Item on COM .Path values;
  that pattern from generic snippets often fails silently.

  This is NOT a live mirror: run on a schedule or after export. For stable names in app
  storage, use Sync-IphoneSegments.ps1 when Exports is visible, or Apple Devices save +
  Copy-FromIncoming.ps1.

.PARAMETER Discover
  List iPhone MTP folders and newest video candidates.

.PARAMETER NewestCount
  How many recent videos to map to 3d_op_00.mp4 .. 3d_op_(N-1).mp4 (default 2).

.PARAMETER Watch
  Repeat sync every -PollSeconds until you press Enter (run from a console window).

.PARAMETER PollSeconds
  Interval between syncs when -Watch is set (default 60).

.EXAMPLE
  .\Sync-FromIPhonePhotos.ps1 -Discover

.EXAMPLE
  .\Sync-FromIPhonePhotos.ps1 -DestinationDirectory 'F:\f1_media\3d_fullsbs_trans'

.EXAMPLE
  .\Sync-FromIPhonePhotos.ps1 -Watch
#>
[CmdletBinding()]
param(
    [string] $DestinationDirectory = 'F:\f1_media\3d_fullsbs_trans',
    [string] $DeviceNameMatch = 'iPhone|Apple',
    [int] $NewestCount = 2,
    [string] $StagingDirectory = '',
    [int] $PollSeconds = 60,
    [switch] $Discover,
    [switch] $Watch,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$VideoExtensions = @('.mp4', '.mov', '.m4v')
$SegmentNames = @('3d_op_00.mp4', '3d_op_01.mp4')

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

function Get-PhotoMediaFolders {
    param($PhoneFolder)
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

function Show-DiscoverReport {
    param([string] $NameMatch)
    Write-Host ''
    Write-Host '=== Sync-FromIPhonePhotos -Discover ===' -ForegroundColor Cyan
    $phoneFolder, $shell = Get-IPhoneRootFolder -NameMatch $NameMatch
    if (-not $phoneFolder) {
        Write-Host 'No iPhone under This PC. USB + unlock + Trust This Computer.' -ForegroundColor Yellow
        return
    }
    Write-Host "Device: $($phoneFolder.Title)"
    $roots, $notes = Get-PhotoMediaFolders -PhoneFolder $phoneFolder
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
    Write-Host 'Newest two would map to 3d_op_00.mp4 and 3d_op_01.mp4 on the DLNA folder.'
    Write-Host 'If your camera roll has other recent videos, they may be picked instead.'
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
        [int] $NewestCount,
        [string] $StagingDirectory,
        [switch] $DryRun,
        [switch] $VerboseNotes
    )

    if ($NewestCount -lt 1 -or $NewestCount -gt $SegmentNames.Count) {
        throw "NewestCount must be 1..$($SegmentNames.Count)"
    }

    $phoneFolder, $shell = Get-IPhoneRootFolder -NameMatch $DeviceNameMatch
    if (-not $phoneFolder) {
        throw 'Apple iPhone not found under This PC. Plug in USB, unlock, trust PC.'
    }

    try {
        $roots, $notes = Get-PhotoMediaFolders -PhoneFolder $phoneFolder
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

        $pick = $allVideos |
            Sort-Object { Get-ShellFolderItemDate $_ } -Descending |
            Select-Object -First $NewestCount

        if ($pick.Count -lt $NewestCount) {
            Write-Warning "Only $($pick.Count) video(s) found; expected $NewestCount."
        }

        $destRoot = [System.IO.Path]::GetFullPath($DestinationDirectory)
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

        $ordered = @($pick | Sort-Object { Get-ShellFolderItemDate $_ })
        for ($i = 0; $i -lt $ordered.Count; $i++) {
            $item = $ordered[$i]
            $segmentName = $SegmentNames[$i]
            $finalPath = Join-Path $destRoot $segmentName
            Write-Host "MTP: $($item.Name) -> $segmentName"

            if ($DryRun) {
                Write-Host "  Would copy to $finalPath"
                continue
            }

            Get-ChildItem -LiteralPath $staging -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Invoke-MtpCopyHere -Shell $shell -DestFolderPath $staging -SourceItem $item
            $staged = Wait-ForStagedFile -Directory $staging -LeafName ([string]$item.Name)
            if (-not $staged) {
                throw "Timed out waiting for MTP copy of $($item.Name)"
            }
            Copy-Item -LiteralPath $staged -Destination $finalPath -Force
            Write-Host "  -> $finalPath"
        }
    } finally {
        if ($shell) {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        }
    }
}

if ($Discover) {
    Show-DiscoverReport -NameMatch $DeviceNameMatch
    return
}

if ($Watch) {
    if ($PollSeconds -lt 5) { throw 'PollSeconds must be at least 5.' }
    $destLabel = [System.IO.Path]::GetFullPath($DestinationDirectory)
    Write-Host "Watch mode: sync every $PollSeconds s -> $destLabel"
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
                -NewestCount $NewestCount `
                -StagingDirectory $StagingDirectory `
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
    -NewestCount $NewestCount `
    -StagingDirectory $StagingDirectory `
    -DryRun:$DryRun `
    -VerboseNotes
Write-Host 'Done.'
