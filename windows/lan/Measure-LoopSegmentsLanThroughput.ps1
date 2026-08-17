# Entry may start under Windows PowerShell 5.1; re-launch with pwsh.
<#
.SYNOPSIS
  Measure LAN throughput via phone HTTP and/or rclone mount (L:).

.DESCRIPTION
  Prefers a random media file under phone pcld_ios_media/archive/ (>= -MinBytes).
  If archive/ is empty, falls back to other phone media (loop/root/etc.).

  Default: times both phone HTTP GET and an rclone mount copy of the same file.
  Bitrate recommendation / low-throughput recovery use the lesser measured Mbps
  (then RecommendHeadroom). Mount-only numbers can still look cache-inflated; the
  lesser pick keeps an inflated mount from raising the encode cap.

  If that Mbps is below minLanThroughputMbps (default 40), reboots Wi-Fi on every
  known router except the PC's current default gateway (suspected cause: Wi-Fi
  channel congestion from neighboring APs; the app LAN AP is tethered to a primary
  router and those two channels must match), waits to settle, and re-measures.
  Repeats until throughput is at least the minimum or 2 retries.

  -HttpOnly / -ViaMount select a single path. Not 5G WAN internet speed.

  Do not run this probe during an active Virtual Desktop headset session — VD
  streaming the PC screen uses about 50 Mbps of LAN and will understate phone LAN.

  When run directly (double-click / console), waits for Enter before closing so you can
  read the Mbps result. Pass -NoWaitEnter (or -NoWaitEnterOnLowThroughputStop) when
  invoked as a child so the parent keeps a single prompt.

  Prefer: pwsh -File .\lan\Measure-LoopSegmentsLanThroughput.ps1 (or companion).
  Opening under Windows PowerShell 5.1 re-launches pwsh.

  Remap the rclone letter (default L:) if the mount is missing, hung, or died after a
  Wi-Fi bounce: .\rclone\Mount-LoopSegmentsRclone.ps1 -Unstick then .\rclone\Mount-LoopSegmentsRclone.ps1 (leave open).

.EXAMPLE
  .\rclone\Mount-LoopSegmentsRclone.ps1   # leave window open
  .\lan\Measure-LoopSegmentsLanThroughput.ps1

.EXAMPLE
  .\lan\Measure-LoopSegmentsLanThroughput.ps1 -MaxBytes 0 -KeepLocal
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]$')]
    [string] $DriveLetter = '',
    [string] $MediaRelativePath = 'pcld_ios_media',
    [string] $SourcePath = '',
    [string] $OutFile = '',
    [long] $MinBytes = 8MB,
    [long] $MaxBytes = 64MB,
    [int] $WaitMountSec = 45,
    [int] $BufferBytes = 4MB,
    # Fraction of measured LAN Mbps used as recommended max media/encode bitrate (headroom for HTTP/rclone/player).
    [ValidateRange(0.1, 1.0)]
    [double] $RecommendHeadroom = 0.8,
    [int] $RecommendMinMbps = 5,
    [int] $RecommendMaxMbps = 100,
    # After measure: if throughput is below this, reboot other routers (not the current gateway), settle, re-check.
    # 0 = use minLanThroughputMbps from loop-segments-windows.json (default 40).
    [double] $LowThroughputMbps = 0,
    [int] $PostRebootSettleSec = 20,
    [ValidateRange(0, 10)]
    [int] $LowThroughputRetries = 2,
    [switch] $SkipLowThroughputGatewayReboot,
    # Only time phone HTTP GET (skip rclone mount copy).
    [switch] $HttpOnly,
    # Only time a copy from L: (rclone VFS cache can inflate Mbps).
    [switch] $ViaMount,
    # When set (companion/automation child): do not wait for Enter; parent prompts instead.
    [switch] $NoWaitEnter,
    # Alias of -NoWaitEnter (kept for companion callers).
    [switch] $NoWaitEnterOnLowThroughputStop,
    [switch] $SkipSidecarWrite,
    [switch] $KeepLocal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PwshHelper = Join-Path $PSScriptRoot '..\lib\Get-LoopSegmentsPwsh.ps1'
if (-not (Test-Path -LiteralPath $PwshHelper)) {
    throw "Missing $PwshHelper"
}
. $PwshHelper
Ensure-LoopSegmentsPwshHost -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

$skipEnterPrompt = [bool]($NoWaitEnter -or $NoWaitEnterOnLowThroughputStop)

function Wait-EnterToClose {
    if ($skipEnterPrompt) { return }
    Write-Host ""
    Write-Host 'Press Enter to close...' -ForegroundColor Yellow
    try {
        [void][Console]::ReadLine()
    } catch {
        Read-Host | Out-Null
    }
}

# When this script is the console entry (not via companion), pause on fatal errors.
trap {
    Write-Host ""
    Write-Host ("[lan-bw] {0}" -f $_.Exception.Message) -ForegroundColor Red
    if ("$($_.Exception.Message)" -match 'Cannot find drive') {
        if (Get-Command Write-MountRemapHint -ErrorAction SilentlyContinue) {
            $hintLetter = 'L'
            if (Get-Command Get-LoopSegmentsMountDriveLetter -ErrorAction SilentlyContinue) {
                $hintLetter = Get-LoopSegmentsMountDriveLetter -Override $DriveLetter
            }
            Write-MountRemapHint -DriveLetter $hintLetter
        }
    }
    Wait-EnterToClose
    if ($skipEnterPrompt) {
        throw $_
    }
    exit 1
}

. "$PSScriptRoot\..\lib\LoopSegments-Windows.ps1"
$VdHelper = Join-Path $PSScriptRoot '..\lib\Get-LoopSegmentsVirtualDesktop.ps1'
if (Test-Path -LiteralPath $VdHelper) {
    . $VdHelper
}

function Format-Bytes {
    param([long] $Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function Write-MountRemapHint {
    param([string] $DriveLetter = 'L')
    $letter = ([string]$DriveLetter).Trim().TrimEnd(':')
    if ([string]::IsNullOrWhiteSpace($letter)) { $letter = 'L' }
    $mountPs1 = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\rclone\Mount-LoopSegmentsRclone.ps1'))
    Write-Host ""
    Write-Host ("[lan-bw] {0}: does not exist. Remap it - Unstick if stale/hung, then remount and leave that window open:" -f $letter) -ForegroundColor Yellow
    Write-Host ("  {0} -Unstick" -f $mountPs1)
    Write-Host ("  {0}" -f $mountPs1)
    Write-Host ""
}

function Test-MountDrivePresent {
    param([Parameter(Mandatory = $true)][string] $Root)
    $name = ([string]$Root).Trim().Substring(0, 1)
    return $null -ne (Get-PSDrive -Name $name -PSProvider FileSystem -ErrorAction SilentlyContinue)
}

function Test-MountRootReady {
    param([Parameter(Mandatory = $true)][string] $Root)
    # Missing letter: Get-PSDrive / Test-Path -ErrorAction SilentlyContinue (EAP Stop would throw).
    if (-not (Test-MountDrivePresent -Root $Root)) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $Root -ErrorAction SilentlyContinue)) { return $false }
        $null = Get-ChildItem -LiteralPath $Root -ErrorAction Stop | Select-Object -First 1
        return $true
    } catch {
        return $false
    }
}

function Wait-MountRootReady {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][int] $TimeoutSec
    )
    if (Test-MountRootReady -Root $Root) { return $true }
    if (-not (Test-MountDrivePresent -Root $Root)) { return $false }
    if ($TimeoutSec -le 0) { return $false }
    Write-Host ("[lan-bw] Waiting up to {0}s for mount {1} ..." -f $TimeoutSec, $Root)
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Test-MountRootReady -Root $Root) { return $true }
    }
    return (Test-MountRootReady -Root $Root)
}

function Test-IsArchiveMediaRelativePath {
    param([Parameter(Mandatory = $true)][string] $RelativePath)
    $n = $RelativePath.Trim().Replace('\', '/').TrimStart('/').ToLowerInvariant()
    return ($n -match '(^|/)archive/')
}

function Find-RandomPhoneMediaFile {
    param(
        [Parameter(Mandatory = $true)][string] $MediaRoot,
        [Parameter(Mandatory = $true)][long] $MinBytes
    )
    $archiveRoot = Join-Path $MediaRoot 'archive'
    $exts = @('.mp4', '.mov', '.m4v', '.mkv', '.webm')
    $candidates = @()
    if (Test-Path -LiteralPath $archiveRoot) {
        # Flat archive listing only - recursive WinFsp walks are too slow for a probe.
        $candidates = @(Get-ChildItem -LiteralPath $archiveRoot -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Length -ge $MinBytes -and
                ($exts -contains $_.Extension.ToLowerInvariant())
            })
    }
    if ($candidates.Count -eq 0) {
        Write-Warning '[lan-bw] archive/ empty on mount - falling back to other media under pcld_ios_media/.'
        if (-not (Test-Path -LiteralPath $MediaRoot -ErrorAction SilentlyContinue)) {
            throw "Media root not found: $MediaRoot"
        }
        $loopRoot = Join-Path $MediaRoot 'loop'
        $roots = @($MediaRoot)
        if (Test-Path -LiteralPath $loopRoot) { $roots += $loopRoot }
        foreach ($root in $roots) {
            $candidates += @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Length -ge $MinBytes -and
                    ($exts -contains $_.Extension.ToLowerInvariant()) -and
                    ($_.FullName -notmatch '(?i)[\\/]scripts[\\/]')
                })
        }
    }
    if ($candidates.Count -eq 0) {
        throw @"
No media file >= $(Format-Bytes $MinBytes) under $MediaRoot (archive/ empty and no fallback).
Export a video on the phone (or lower -MinBytes), then retry.
"@
    }

    $pick = Get-Random -InputObject $candidates
    Write-Host ('[lan-bw] Picked random mount media ({0} candidates >= {1}): {2}' -f `
        $candidates.Count, (Format-Bytes $MinBytes), $pick.Name)
    return $pick
}

function New-PhoneLanMediaUrlFromRelativePath {
    param([Parameter(Mandatory = $true)][string] $RelativePath)
    $rel = $RelativePath.Trim().TrimStart('/').Replace('\', '/')
    $parts = $rel.Split(@('/'), [System.StringSplitOptions]::RemoveEmptyEntries)
    $encoded = ($parts | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    return ((Get-LoopSegmentsPhoneLanBaseUrl).TrimEnd('/') + '/' + $encoded)
}

function Get-PhoneLanStatusListMediaCandidates {
    param(
        [Parameter(Mandatory = $true)][long] $MinBytes,
        [switch] $ArchiveOnly
    )

    $url = (Get-LoopSegmentsPhoneLanBaseUrl).TrimEnd('/') + '/status_lists.json'
    $auth = Get-LoopSegmentsPhoneWebDavAuthHeader
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = 'GET'
    $req.Timeout = 20000
    $req.ReadWriteTimeout = 20000
    $req.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
    foreach ($key in $auth.Keys) {
        $req.Headers[$key] = [string]$auth[$key]
    }

    $resp = $null
    $reader = $null
    try {
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $jsonText = $reader.ReadToEnd()
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($resp) { $resp.Dispose() }
    }

    $lists = $jsonText | ConvertFrom-Json
    $exts = @('.mp4', '.mov', '.m4v', '.mkv', '.webm')
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($file in @($lists.files)) {
        if ($null -eq $file) { continue }
        $name = [string]$file.name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $bytes = [long]0
        if ($null -ne $file.bytes) {
            try { $bytes = [int64]$file.bytes } catch { $bytes = 0 }
        }
        if ($bytes -lt $MinBytes) { continue }
        $isArchive = Test-IsArchiveMediaRelativePath -RelativePath $name
        if ($ArchiveOnly -and -not $isArchive) { continue }
        if (-not $ArchiveOnly -and $isArchive) { continue }
        $ext = [System.IO.Path]::GetExtension($name).ToLowerInvariant()
        if ($exts -notcontains $ext) { continue }
        $sourceTag = if ($isArchive) { 'status_lists/archive' } else { 'status_lists' }
        [void]$out.Add([pscustomobject]@{
                Name   = $name.TrimStart('/')
                Bytes  = $bytes
                Url    = (New-PhoneLanMediaUrlFromRelativePath -RelativePath $name)
                Source = $sourceTag
            })
    }
    return @($out.ToArray())
}

function Add-MountMediaCandidates {
    param(
        [Parameter(Mandatory = $true)][string] $ScanRoot,
        [Parameter(Mandatory = $true)][string] $DriveRoot,
        [Parameter(Mandatory = $true)][long] $MinBytes,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.IList] $Candidates,
        [Parameter(Mandatory = $true)][string] $SourceTag,
        [switch] $ExcludeScripts
    )
    if (-not (Test-Path -LiteralPath $ScanRoot)) { return 0 }
    $seenUrls = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($existing in @($Candidates)) {
        if ($null -eq $existing) { continue }
        [void]$seenUrls.Add([string]$existing.Url)
    }
    $added = 0
    # Non-recursive by default: archive/ is flat; recursive WinFsp listings are very slow.
    $mountFiles = @(Get-ChildItem -LiteralPath $ScanRoot -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Length -ge $MinBytes -and
            (@('.mp4', '.mov', '.m4v', '.mkv', '.webm') -contains $_.Extension.ToLowerInvariant()) -and
            ((-not $ExcludeScripts) -or ($_.FullName -notmatch '(?i)[\\/]scripts[\\/]'))
        })
    foreach ($item in $mountFiles) {
        try {
            $url = Get-PhoneLanUrlForMountPath -DriveRoot $DriveRoot -MountFilePath $item.FullName
        } catch {
            continue
        }
        if (-not $seenUrls.Add($url)) { continue }
        [void]$Candidates.Add([pscustomobject]@{
                Name   = $item.FullName
                Bytes  = [long]$item.Length
                Url    = $url
                Source = $SourceTag
            })
        $added++
    }
    return $added
}

function Test-PhoneLanHttpUrlExists {
    param([Parameter(Mandatory = $true)][string] $Url)
    $auth = Get-LoopSegmentsPhoneWebDavAuthHeader
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'HEAD'
    $req.Timeout = 12000
    $req.ReadWriteTimeout = 12000
    $req.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
    foreach ($key in $auth.Keys) {
        $req.Headers[$key] = [string]$auth[$key]
    }
    $resp = $null
    try {
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        return ($code -ge 200 -and $code -lt 300)
    } catch {
        return $false
    } finally {
        if ($resp) { $resp.Dispose() }
    }
}

function Find-RandomPhoneLanHttpTarget {
    param(
        [Parameter(Mandatory = $true)][long] $MinBytes,
        [string] $MediaRoot = '',
        [string] $DriveRoot = '',
        [int] $MaxHeadAttempts = 8
    )

    $candidates = New-Object System.Collections.Generic.List[object]
    try {
        Write-Host '[lan-bw] Loading archive media candidates from phone status_lists.json ...'
        $fromStatus = @(Get-PhoneLanStatusListMediaCandidates -MinBytes $MinBytes -ArchiveOnly)
        Write-Host ('[lan-bw] status_lists.json archive/: {0} media file(s) >= {1}' -f $fromStatus.Count, (Format-Bytes $MinBytes))
        foreach ($row in $fromStatus) { [void]$candidates.Add($row) }
    } catch {
        Write-Warning ("[lan-bw] status_lists.json failed: {0}" -f $_.Exception.Message)
    }

    # Avoid recursive rclone/WinFsp archive walks when the phone already listed files (very slow).
    if ($candidates.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($MediaRoot)) {
        $archiveRoot = Join-Path $MediaRoot 'archive'
        Write-Host ('[lan-bw] status_lists archive empty - shallow mount list {0} ...' -f $archiveRoot)
        $added = Add-MountMediaCandidates -ScanRoot $archiveRoot -DriveRoot $DriveRoot -MinBytes $MinBytes `
            -Candidates $candidates -SourceTag 'mount/archive'
        Write-Host ('[lan-bw] Mount archive candidates: {0}' -f $added)
    } elseif ($candidates.Count -gt 0) {
        Write-Host '[lan-bw] Skipping mount archive scan (using status_lists.json).'
    }

    if ($candidates.Count -eq 0) {
        Write-Warning '[lan-bw] archive/ is empty (or no file >= MinBytes) - falling back to other phone media.'
        try {
            $fromStatusAny = @(Get-PhoneLanStatusListMediaCandidates -MinBytes $MinBytes)
            Write-Host ('[lan-bw] status_lists.json (non-archive): {0} media file(s) >= {1}' -f $fromStatusAny.Count, (Format-Bytes $MinBytes))
            foreach ($row in $fromStatusAny) { [void]$candidates.Add($row) }
        } catch {
            Write-Warning ("[lan-bw] status_lists.json fallback failed: {0}" -f $_.Exception.Message)
        }
        if ($candidates.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($MediaRoot) -and (Test-Path -LiteralPath $MediaRoot -ErrorAction SilentlyContinue)) {
            Write-Host ('[lan-bw] Shallow mount list of media root {0} (no recurse)...' -f $MediaRoot)
            $null = Add-MountMediaCandidates -ScanRoot $MediaRoot -DriveRoot $DriveRoot -MinBytes $MinBytes `
                -Candidates $candidates -SourceTag 'mount/fallback' -ExcludeScripts
            $loopRoot = Join-Path $MediaRoot 'loop'
            if (Test-Path -LiteralPath $loopRoot) {
                $null = Add-MountMediaCandidates -ScanRoot $loopRoot -DriveRoot $DriveRoot -MinBytes $MinBytes `
                    -Candidates $candidates -SourceTag 'mount/fallback/loop'
            }
            Write-Host ('[lan-bw] Fallback candidates: {0}' -f $candidates.Count)
        }
    }

    if ($candidates.Count -eq 0) {
        throw @"
No HTTP-reachable media file >= $(Format-Bytes $MinBytes) under pcld_ios_media/ (archive/ empty and no fallback media).
Export or archive a video on the phone (or lower -MinBytes), then retry.
"@
    }

    $take = [Math]::Min([Math]::Max(1, $MaxHeadAttempts), $candidates.Count)
    $order = @($candidates | Get-Random -Count $take)
    $tried = 0
    foreach ($pick in $order) {
        $tried++
        if (Test-PhoneLanHttpUrlExists -Url $pick.Url) {
            Write-Host ('[lan-bw] Picked random LAN media ({0}/{1} tried, via {2}): {3}' -f `
                $tried, $order.Count, $pick.Source, $pick.Name)
            return $pick
        }
        Write-Warning ("[lan-bw] Skip (HTTP HEAD failed): {0}" -f $pick.Url)
    }

    Write-MountRemapHint -DriveLetter $letter
    throw ('No candidate passed HTTP HEAD after {0} attempt(s). Remap {1}: or wait for the phone LAN index to refresh, then retry.' -f $tried, $letter)
}

function Copy-FileMeasured {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination,
        [Parameter(Mandatory = $true)][int] $BufferSize,
        [long] $LimitBytes = 0
    )

    $buffer = New-Object byte[] $BufferSize
    $src = $null
    $dst = $null
    $total = [long]0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $src = [System.IO.File]::Open(
            $Source,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $dst = [System.IO.File]::Create($Destination)
        while ($true) {
            $toRead = $buffer.Length
            if ($LimitBytes -gt 0) {
                $left = $LimitBytes - $total
                if ($left -le 0) { break }
                if ($left -lt $toRead) { $toRead = [int]$left }
            }
            $n = $src.Read($buffer, 0, $toRead)
            if ($n -le 0) { break }
            $dst.Write($buffer, 0, $n)
            $total += $n
        }
    } finally {
        $sw.Stop()
        if ($dst) { $dst.Dispose() }
        if ($src) { $src.Dispose() }
    }

    return [pscustomobject]@{
        Bytes     = $total
        Seconds   = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
        Stopwatch = $sw
        Method    = 'mount'
        Url       = ''
    }
}

function Get-PhoneLanUrlForMountPath {
    param(
        [Parameter(Mandatory = $true)][string] $DriveRoot,
        [Parameter(Mandatory = $true)][string] $MountFilePath
    )
    $root = $DriveRoot.TrimEnd('\') + '\'
    $full = [System.IO.Path]::GetFullPath($MountFilePath)
    if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Source is not under mount root {0}: {1}" -f $DriveRoot, $MountFilePath)
    }
    $rel = $full.Substring($root.Length).Replace('\', '/')
    $rel = $rel.TrimStart('/')
    if ($rel -notmatch '(?i)^pcld_ios_media(/|$)') {
        $rel = 'pcld_ios_media/' + $rel
    }
    $parts = $rel.Split(@('/'), [System.StringSplitOptions]::RemoveEmptyEntries)
    $encoded = ($parts | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    return ((Get-LoopSegmentsPhoneLanBaseUrl).TrimEnd('/') + '/' + $encoded)
}

function Copy-HttpMeasured {
    param(
        [Parameter(Mandatory = $true)][string] $Url,
        [Parameter(Mandatory = $true)][string] $Destination,
        [Parameter(Mandatory = $true)][int] $BufferSize,
        [long] $LimitBytes = 0
    )

    $auth = Get-LoopSegmentsPhoneWebDavAuthHeader
    $buffer = New-Object byte[] $BufferSize
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.Timeout = 120000
    $req.ReadWriteTimeout = 120000
    $req.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
    foreach ($key in $auth.Keys) {
        $req.Headers[$key] = [string]$auth[$key]
    }

    $resp = $null
    $stream = $null
    $dst = $null
    $total = [long]0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = $req.GetResponse()
        $stream = $resp.GetResponseStream()
        $dst = [System.IO.File]::Create($Destination)
        while ($true) {
            $toRead = $buffer.Length
            if ($LimitBytes -gt 0) {
                $left = $LimitBytes - $total
                if ($left -le 0) { break }
                if ($left -lt $toRead) { $toRead = [int]$left }
            }
            $n = $stream.Read($buffer, 0, $toRead)
            if ($n -le 0) { break }
            $dst.Write($buffer, 0, $n)
            $total += $n
        }
    } finally {
        $sw.Stop()
        if ($dst) { $dst.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($resp) { $resp.Dispose() }
    }

    return [pscustomobject]@{
        Bytes     = $total
        Seconds   = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
        Stopwatch = $sw
        Method    = 'http'
        Url       = $Url
    }
}

function ConvertTo-Ipv4UInt32 {
    param([Parameter(Mandatory = $true)][string] $IpAddress)
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($IpAddress.Trim(), [ref]$parsed)) {
        throw "Invalid IPv4 address: $IpAddress"
    }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Not an IPv4 address: $IpAddress"
    }
    $bytes = $parsed.GetAddressBytes()
    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($bytes)
    }
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Test-SameIpv4Subnet {
    param(
        [Parameter(Mandatory = $true)][string] $IpA,
        [Parameter(Mandatory = $true)][string] $IpB,
        [Parameter(Mandatory = $true)][int] $PrefixLen
    )
    if ($PrefixLen -lt 0 -or $PrefixLen -gt 32) {
        throw "PrefixLength must be 0..32 (got $PrefixLen)"
    }
    $hostBits = 32 - $PrefixLen
    [uint32]$mask = 0
    if ($PrefixLen -ge 32) {
        $mask = [uint32]::MaxValue
    } elseif ($PrefixLen -gt 0) {
        $mask = [uint32](-bnot (([uint32]1 -shl $hostBits) - 1))
    }
    $netA = (ConvertTo-Ipv4UInt32 -IpAddress $IpA) -band $mask
    $netB = (ConvertTo-Ipv4UInt32 -IpAddress $IpB) -band $mask
    return ($netA -eq $netB)
}

function Get-DefaultGatewayInfo {
    $info = [pscustomobject]@{
        Gateway      = $null
        PrefixLength = 24
    }
    try {
        $configs = @(Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object {
                $_.IPv4DefaultGateway -and
                $_.NetAdapter -and
                $_.NetAdapter.Status -eq 'Up'
            })
        foreach ($cfg in $configs) {
            $nextHop = [string]$cfg.IPv4DefaultGateway.NextHop
            if ([string]::IsNullOrWhiteSpace($nextHop) -or $nextHop -eq '0.0.0.0') { continue }
            $info.Gateway = $nextHop.Trim()
            $v4 = @($cfg.IPv4Address) | Select-Object -First 1
            if ($null -ne $v4 -and $null -ne $v4.PrefixLength -and [int]$v4.PrefixLength -gt 0) {
                $info.PrefixLength = [int]$v4.PrefixLength
            }
            return $info
        }
    } catch {}
    try {
        $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1
        if ($route) {
            $info.Gateway = ([string]$route.NextHop).Trim()
            try {
                $addr = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
                    Where-Object { $_.IPAddress -and $_.IPAddress -notlike '169.254.*' } |
                    Select-Object -First 1
                if ($addr -and $addr.PrefixLength -gt 0) {
                    $info.PrefixLength = [int]$addr.PrefixLength
                }
            } catch {}
        }
    } catch {}
    return $info
}

function Invoke-RebootOtherRoutersForLowThroughput {
    param(
        [Parameter(Mandatory = $true)][double] $MeasuredMbps,
        [Parameter(Mandatory = $true)][double] $ThresholdMbps,
        [Parameter(Mandatory = $true)][int] $SettleSec
    )

    $gwInfo = Get-DefaultGatewayInfo
    $gatewayIp = [string]$gwInfo.Gateway
    Write-Host ""
    Write-Host ('[lan-bw] WARNING: LAN throughput {0:N1} Mbps is below {1} Mbps.' -f $MeasuredMbps, $ThresholdMbps) -ForegroundColor Yellow
    Write-Host ('[lan-bw] Rebooting Wi-Fi on other routers/gateways (not current gateway {0}).' -f $(if ($gatewayIp) { $gatewayIp } else { '(unknown)' })) -ForegroundColor Yellow

    $rebootPs1 = Join-Path $PSScriptRoot 'Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1'
    if (-not (Test-Path -LiteralPath $rebootPs1)) {
        Write-Warning ("[lan-bw] Missing {0} - cannot reboot other routers." -f $rebootPs1)
        return $false
    }

    $psArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $rebootPs1,
        '-RebootOtherRouters',
        '-NoWaitEnter'
    )
    Write-Host ('[lan-bw] > pwsh {0}' -f ($psArgs -join ' '))
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & (Get-LoopSegmentsPwshExe) @psArgs
        $code = 0
        if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) {
        Write-Warning ("[lan-bw] Other-router reboot failed (exit {0})." -f $code)
        return $false
    }

    $settle = [Math]::Max(1, $SettleSec)
    Write-Host ('[lan-bw] Waiting {0}s for Wi-Fi to settle, then re-checking throughput...' -f $settle) -ForegroundColor Cyan
    Start-Sleep -Seconds $settle
    if (-not (Test-MountRootReady -Root $driveRoot)) {
        Write-MountRemapHint -DriveLetter $letter
    }
    return $true
}

$letter = Get-LoopSegmentsMountDriveLetter -Override $DriveLetter
$driveRoot = "${letter}:\"
$mediaRoot = Join-Path $driveRoot $MediaRelativePath.TrimStart('\')

function Resolve-LoopSegmentsMountMediaRoot {
    param(
        [Parameter(Mandatory = $true)][string] $DriveRoot,
        [Parameter(Mandatory = $true)][string] $PreferredRelative
    )
    $root = $DriveRoot.TrimEnd('\')
    # Mount may already start at pcld_ios_media (L:\loop, L:\archive). Prefer that even if a
    # nested L:\pcld_ios_media exists from an older sidecar write.
    foreach ($n in @('archive', 'loop', 'scripts')) {
        if (Test-Path -LiteralPath (Join-Path $root $n) -ErrorAction SilentlyContinue) {
            return $root
        }
    }
    $preferred = Join-Path $root $PreferredRelative.TrimStart('\')
    if (Test-Path -LiteralPath $preferred -ErrorAction SilentlyContinue) {
        return $preferred
    }
    return $preferred
}

Write-Host ('[lan-bw] Mount drive: {0} (from loop-segments-windows.json / -DriveLetter)' -f $driveRoot)
if ($HttpOnly -and $ViaMount) {
    throw '[lan-bw] Use only one of -HttpOnly / -ViaMount (default measures both).'
}
$doHttp = -not $ViaMount
$doMount = -not $HttpOnly
if ($doHttp -and $doMount) {
    Write-Host '[lan-bw] Measures both phone HTTP GET and rclone mount copy (same file when possible).'
} elseif ($doHttp) {
    Write-Host '[lan-bw] Measures phone HTTP GET only (-HttpOnly).'
} else {
    Write-Host '[lan-bw] Measures rclone mount copy only (-ViaMount). Cache can inflate Mbps.'
}
$minLanMbps = Get-LoopSegmentsMinLanThroughputMbps -Override $LowThroughputMbps
Write-Host ('[lan-bw] Min LAN throughput: {0} Mbps — below this, reboot other routers and re-check (up to {1} retr{2})' -f $minLanMbps, $LowThroughputRetries, $(if ($LowThroughputRetries -eq 1) { 'y' } else { 'ies' }))
Write-Host '[lan-bw] Do not run this probe while a Virtual Desktop headset session is active — VD streaming the PC screen uses ~50 Mbps of LAN and will understate phone LAN capacity.' -ForegroundColor Yellow
$vdRunning = $false
try {
    $vdRunning = [bool]((Get-Command Test-LoopSegmentsVdStreamerRunning -ErrorAction SilentlyContinue) -and (Test-LoopSegmentsVdStreamerRunning))
} catch {}
if ($vdRunning) {
    Write-Warning '[lan-bw] Virtual Desktop Streamer is running now. Pause the VD session (or quit Streamer) before trusting this Mbps result.'
}

$mountReady = $false
if ($doMount -or -not $HttpOnly) {
    $mountReady = Wait-MountRootReady -Root $driveRoot -TimeoutSec $WaitMountSec
    if (-not $mountReady -and $doMount) {
        if ($doHttp) {
            Write-Warning ("[lan-bw] Mount {0} not ready - falling back to HTTP-only." -f $driveRoot)
            Write-MountRemapHint -DriveLetter $letter
            $doMount = $false
        } else {
            Write-MountRemapHint -DriveLetter $letter
            throw "[lan-bw] Mount $driveRoot is not ready. Remap ${letter}: (see commands above), then re-run this script."
        }
    }
    if (-not $mountReady -and $doHttp -and -not $doMount) {
        Write-Host '[lan-bw] HTTP-only: no mount sidecars / mount scan.'
    }
} else {
    # -HttpOnly with WaitMountSec 0: do not block on L:
    $mountReady = Test-MountRootReady -Root $driveRoot
    if (-not $mountReady) {
        Write-Host '[lan-bw] HTTP-only: skipping mount wait.'
        Write-MountRemapHint -DriveLetter $letter
    }
}

$scanMediaRoot = ''
if ($mountReady) {
    $mediaRoot = Resolve-LoopSegmentsMountMediaRoot -DriveRoot $driveRoot -PreferredRelative $MediaRelativePath
    $scanMediaRoot = $mediaRoot
    Write-Host ('[lan-bw] Media root: {0}' -f $mediaRoot)
}

function Resolve-MountPathFromLanName {
    param(
        [Parameter(Mandatory = $true)][string] $DriveRoot,
        [Parameter(Mandatory = $true)][string] $NameOrPath
    )
    if (Test-Path -LiteralPath $NameOrPath -PathType Leaf) {
        return (Get-Item -LiteralPath $NameOrPath).FullName
    }
    $rel = $NameOrPath.Trim().TrimStart('/').Replace('/', '\')
    $candidate = Join-Path $DriveRoot.TrimEnd('\') $rel
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Get-Item -LiteralPath $candidate).FullName
    }
    $stripped = $rel -replace '(?i)^pcld_ios_media\\', ''
    if ($stripped -ne $rel) {
        $alt = Join-Path $DriveRoot.TrimEnd('\') $stripped
        if (Test-Path -LiteralPath $alt -PathType Leaf) {
            return (Get-Item -LiteralPath $alt).FullName
        }
    }
    return $null
}

function Get-MeasuredMbps {
    param($Result)
    $mb = $Result.Bytes / 1MB
    return [pscustomobject]@{
        MegabitsPerSec  = (8.0 * $mb) / $Result.Seconds
        MegabytesPerSec = $mb / $Result.Seconds
        MB              = $mb
        Bytes           = $Result.Bytes
        Seconds         = $Result.Seconds
        Method          = $Result.Method
        Url             = $Result.Url
    }
}

$measureUrl = ''
$source = ''
$mountSource = $null
$sourceBytes = [long]0

if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
    $source = $SourcePath.Trim()
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "SourcePath not found: $source"
    }
    $sourceItem = Get-Item -LiteralPath $source
    $mountSource = $sourceItem.FullName
    $sourceBytes = [long]$sourceItem.Length
    $measureUrl = Get-PhoneLanUrlForMountPath -DriveRoot $driveRoot -MountFilePath $mountSource
} else {
    $target = Find-RandomPhoneLanHttpTarget -MinBytes $MinBytes -MediaRoot $scanMediaRoot -DriveRoot $driveRoot
    $source = [string]$target.Name
    $sourceBytes = [long]$target.Bytes
    $measureUrl = [string]$target.Url
    $mountSource = $null
    if ($mountReady) {
        $mountSource = Resolve-MountPathFromLanName -DriveRoot $driveRoot -NameOrPath $source
    }
    if ([string]::IsNullOrWhiteSpace($mountSource) -and $doMount) {
        Write-Warning '[lan-bw] Could not map pick to a mount path - choosing a random mount file for the rclone leg.'
        $sourceItem = Find-RandomPhoneMediaFile -MediaRoot $mediaRoot -MinBytes $MinBytes
        $mountSource = $sourceItem.FullName
        if ([string]::IsNullOrWhiteSpace($measureUrl) -or -not $doHttp) {
            $source = $mountSource
            $sourceBytes = [long]$sourceItem.Length
            $measureUrl = Get-PhoneLanUrlForMountPath -DriveRoot $driveRoot -MountFilePath $mountSource
        }
    }
}

Write-Host ('[lan-bw] Source: {0}' -f $source)
if ($mountSource -and ($mountSource -ne $source)) {
    Write-Host ('[lan-bw] Mount:  {0}' -f $mountSource)
}
Write-Host ('[lan-bw] Size:   {0}' -f (Format-Bytes $sourceBytes))
if ($MaxBytes -gt 0) {
    Write-Host ('[lan-bw] Cap transfer at {0} (-MaxBytes)' -f (Format-Bytes $MaxBytes))
}

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $OutFile = Join-Path $env:TEMP ('loopsegments-lan-bw-{0:yyyyMMdd-HHmmss}.bin' -f (Get-Date))
} else {
    $parent = Split-Path -Parent $OutFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

$outHttp = "$OutFile.http"
$outMount = "$OutFile.mount"
$httpStats = $null
$mountStats = $null

if ($doHttp) {
    if ([string]::IsNullOrWhiteSpace($measureUrl)) {
        if ([string]::IsNullOrWhiteSpace($mountSource)) {
            throw '[lan-bw] No HTTP URL or mount path available for HTTP measure.'
        }
        $measureUrl = Get-PhoneLanUrlForMountPath -DriveRoot $driveRoot -MountFilePath $mountSource
    }
    Write-Host ''
    Write-Host ('[lan-bw] HTTP GET {0}' -f $measureUrl)
    Write-Host '[lan-bw] Downloading (HTTP)...'
    $httpResult = Copy-HttpMeasured -Url $measureUrl -Destination $outHttp -BufferSize $BufferBytes -LimitBytes $MaxBytes
    $httpStats = Get-MeasuredMbps -Result $httpResult
    Write-Host ('[lan-bw] HTTP:  {0:N1} Mbps ({1:N1} MB/s) - {2} in {3:N2}s' -f `
        $httpStats.MegabitsPerSec, $httpStats.MegabytesPerSec, (Format-Bytes $httpStats.Bytes), $httpStats.Seconds) -ForegroundColor Green
}

if ($doMount) {
    if ([string]::IsNullOrWhiteSpace($mountSource) -or -not (Test-Path -LiteralPath $mountSource -PathType Leaf)) {
        throw '[lan-bw] No mount source file available for rclone measure.'
    }
    Write-Host ''
    Write-Host ('[lan-bw] Mount copy {0}' -f $mountSource)
    Write-Host '[lan-bw] Copying (rclone/WinFsp)...'
    $mountResult = Copy-FileMeasured -Source $mountSource -Destination $outMount -BufferSize $BufferBytes -LimitBytes $MaxBytes
    $mountStats = Get-MeasuredMbps -Result $mountResult
    Write-Host ('[lan-bw] Mount: {0:N1} Mbps ({1:N1} MB/s) - {2} in {3:N2}s' -f `
        $mountStats.MegabitsPerSec, $mountStats.MegabytesPerSec, (Format-Bytes $mountStats.Bytes), $mountStats.Seconds) -ForegroundColor Green
    if ($null -ne $httpStats -and $mountStats.MegabitsPerSec -gt ([Math]::Max(500.0, $httpStats.MegabitsPerSec * 5.0))) {
        Write-Warning ('[lan-bw] Mount Mbps looks cache-inflated vs HTTP ({0:N1} vs {1:N1}). Prefer HTTP for LAN capacity.' -f $mountStats.MegabitsPerSec, $httpStats.MegabitsPerSec)
    }
}

# Use the lesser of HTTP / mount for encode recommendation / gateway reboot.
if ($null -ne $httpStats -and $null -ne $mountStats) {
    if ($httpStats.MegabitsPerSec -le $mountStats.MegabitsPerSec) {
        $primary = $httpStats
    } else {
        $primary = $mountStats
    }
    Write-Host ('[lan-bw] Using lesser of HTTP ({0:N1}) and mount ({1:N1}) Mbps.' -f `
        $httpStats.MegabitsPerSec, $mountStats.MegabitsPerSec) -ForegroundColor Cyan
} elseif ($null -ne $httpStats) {
    $primary = $httpStats
} else {
    $primary = $mountStats
}
$mbps = [double]$primary.MegabitsPerSec
$recommendedMbps = [int][Math]::Floor($mbps * $RecommendHeadroom)
if ($recommendedMbps -lt $RecommendMinMbps) { $recommendedMbps = $RecommendMinMbps }
if ($recommendedMbps -gt $RecommendMaxMbps) { $recommendedMbps = $RecommendMaxMbps }

Write-Host ''
Write-Host ('[lan-bw] Primary for bitrate/reboot: {0} (lesser measured path)' -f $primary.Method) -ForegroundColor Cyan
Write-Host ('[lan-bw] Recommended max media bitrate for minute segments: {0} Mbps ({1:P0} of {2}, clamp {3}-{4})' -f `
    $recommendedMbps, $RecommendHeadroom, $primary.Method, $RecommendMinMbps, $RecommendMaxMbps) -ForegroundColor Cyan
Write-Host '[lan-bw] Use this as -SegmentVideoBitrateMbps (hybrid batch / Run-TranscodeFfmpeg) so 60s DLNA slots stay under LAN capacity.'
Write-Host ('[lan-bw] Phone LAN:   {0}' -f (Get-LoopSegmentsPhoneLanBaseUrl))

if (-not $SkipSidecarWrite) {
    if (-not $mountReady) {
        Write-Warning '[lan-bw] Skipping sidecar write (mount not ready).'
    } else {
    $payload = [ordered]@{
        schema                             = 'loopsegments-lan-throughput/v1'
        measureMethod                      = [string]$primary.Method
        measuredMbps                       = [Math]::Round($mbps, 2)
        measuredHttpMbps                   = if ($httpStats) { [Math]::Round([double]$httpStats.MegabitsPerSec, 2) } else { $null }
        measuredMountMbps                  = if ($mountStats) { [Math]::Round([double]$mountStats.MegabitsPerSec, 2) } else { $null }
        recommendedMaxMediaBitrateMbps     = $recommendedMbps
        minLanThroughputMbps               = $minLanMbps
        headroomFactor                     = $RecommendHeadroom
        measuredAtUtc                      = [datetime]::UtcNow.ToString('o')
        phoneLanHost                       = (Get-LoopSegmentsLANHost)
        phoneLanBaseUrl                    = (Get-LoopSegmentsPhoneLanBaseUrl)
        sourcePath                         = $source
        mountSourcePath                    = $mountSource
        sourceUrl                          = $measureUrl
        transferredBytes                   = $primary.Bytes
        elapsedSeconds                     = [Math]::Round($primary.Seconds, 3)
        note                               = 'Default measures HTTP + rclone mount. recommendedMaxMediaBitrateMbps uses the lesser measured Mbps (then headroom), so VFS-cache inflated mount numbers do not raise the encode cap.'
    }
    $json = ($payload | ConvertTo-Json -Depth 4)
    $sidecarPaths = @(
        (Join-Path $mediaRoot 'scripts\lan_throughput.json')
        (Join-Path $mediaRoot 'archive\lan_recommended_segment_bitrate.json')
        (Join-Path $mediaRoot 'lan_recommended_segment_bitrate.json')
    )
    foreach ($sidecar in $sidecarPaths) {
        try {
            $dir = Split-Path -Parent $sidecar
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            Set-Content -LiteralPath $sidecar -Value $json -Encoding UTF8
            Write-Host ('[lan-bw] Wrote recommendation sidecar: {0}' -f $sidecar)
        } catch {
            Write-Warning ("[lan-bw] Could not write sidecar {0}: {1}" -f $sidecar, $_.Exception.Message)
        }
    }
    }
}

$retry = 0
while (
    -not $SkipLowThroughputGatewayReboot -and
    $minLanMbps -gt 0 -and
    $mbps -lt $minLanMbps -and
    $retry -lt $LowThroughputRetries
) {
    $retry++
    Write-Host ""
    Write-Host ('[lan-bw] Retry {0}/{1}: reboot other routers, settle, re-check (now {2:N1} Mbps < {3}).' -f `
        $retry, $LowThroughputRetries, $mbps, $minLanMbps) -ForegroundColor Yellow
    if (-not (Invoke-RebootOtherRoutersForLowThroughput -MeasuredMbps $mbps `
            -ThresholdMbps $minLanMbps -SettleSec $PostRebootSettleSec)) {
        break
    }

    $httpStats = $null
    $mountStats = $null
    $retryMount = $doMount -and (Test-MountRootReady -Root $driveRoot) -and
        $mountSource -and (Test-Path -LiteralPath $mountSource -PathType Leaf -ErrorAction SilentlyContinue)
    if ($doHttp -or -not $retryMount) {
        if ([string]::IsNullOrWhiteSpace($measureUrl)) {
            Write-Warning '[lan-bw] No HTTP URL for re-check - stopping retries.'
            break
        }
        Write-Host ''
        Write-Host ('[lan-bw] Re-check HTTP GET {0}' -f $measureUrl)
        Write-Host '[lan-bw] Downloading (HTTP)...'
        $httpResult = Copy-HttpMeasured -Url $measureUrl -Destination $outHttp -BufferSize $BufferBytes -LimitBytes $MaxBytes
        $httpStats = Get-MeasuredMbps -Result $httpResult
        Write-Host ('[lan-bw] HTTP:  {0:N1} Mbps ({1:N1} MB/s) - {2} in {3:N2}s' -f `
            $httpStats.MegabitsPerSec, $httpStats.MegabytesPerSec, (Format-Bytes $httpStats.Bytes), $httpStats.Seconds) -ForegroundColor Green
    }
    if ($retryMount) {
        Write-Host ''
        Write-Host ('[lan-bw] Re-check mount copy {0}' -f $mountSource)
        $mountResult = Copy-FileMeasured -Source $mountSource -Destination $outMount -BufferSize $BufferBytes -LimitBytes $MaxBytes
        $mountStats = Get-MeasuredMbps -Result $mountResult
        Write-Host ('[lan-bw] Mount: {0:N1} Mbps ({1:N1} MB/s) - {2} in {3:N2}s' -f `
            $mountStats.MegabitsPerSec, $mountStats.MegabytesPerSec, (Format-Bytes $mountStats.Bytes), $mountStats.Seconds) -ForegroundColor Green
    }
    if ($null -ne $httpStats -and $null -ne $mountStats) {
        if ($httpStats.MegabitsPerSec -le $mountStats.MegabitsPerSec) { $primary = $httpStats } else { $primary = $mountStats }
    } elseif ($null -ne $httpStats) {
        $primary = $httpStats
    } elseif ($null -ne $mountStats) {
        $primary = $mountStats
    } else {
        Write-Warning '[lan-bw] Re-check produced no measurement - stopping retries.'
        break
    }
    $mbps = [double]$primary.MegabitsPerSec
    $recommendedMbps = [int][Math]::Floor($mbps * $RecommendHeadroom)
    if ($recommendedMbps -lt $RecommendMinMbps) { $recommendedMbps = $RecommendMinMbps }
    if ($recommendedMbps -gt $RecommendMaxMbps) { $recommendedMbps = $RecommendMaxMbps }
    Write-Host ('[lan-bw] Re-check primary: {0:N1} Mbps ({1})' -f $mbps, $primary.Method) -ForegroundColor Cyan
}

if ($minLanMbps -gt 0 -and $mbps -lt $minLanMbps) {
    Write-Warning ('[lan-bw] Still {0:N1} Mbps after {1} retry(ies) (min {2}). Continuing.' -f $mbps, $retry, $minLanMbps)
} elseif ($retry -gt 0) {
    Write-Host ('[lan-bw] Throughput recovered to {0:N1} Mbps after {1} retry(ies).' -f $mbps, $retry) -ForegroundColor Green
}

$localFiles = @($outHttp, $outMount, $OutFile) | Select-Object -Unique
if (-not $KeepLocal) {
    foreach ($f in $localFiles) {
        if ($f -and (Test-Path -LiteralPath $f)) {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host '[lan-bw] Removed local copies (use -KeepLocal to retain).'
} else {
    Write-Host ('[lan-bw] Kept local copies under: {0}' -f $OutFile)
}

Wait-EnterToClose
exit 0
