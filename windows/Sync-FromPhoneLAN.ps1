#Requires -Version 5.1
<#
.SYNOPSIS
  Pull op_00.mp4 from Loop Segments LAN export into the older PC DLNA slot.

.DESCRIPTION
  While export runs on the phone, Loop Segments serves Documents/Exports on Wi-Fi
  (default http://<phone-ip>:8765/). This script downloads the segment and copies it
  to the older of op_00.mp4 / op_01.mp4 on the PC (DLNA ring buffer).
  Skips overwrite when the peer slot already has the same segment (phone unchanged) so DLNA
  never has identical op_00 and op_01. Schedules a retry of that same slot after DeferRetrySeconds
  (default = PollSeconds, 60). Installs via a temp file + rename so DLNA never reads a partial MP4.
  -Watch removes op_00.mp4 / op_01.mp4 from the PC destination when you stop (Enter), close the window (X), or Ctrl+C.

  Save the phone IP from the export log (LAN export: http://...) or -Discover.

.PARAMETER PhoneHost
  iPhone LAN IPv4 (e.g. 192.168.1.42). Default: loop-segments-lan-host.txt in this folder.

.PARAMETER Port
  LAN server port (default 8765).

.PARAMETER Watch
  Poll every -PollSeconds until Enter.

.PARAMETER Discover
  GET /status.json and list available files.

.EXAMPLE
  .\Sync-FromPhoneLAN.ps1 -PhoneHost 192.168.1.42 -Discover

.EXAMPLE
  .\Set-LoopSegmentsLANHost.ps1 192.168.1.42
  .\Sync-FromPhoneLAN.ps1 -Watch
#>
[CmdletBinding()]
param(
    [string] $PhoneHost = '',
    [int] $Port = 8765,
    [string] $DestinationDirectory = '',
    [string] $StagingDirectory = '',
    [int] $PollSeconds = 60,
    [int] $MinSegmentBytes = 8192,
    [switch] $Discover,
    [switch] $Watch,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\LoopSegments-Config.ps1"

$SegmentNames = @('op_00.mp4', 'op_01.mp4')
$RemoteSegmentName = 'op_00.mp4'

function Get-LoopSegmentsLANHostConfigPath {
    Join-Path $PSScriptRoot 'loop-segments-lan-host.txt'
}

function Get-LoopSegmentsLANHost {
    param([string] $Override = '')
    $resolved = $Override.Trim()
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $configFile = Get-LoopSegmentsLANHostConfigPath
        if (Test-Path -LiteralPath $configFile -PathType Leaf) {
            $resolved = (Get-Content -LiteralPath $configFile -Raw).Trim().Trim('"')
        }
    }
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw @"
PhoneHost is required. Copy the IP from the app export log (LAN export: http://...).

Run once:
  .\Set-LoopSegmentsLANHost.ps1 192.168.1.42

Or pass -PhoneHost on each run.
Config file: $(Get-LoopSegmentsLANHostConfigPath)
"@
    }
    return $resolved.Trim()
}

function Get-LANBaseUrl {
    param([string] $PhoneHost, [int] $Port)
    return "http://${PhoneHost}:$Port"
}

function Get-LANStatus {
    param([string] $BaseUrl)
    return Invoke-RestMethod -Uri "$BaseUrl/status.json" -Method Get -TimeoutSec 30
}

function Get-FileSha256Hex {
    param([string] $Path)
    $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256
    return $hash.Hash.ToLowerInvariant()
}

function Get-Int64Scalar {
    param($Value)
    if ($null -eq $Value) { return $null }
    while ($Value -is [System.Array]) {
        if ($Value.Count -lt 1) { return $null }
        $Value = $Value[0]
    }
    return [int64]$Value
}

function Get-HttpContentLengthBytes {
    param(
        $Response,
        [int64] $Fallback
    )
    if ($null -eq $Response) { return $Fallback }
    try {
        $values = $Response.Headers.GetValues('Content-Length')
        if ($values -and $values.Count -gt 0) {
            return Get-Int64Scalar $values[0]
        }
    } catch { }
    return $Fallback
}

function Get-LANSyncState {
    param([string] $StateFile)
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) { return $null }
    try {
        return Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Write-LANSyncState {
    param(
        [string] $StateFile,
        [long] $Bytes,
        [string] $Checksum,
        [string] $DestName,
        [string] $DeferredDest = '',
        [string] $DeferredAt = '',
        [string] $DeferredReason = ''
    )
    $payload = [ordered]@{
        bytes = $Bytes
        checksum = $Checksum
        syncedAt = (Get-Date).ToUniversalTime().ToString('o')
        dest = $DestName
    }
    if (-not [string]::IsNullOrWhiteSpace($DeferredDest)) {
        $payload.deferredDest = $DeferredDest
        $payload.deferredAt = $DeferredAt
        $payload.deferredReason = $DeferredReason
    }
    $payload | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Register-LANSyncDefer {
    param(
        [string] $StateFile,
        [string] $DestName,
        [string] $Reason,
        [int] $DeferRetrySeconds,
        [long] $Bytes,
        [string] $Checksum
    )
    $now = (Get-Date).ToUniversalTime().ToString('o')
    Write-LANSyncState -StateFile $StateFile -Bytes $Bytes -Checksum $Checksum -DestName $DestName `
        -DeferredDest $DestName -DeferredAt $now -DeferredReason $Reason
    Write-Host "Deferred $DestName — will force retry in $DeferRetrySeconds s ($Reason)."
}

function Resolve-DLANTargetSlot {
    param(
        [string] $DestinationRoot,
        [string] $StateFile,
        [int] $DeferRetrySeconds
    )
    $state = Get-LANSyncState -StateFile $StateFile
    if ($null -ne $state -and $null -ne $state.deferredDest -and $null -ne $state.deferredAt) {
        $destName = [string]$state.deferredDest
        if ($SegmentNames -contains $destName) {
            try {
                $deferredAt = [datetime]::Parse(
                    [string]$state.deferredAt,
                    $null,
                    [System.Globalization.DateTimeStyles]::RoundtripKind
                )
                if ($deferredAt.Kind -eq [System.DateTimeKind]::Unspecified) {
                    $deferredAt = [datetime]::SpecifyKind($deferredAt, [System.DateTimeKind]::Utc)
                }
                $elapsed = ((Get-Date).ToUniversalTime() - $deferredAt.ToUniversalTime()).TotalSeconds
                if ($elapsed -ge $DeferRetrySeconds) {
                    $destPath = Join-Path $DestinationRoot $destName
                    $was = if ($state.deferredReason) { [string]$state.deferredReason } else { 'checksum skip' }
                    return $destPath, $destName, "retry deferred $destName (${DeferRetrySeconds}s+, $was)"
                }
            } catch {
                Write-Warning "Could not parse deferredAt in lan-sync-state.json — using ring slot."
            }
        }
    }
    return Get-OlderDLNASlot -DestinationRoot $DestinationRoot
}

function Test-SegmentMP4Readable {
    param([string] $Path)
    $ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
    if (-not $ffprobe) {
        return $true
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ffprobe.Source
    $psi.Arguments = "-v error -show_format -show_streams -i `"$Path`""
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
    return $proc.ExitCode -eq 0
}

function Clear-LANSyncDefer {
    param(
        [string] $StateFile,
        [long] $Bytes,
        [string] $DestName
    )
    Write-LANSyncState -StateFile $StateFile -Bytes $Bytes -Checksum '' -DestName $DestName
}

function Install-DLANSegmentAtomic {
    param(
        [string] $SourcePath,
        [string] $DestPath
    )
    $srcFull = [System.IO.Path]::GetFullPath($SourcePath)
    $dstFull = [System.IO.Path]::GetFullPath($DestPath)
    if ($srcFull -eq $dstFull) {
        return
    }
    $parent = Split-Path -Parent $DestPath
    $leaf = Split-Path -Leaf $DestPath
    $tempPath = Join-Path $parent ".$leaf.part"
    foreach ($path in @($tempPath, $DestPath)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    Copy-Item -LiteralPath $SourcePath -Destination $tempPath -Force
    Move-Item -LiteralPath $tempPath -Destination $DestPath -Force
}

function Remove-LANStagingFile {
    param([string] $StagingFile)
    if (Test-Path -LiteralPath $StagingFile -PathType Leaf) {
        Remove-Item -LiteralPath $StagingFile -Force -ErrorAction SilentlyContinue
    }
}

function Remove-LANSegmentArtifacts {
    param(
        [string] $DestinationRoot,
        [string] $StagingDirectory
    )
    $removed = @()
    foreach ($name in $SegmentNames) {
        $path = Join-Path $DestinationRoot $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            $removed += $name
        }
        $partPath = Join-Path $DestinationRoot ".$name.part"
        if (Test-Path -LiteralPath $partPath -PathType Leaf) {
            Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
            $removed += ".$name.part"
        }
    }
    $stagingFile = Join-Path $StagingDirectory $RemoteSegmentName
    if (Test-Path -LiteralPath $stagingFile -PathType Leaf) {
        Remove-LANStagingFile -StagingFile $stagingFile
        $removed += "$RemoteSegmentName (staging)"
    }
    $stateFile = Join-Path $StagingDirectory 'lan-sync-state.json'
    if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
        Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
        $removed += 'lan-sync-state.json'
    }
    if ($removed.Count -gt 0) {
        Write-Host "Cleanup: removed $($removed -join ', ') from PC DLNA folder / LAN staging."
    } else {
        Write-Host 'Cleanup: no segment files found in DLNA folder or LAN staging.'
    }
}

function Get-LANWatchSessionPath {
    param([string] $StagingDirectory)
    return Join-Path $StagingDirectory 'lan-watch-session.json'
}

function Get-LANWatchCleanupScriptPath {
    param([string] $StagingDirectory)
    return Join-Path $StagingDirectory 'lan-watch-cleanup.ps1'
}

function New-LANWatchCleanupScript {
    param(
        [string] $CleanupScriptPath,
        [string] $DestinationRoot,
        [string] $StagingDirectory
    )
    $destEsc = $DestinationRoot.Replace("'", "''")
    $stagingEsc = $StagingDirectory.Replace("'", "''")
    $selfEsc = $CleanupScriptPath.Replace("'", "''")
    @"
`$ErrorActionPreference = 'SilentlyContinue'
foreach (`$name in @('op_00.mp4', 'op_01.mp4')) {
    Remove-Item -LiteralPath (Join-Path '$destEsc' `$name) -Force
    Remove-Item -LiteralPath (Join-Path '$destEsc' ".$name.part") -Force
}
Remove-Item -LiteralPath (Join-Path '$stagingEsc' 'op_00.mp4') -Force
Remove-Item -LiteralPath (Join-Path '$stagingEsc' 'lan-sync-state.json') -Force
Remove-Item -LiteralPath (Join-Path '$stagingEsc' 'lan-watch-session.json') -Force
Remove-Item -LiteralPath '$selfEsc' -Force
"@ | Set-Content -LiteralPath $CleanupScriptPath -Encoding UTF8
}

function Start-LANWatchCleanupProcess {
    param([string] $CleanupScriptPath)
    if (-not (Test-Path -LiteralPath $CleanupScriptPath -PathType Leaf)) {
        return
    }
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', $CleanupScriptPath
    ) -WindowStyle Hidden | Out-Null
}

function Register-LANWatchConsoleHook {
    param([string] $CleanupScriptPath)
    if (-not ('LanWatchConsoleHook' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class LanWatchConsoleHook {
    public static string CleanupScriptPath = "";
    public delegate bool HandlerDelegate(int signal);
  public static HandlerDelegate Handler = OnSignal;
    private static bool OnSignal(int signal) {
        try {
            if (string.IsNullOrEmpty(CleanupScriptPath)) return false;
            var psi = new ProcessStartInfo {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + CleanupScriptPath + "\"",
                CreateNoWindow = true,
                UseShellExecute = false
            };
            Process.Start(psi);
        } catch { }
        return false;
    }
    [DllImport("Kernel32", SetLastError = true)]
    public static extern bool SetConsoleCtrlHandler(HandlerDelegate handler, bool add);
}
'@
    }
    [LanWatchConsoleHook]::CleanupScriptPath = $CleanupScriptPath
    [void][LanWatchConsoleHook]::SetConsoleCtrlHandler([LanWatchConsoleHook]::Handler, $true)
}

function Invoke-PendingLANWatchCleanup {
    param([string] $StagingDirectory)
    $sessionPath = Get-LANWatchSessionPath -StagingDirectory $StagingDirectory
    if (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) {
        return
    }
    $session = $null
    try {
        $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
    } catch {
        Remove-Item -LiteralPath $sessionPath -Force -ErrorAction SilentlyContinue
        return
    }
    $alive = $false
    if ($null -ne $session.pid) {
        $alive = $null -ne (Get-Process -Id ([int]$session.pid) -ErrorAction SilentlyContinue)
    }
    if ($alive) {
        return
    }
    Write-Host 'Previous -Watch ended without cleanup (closed window?) — removing segment files...'
    $cleanupPath = Get-LANWatchCleanupScriptPath -StagingDirectory $StagingDirectory
    if (Test-Path -LiteralPath $cleanupPath -PathType Leaf) {
        Start-LANWatchCleanupProcess -CleanupScriptPath $cleanupPath
        Start-Sleep -Milliseconds 800
    } elseif ($session.destinationRoot -and $session.stagingDirectory) {
        Remove-LANSegmentArtifacts -DestinationRoot $session.destinationRoot -StagingDirectory $session.stagingDirectory
        Remove-Item -LiteralPath $sessionPath -Force -ErrorAction SilentlyContinue
    }
}

function Start-LANWatchSession {
    param(
        [string] $DestinationRoot,
        [string] $StagingDirectory
    )
    if (-not (Test-Path -LiteralPath $StagingDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $StagingDirectory -Force | Out-Null
    }
    $cleanupPath = Get-LANWatchCleanupScriptPath -StagingDirectory $StagingDirectory
    New-LANWatchCleanupScript -CleanupScriptPath $cleanupPath -DestinationRoot $DestinationRoot `
        -StagingDirectory $StagingDirectory
    $sessionPath = Get-LANWatchSessionPath -StagingDirectory $StagingDirectory
    @{
        pid = $PID
        destinationRoot = $DestinationRoot
        stagingDirectory = $StagingDirectory
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $sessionPath -Encoding UTF8
    Register-LANWatchConsoleHook -CleanupScriptPath $cleanupPath
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -MessageData $cleanupPath -Action {
        Start-LANWatchCleanupProcess -CleanupScriptPath $Event.MessageData
    }
}

function Complete-LANWatchSession {
    param(
        [string] $DestinationRoot,
        [string] $StagingDirectory,
        [switch] $SkipArtifactRemoval
    )
    $sessionPath = Get-LANWatchSessionPath -StagingDirectory $StagingDirectory
    $cleanupPath = Get-LANWatchCleanupScriptPath -StagingDirectory $StagingDirectory
    if (-not $SkipArtifactRemoval) {
        Remove-LANSegmentArtifacts -DestinationRoot $DestinationRoot -StagingDirectory $StagingDirectory
    }
    Remove-Item -LiteralPath $sessionPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $cleanupPath -Force -ErrorAction SilentlyContinue
}

function Get-OlderDLNASlot {
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

function Get-PeerDLNASlotPath {
    param(
        [string] $DestinationRoot,
        [string] $DestName
    )
    $peerName = if ($DestName -eq $SegmentNames[0]) { $SegmentNames[1] } else { $SegmentNames[0] }
    return (Join-Path $DestinationRoot $peerName), $peerName
}

function Invoke-LANSegmentSync {
    param(
        [string] $BaseUrl,
        [string] $DestinationRoot,
        [string] $StagingDirectory,
        [int] $MinSegmentBytes,
        [int] $DeferRetrySeconds = 60,
        [switch] $DryRun
    )

    $status = Get-LANStatus -BaseUrl $BaseUrl
    $entry = $status.files | Where-Object { $_.name -eq $RemoteSegmentName } | Select-Object -First 1
    if (-not $entry) {
        Write-Host "No $RemoteSegmentName on phone yet (export still warming up)."
        return $false
    }

    $remoteBytes = Get-Int64Scalar $entry.bytes
    if ($remoteBytes -lt $MinSegmentBytes) {
        Write-Host "$RemoteSegmentName on phone too small ($remoteBytes B) — wait for segment to finish."
        return $false
    }

    $stateFile = Join-Path $StagingDirectory 'lan-sync-state.json'

    $destPath, $destName, $reason = Resolve-DLANTargetSlot -DestinationRoot $DestinationRoot `
        -StateFile $stateFile -DeferRetrySeconds $DeferRetrySeconds
    $stagingFile = Join-Path $StagingDirectory $RemoteSegmentName

    Write-Host "Phone: $RemoteSegmentName $remoteBytes bytes (modified $($entry.modified)) -> $destName ($reason)"

    $peerPath, $peerName = Get-PeerDLNASlotPath -DestinationRoot $DestinationRoot -DestName $destName

    if ($DryRun) {
        Write-Host "Would download: $BaseUrl/$RemoteSegmentName -> $destPath (atomic install)"
        Write-Host "Would skip if $destName already matches, or if $peerName already has the same segment (avoid duplicate slots)."
        return $true
    }

    if (-not (Test-Path -LiteralPath $StagingDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $StagingDirectory -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $DestinationRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
    }

    # PS 5.1 -OutFile fails if the path already exists (common after a prior skip/install).
    Remove-LANStagingFile -StagingFile $stagingFile
    $downloadUrl = "$BaseUrl/$RemoteSegmentName"
    $response = Invoke-WebRequest -Uri $downloadUrl -OutFile $stagingFile -TimeoutSec 600 -UseBasicParsing -PassThru

    $local = Get-Item -LiteralPath $stagingFile
    if ($local.Length -lt $MinSegmentBytes) {
        Write-Host "Downloaded file too small ($($local.Length) B) — skipped."
        Remove-Item -LiteralPath $stagingFile -Force -ErrorAction SilentlyContinue
        return $false
    }
    $expectedBytes = Get-HttpContentLengthBytes -Response $response -Fallback $remoteBytes
    if ($local.Length -ne $expectedBytes) {
        Write-Host (
            "Download incomplete — got $($local.Length) B, expected $expectedBytes B " +
            "(moov missing if installed). Skipped."
        )
        Remove-Item -LiteralPath $stagingFile -Force -ErrorAction SilentlyContinue
        return $false
    }
    if (-not (Test-SegmentMP4Readable -Path $stagingFile)) {
        Write-Host (
            "Not a playable MP4 (moov missing — often a partial LAN download while the phone published a new segment). " +
            "Wait for export_latest.txt 'DLNA slot published', then sync again. Skipped."
        )
        Clear-LANSyncDefer -StateFile $stateFile -Bytes $remoteBytes -DestName $destName
        Remove-LANStagingFile -StagingFile $stagingFile
        return $false
    }

    $checksum = Get-FileSha256Hex -Path $stagingFile
    if (Test-Path -LiteralPath $destPath -PathType Leaf) {
        $destChecksum = Get-FileSha256Hex -Path $destPath
        if ($destChecksum -eq $checksum) {
            Write-Host "$destName already has this segment (SHA256 $checksum) — skipped."
            Register-LANSyncDefer -StateFile $stateFile -DestName $destName -Reason 'dest_unchanged' `
                -DeferRetrySeconds $DeferRetrySeconds -Bytes $local.Length -Checksum $checksum
            Remove-LANStagingFile -StagingFile $stagingFile
            return $false
        }
    }
    if (Test-Path -LiteralPath $peerPath -PathType Leaf) {
        $peerChecksum = Get-FileSha256Hex -Path $peerPath
        if ($peerChecksum -eq $checksum) {
            Write-Host (
                "Peer $peerName already has this segment (phone unchanged) — " +
                "skipped $destName to avoid identical DLNA slots."
            )
            Register-LANSyncDefer -StateFile $stateFile -DestName $destName -Reason 'peer_has_segment' `
                -DeferRetrySeconds $DeferRetrySeconds -Bytes $local.Length -Checksum $checksum
            Remove-LANStagingFile -StagingFile $stagingFile
            return $false
        }
    }

    Install-DLANSegmentAtomic -SourcePath $stagingFile -DestPath $destPath
    Write-LANSyncState -StateFile $stateFile -Bytes $local.Length -Checksum $checksum -DestName $destName
    Remove-LANStagingFile -StagingFile $stagingFile

    Write-Host "Copied -> $destPath ($($local.Length) bytes, SHA256 $checksum)"
    return $true
}

$phone = Get-LoopSegmentsLANHost -Override $PhoneHost
$baseUrl = Get-LANBaseUrl -PhoneHost $phone -Port $Port

if ([string]::IsNullOrWhiteSpace($DestinationDirectory)) {
    $DestinationDirectory = Get-LoopSegmentsDestinationDirectory
}
Test-LoopSegmentsDestinationReady -Directory $DestinationDirectory
$destRoot = [System.IO.Path]::GetFullPath($DestinationDirectory)

if ([string]::IsNullOrWhiteSpace($StagingDirectory)) {
    $StagingDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'LoopSegmentsLanStaging'
}
$stagingRoot = [System.IO.Path]::GetFullPath($StagingDirectory)

if ($Watch -and -not $DryRun) {
    Invoke-PendingLANWatchCleanup -StagingDirectory $stagingRoot
}

if ($Discover) {
    Write-Host "LAN base: $baseUrl"
    try {
        $status = Get-LANStatus -BaseUrl $baseUrl
        $status.files | Format-Table name, bytes, modified -AutoSize
    } catch {
        Write-Error "Cannot reach phone at $baseUrl — export running, same Wi-Fi, Local Network allowed for Loop Segments?`n$_"
    }
    exit 0
}

function Wait-ForEnterOrSeconds {
    param([int] $Seconds)
    $end = [datetime]::UtcNow.AddSeconds($Seconds)
    while ([datetime]::UtcNow -lt $end) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'Enter') { return $true }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

if ($Watch) {
    if ($PollSeconds -lt 5) { throw 'PollSeconds must be at least 5.' }
    Write-Host "Watch: $baseUrl -> $destRoot every $PollSeconds s"
    Write-Host 'Press Enter to stop (phone: export running, same Wi-Fi, Local Network allowed).'
    Write-Host 'On stop (Enter, X, or Ctrl+C): op_00.mp4 / op_01.mp4 removed from PC DLNA folder; LAN staging cleared.'
    Write-Host ''
    if (-not $DryRun) {
        Start-LANWatchSession -DestinationRoot $destRoot -StagingDirectory $stagingRoot
    }
    $iteration = 0
    try {
        while ($true) {
            $iteration++
            Write-Host "--- LAN sync #$iteration  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ---" -ForegroundColor Cyan
            try {
                Invoke-LANSegmentSync -BaseUrl $baseUrl -DestinationRoot $destRoot `
                    -StagingDirectory $stagingRoot -MinSegmentBytes $MinSegmentBytes `
                    -DeferRetrySeconds $PollSeconds -DryRun:$DryRun
            } catch {
                Write-Warning $_.Exception.Message
            }
            Write-Host "Next sync in $PollSeconds s (Enter to stop)..."
            if (Wait-ForEnterOrSeconds -Seconds $PollSeconds) {
                Write-Host 'Stopped.'
                break
            }
        }
    } finally {
        if (-not $DryRun) {
            Complete-LANWatchSession -DestinationRoot $destRoot -StagingDirectory $stagingRoot
        }
    }
    exit 0
}

Invoke-LANSegmentSync -BaseUrl $baseUrl -DestinationRoot $destRoot `
    -StagingDirectory $stagingRoot -MinSegmentBytes $MinSegmentBytes `
    -DeferRetrySeconds $PollSeconds -DryRun:$DryRun
