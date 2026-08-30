# Entry may start under Windows PowerShell 5.1; re-launch with pwsh.
<#
.SYNOPSIS
  Mount the phone LAN export folder as a Windows drive via rclone WebDAV (or test connectivity).

.DESCRIPTION
  Loop Segments on the phone serves HTTP + WebDAV on port 8765 (PROPFIND, GET, Basic auth admin/iosadmin).
  This script writes/updates a [loopsegments] block in rclone.conf and runs rclone mount (WinFsp).
  If the phone has pcld_ios_media/, the mount start directory is that folder (L:\loop, L:\archive);
  otherwise the WebDAV root is mounted (L:\pcld_ios_media\...).

  Per-PC settings: loop-segments-windows.json in the parent windows\ folder (see ..\setup\Set-LoopSegmentsWindows.ps1).
  Scripts resolve paths from the shared helper - copy or clone the repo anywhere; only the json file differs per PC.
  Prefer Mount-LoopSegmentsRclone.ps1 / Mount-PhoneL.cmd (PowerShell 7). Opening this .ps1 under 5.1 re-launches pwsh.

.PARAMETER RemovePort80Proxy
  Admin: remove netsh portproxy rules (PC :80 or :8080 -> phone :8765) from legacy WebDAV mapping.

.PARAMETER Remove
  Stop rclone processes that mount the configured drive letter.

.PARAMETER Unstick
  Emergency when Explorer freezes after phone LAN dies: kill the phone rclone mount
  (and its mount PowerShell window), then restart Explorer. Does not need LAN up.

.PARAMETER ReadOnly
  Mount with rclone --read-only (safer for DLNA-only; blocks Explorer copy to L:).
  Default mount is read/write where the phone allows (pcld_ios_media/scripts/ and subfolders).
  loop/, _working.mp4, and export segments stay read-only on the phone even when L: is writable.

.PARAMETER Quick
  Skip the slow pre-mount "rclone ls" WebDAV listing (HTTP status.json + remote config only).
  Used by the web companion so L: appears sooner; full -TestOnly still runs the ls check.

.PARAMETER LanPollSeconds
  While mounted, probe phone LAN this often (default 15). Ignored with -NoLanWatch.

.PARAMETER LanDownSeconds
  If LAN stays unreachable this long, kill rclone and exit this script (default 60).
  Prevents Explorer hangs on a dead L: mount.

.PARAMETER NoLanWatch
  Do not poll LAN; keep rclone in the foreground until Ctrl+C (legacy behavior).

.PARAMETER SkipOffSubnetRouterReboot
  If phone LAN page is unreachable, do not sequentially reboot off-subnet routers
  (P:\all_scripts\5g_router_reboot) to pull the phone onto the desired gateway.

.EXAMPLE
  Copy-Item ..\loop-segments-windows.example.json ..\loop-segments-windows.json
  ..\setup\Set-LoopSegmentsWindows.ps1 -PhoneHost 192.168.1.42
  .\Mount-LoopSegmentsRclone.ps1 -TestOnly
  .\Mount-LoopSegmentsRclone.ps1

.EXAMPLE
  .\Mount-LoopSegmentsRclone.ps1 -Unstick

.EXAMPLE
  .\Mount-LoopSegmentsRclone.ps1 -RemovePort80Proxy
#>
[CmdletBinding()]
param(
    [string] $PhoneHost = '',
    [ValidatePattern('^[A-Za-z]$')]
    [string] $DriveLetter = '',
    [int] $Port = 0,
    [string] $RemoteName = '',
    [string] $WebDAVUser = '',
    [string] $WebDAVPassword = '',
    [switch] $Remove,
    [switch] $Unstick,
    [switch] $RemovePort80Proxy,
    [switch] $TestOnly,
    [switch] $ReadOnly,
    [switch] $Quick,
    [ValidateRange(5, 600)]
    [int] $LanPollSeconds = 15,
    [ValidateRange(15, 3600)]
    [int] $LanDownSeconds = 60,
    [switch] $NoLanWatch,
    [switch] $SkipOffSubnetRouterReboot,
    # Companion child: exit on error without local Enter (parent already continues).
    [switch] $NoWaitEnter
)

$ErrorActionPreference = 'Stop'

$PwshHelper = Join-Path $PSScriptRoot '..\lib\Get-LoopSegmentsPwsh.ps1'
if (-not (Test-Path -LiteralPath $PwshHelper)) {
    throw "Missing $PwshHelper"
}
. $PwshHelper
Ensure-LoopSegmentsPwshHost -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

. "$PSScriptRoot\..\lib\LoopSegments-Windows.ps1"

function Ensure-RcloneRemote {
    param(
        [string] $Name,
        [string] $Url,
        [string] $User,
        [string] $Pass
    )

    $inv = Get-RcloneInvocation
    $args = @()
    if ($inv.PrefixArgs) { $args += $inv.PrefixArgs }
    $args += 'obscure', $Pass
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $obscured = (& $inv.Exe @args 2>&1 | Out-String).Trim()
    $ErrorActionPreference = $prev
    if ($LASTEXITCODE -ne 0) {
        throw "rclone obscure failed: $obscured"
    }

    $configPath = (Get-RcloneInvocation).ConfigPath

    $block = @"
[$Name]
type = webdav
url = $Url
vendor = other
user = $User
pass = $obscured

"@

    if (Test-Path -LiteralPath $configPath) {
        $text = Get-Content -LiteralPath $configPath -Raw
        $pattern = "(?ms)^\[$([regex]::Escape($Name))\].*?(?=^\[|\z)"
        if ($text -match $pattern) {
            $text = [regex]::Replace($text, $pattern, $block.TrimEnd() + "`r`n`r`n")
        } else {
            if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`r`n" }
            $text += "`r`n" + $block
        }
        Set-Content -LiteralPath $configPath -Value $text -Encoding UTF8 -NoNewline
    } else {
        Set-Content -LiteralPath $configPath -Value $block -Encoding UTF8
    }
    Write-Host "rclone remote '$Name' -> $Url"
    Write-Host "Config: $configPath"
}

function Invoke-WebDavRequest {
    param(
        [string] $Uri,
        [string] $Method,
        [hashtable] $Headers = @{},
        [string] $Body = '',
        [int] $TimeoutSec = 20
    )

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = $Method
    $request.Timeout = $TimeoutSec * 1000
    foreach ($key in $Headers.Keys) {
        if ($key -ieq 'Authorization') {
            $request.Headers['Authorization'] = [string]$Headers[$key]
        } else {
            $request.Headers[$key] = [string]$Headers[$key]
        }
    }
    if (-not [string]::IsNullOrEmpty($Body)) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentType = 'text/xml; charset=utf-8'
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try {
            $stream.Write($bytes, 0, $bytes.Length)
        } finally {
            $stream.Close()
        }
    }
    try {
        $response = $request.GetResponse()
    } catch [System.Net.WebException] {
        if ($null -ne $_.Exception.Response) {
            return $_.Exception.Response
        }
        throw
    }
    return $response
}

function Test-PhoneLANExport {
    param(
        [string] $HostName,
        [int] $PortNum,
        [string] $User,
        [string] $Pass
    )

    $base = "http://${HostName}:${PortNum}/"
    $pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${Pass}"))
    $headers = @{ Authorization = "Basic $pair" }

    Write-Host "Checking $base ..."
    try {
        $r = Invoke-WebRequest -Uri ($base + 'status.json') -TimeoutSec 15 -UseBasicParsing
        Write-Host "  GET status.json -> $($r.StatusCode)"
    } catch {
        throw "Phone not reachable at $base (same Wi-Fi? LAN server on? app in foreground?). $($_.Exception.Message)"
    }

    try {
        $r = Invoke-WebRequest -Uri $base -TimeoutSec 15 -UseBasicParsing
        Write-Host "  GET / (HTML index) -> $($r.StatusCode)"
    } catch {
        Write-Warning "  GET / failed: $($_.Exception.Message)"
    }

    try {
        $r = Invoke-WebRequest -Uri $base -Method 'OPTIONS' -Headers $headers -TimeoutSec 15 -UseBasicParsing
        $allow = $r.Headers['Allow']
        if ($allow) {
            Write-Host "  OPTIONS -> $($r.StatusCode); Allow: $allow"
        } else {
            Write-Host "  OPTIONS (WebDAV) -> $($r.StatusCode)"
        }
    } catch {
        Write-Warning "  OPTIONS failed: $($_.Exception.Message)"
    }

    $body = '<?xml version="1.0" encoding="utf-8"?><D:propfind xmlns:D="DAV:"><D:prop><D:displayname/></D:prop></D:propfind>'
    $propHeaders = $headers.Clone()
    $propHeaders['Depth'] = '1'
    try {
        $response = Invoke-WebDavRequest -Uri $base -Method 'PROPFIND' -Headers $propHeaders -Body $body -TimeoutSec 20
        $status = [int]$response.StatusCode
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        try {
            $content = $reader.ReadToEnd()
        } finally {
            $reader.Close()
            $response.Close()
        }
        Write-Host "  PROPFIND -> $status"
        if ($content -match 'pcld_ios_media/loop/op_00') {
            Write-Host '  pcld_ios_media/loop/op_00.mp4 listed - good'
        } elseif ($content -match 'op_00') {
            Write-Warning '  Found op_00 at root - install latest Loop Segments (pcld_ios_media/loop/ subfolder).'
        }
    } catch {
        Write-Warning "  PROPFIND probe skipped ($($_.Exception.Message)); rclone will verify WebDAV next."
    }
}

function Invoke-OffSubnetRouterRebootsForLanRecovery {
    param([string] $PhoneLanHost = '')
    if ($SkipOffSubnetRouterReboot) {
        Write-Host '[lan-recover] Skipping phone LAN recovery (-SkipOffSubnetRouterReboot)'
        return $false
    }
    $recoverPs1 = Join-Path $script:LoopSegmentsWindowsRoot 'lan\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1'
    if (-not (Test-Path -LiteralPath $recoverPs1)) {
        Write-Warning "[lan-recover] Missing $recoverPs1 — cannot recover unreachable phone LAN"
        return $false
    }

    Write-Host '[lan-recover] Phone LAN page not reachable - recovering onto the expected subnet...'
    Write-Host '[lan-recover] Running recover in-process (same window)...'
    $prevEap = $ErrorActionPreference
    $code = 0
    try {
        if (-not [string]::IsNullOrWhiteSpace($PhoneLanHost)) {
            & $recoverPs1 -WaitBeforeRebootSec 0 -NoWaitEnter -PhoneLanHost $PhoneLanHost
        } else {
            & $recoverPs1 -WaitBeforeRebootSec 0 -NoWaitEnter
        }
        $code = 0
    } catch {
        $msg = [string]$_.Exception.Message
        if ($msg -match 'LAN_RECOVER_EXIT:(\d+)') {
            $code = [int]$Matches[1]
        } else {
            throw
        }
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($code -ne 0) {
        Write-Warning "[lan-recover] Phone LAN recover failed (exit $code)"
        return $false
    }
    return $true
}

function Test-PhoneLANExportWithOffSubnetRecovery {
    param(
        [string] $HostName,
        [int] $PortNum,
        [string] $User,
        [string] $Pass
    )
    try {
        Test-PhoneLANExport -HostName $HostName -PortNum $PortNum -User $User -Pass $Pass
        return
    } catch {
        $msg = [string]$_.Exception.Message
        if ($msg -notmatch '(?i)not reachable|timed out|unable to connect|actively refused|No such host|could not be resolved') {
            throw
        }
        Write-Warning "[rclone] $msg"
        if (-not (Invoke-OffSubnetRouterRebootsForLanRecovery -PhoneLanHost $HostName)) {
            throw
        }
        Write-Host '[rclone] Retrying phone LAN page after phone-LAN recover...'
        Start-Sleep -Seconds 5
        Test-PhoneLANExport -HostName $HostName -PortNum $PortNum -User $User -Pass $Pass
    }
}

function Test-RcloneWebDAVRemote {
    param([string] $Name)
    Write-Host "rclone ls ${Name}: (WebDAV list) ..."
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Invoke-LoopSegmentsRclone ls "${Name}:" --max-depth 1 | Out-Host
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($code -ne 0) {
        throw "rclone could not list ${Name}:"
    }
    Write-Host '  Phone Exports visible via WebDAV - good'
}

function Test-PhoneLanHasPcldIosMediaFolder {
    param(
        [string] $HostName,
        [int] $PortNum,
        [string] $User,
        [string] $Pass
    )
    $uri = "http://${HostName}:${PortNum}/pcld_ios_media/"
    $pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${Pass}"))
    $headers = @{
        Authorization = "Basic $pair"
        Depth         = '0'
    }
    $body = '<?xml version="1.0" encoding="utf-8"?><D:propfind xmlns:D="DAV:"><D:prop><D:displayname/></D:prop></D:propfind>'
    $response = $null
    try {
        $response = Invoke-WebDavRequest -Uri $uri -Method 'PROPFIND' -Headers $headers -Body $body -TimeoutSec 12
        $status = [int]$response.StatusCode
        return ($status -ge 200 -and $status -lt 400)
    } catch {
        return $false
    } finally {
        if ($null -ne $response) {
            try { $response.Close() } catch {}
        }
    }
}

function Wait-EnterOnError {
    param([int] $ExitCode = 1)
    if ($NoWaitEnter) {
        exit $ExitCode
    }
    Write-Host ""
    Write-Host "Press Enter to close..." -ForegroundColor Yellow
    try {
        [void][Console]::ReadLine()
    } catch {
        Read-Host | Out-Null
    }
    exit $ExitCode
}

function Stop-LoopSegmentsPhoneMountProcesses {
    param(
        [Parameter(Mandatory = $true)][string] $DriveLetter,
        [string] $RemoteName = 'loopsegments'
    )

    $driveToken = [regex]::Escape("${DriveLetter}:")
    $remoteToken = [regex]::Escape("${RemoteName}:")
    $stoppedRclone = 0
    $stoppedPs = 0

    Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $cmd = [string]$_.CommandLine
            if ($cmd -notmatch '(?i)\bmount\b') { return $false }
            return ($cmd -match $driveToken -or $cmd -match $remoteToken -or $cmd -match '(?i)LoopSegments')
        } |
        ForEach-Object {
            Write-Host "  kill rclone PID $($_.ProcessId)"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            $stoppedRclone++
        }

    # Companion / Mount-PhoneL leave a PowerShell host sitting on rclone mount.
    # Do not kill this -Unstick/-Remove process.
    $selfPid = $PID
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $selfPid -and
            $_.Name -match '(?i)^powershell(\.exe)?$' -and
            [string]$_.CommandLine -match 'Mount-LoopSegmentsRclone\.ps1'
        } |
        ForEach-Object {
            Write-Host "  kill mount PowerShell PID $($_.ProcessId)"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            $stoppedPs++
        }

    return @{ Rclone = $stoppedRclone; PowerShell = $stoppedPs }
}

function Wait-LoopSegmentsMountDrive {
    param(
        [Parameter(Mandatory = $true)][string] $DriveRoot,
        [int] $TimeoutSec = 15
    )
    $deadline = [datetime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSec))
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $DriveRoot) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return (Test-Path -LiteralPath $DriveRoot)
}

function Test-PhoneLanAlive {
    param(
        [Parameter(Mandatory = $true)][string] $HostName,
        [Parameter(Mandatory = $true)][int] $PortNum,
        [int] $TimeoutMs = 2500
    )

    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($HostName, $PortNum, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $tcp.EndConnect($iar)
    } catch {
        return $false
    } finally {
        if ($null -ne $tcp) {
            try { $tcp.Close() } catch {}
        }
    }

    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://${HostName}:${PortNum}/status.json")
        $req.Method = 'GET'
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.Proxy = $null  # bypass Clash / system proxy
        $req.KeepAlive = $false
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        return ($code -ge 200 -and $code -lt 500)
    } catch {
        return $false
    } finally {
        if ($null -ne $resp) {
            try { $resp.Close() } catch {}
            try { $resp.Dispose() } catch {}
        }
    }
}

function Find-LoopSegmentsRcloneMountProcess {
    param(
        [Parameter(Mandatory = $true)][string] $DriveLetter,
        [string] $RemoteName = 'loopsegments'
    )
    $driveToken = [regex]::Escape("${DriveLetter}:")
    $remoteToken = [regex]::Escape("${RemoteName}:")
    $match = @(Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            if ($null -eq $_) { return $false }
            $cmd = [string]$_.CommandLine
            if ($cmd -notmatch '(?i)\bmount\b') { return $false }
            return ($cmd -match $driveToken -or $cmd -match $remoteToken -or $cmd -match '(?i)--volname[= ]LoopSegments')
        } |
        Select-Object -First 1)
    if ($match.Count -eq 0) { return $null }
    try {
        return Get-Process -Id $match[0].ProcessId -ErrorAction Stop
    } catch {
        return $null
    }
}

function ConvertTo-RcloneArgumentString {
    param([Parameter(Mandatory = $true)][string[]] $Args)
    return (($Args | ForEach-Object {
        $s = [string]$_
        if ($s -match '[\s"]') {
            '"' + ($s.Replace('"', '\"')) + '"'
        } else {
            $s
        }
    }) -join ' ')
}

function Start-LoopSegmentsRcloneMountProcess {
    param(
        [Parameter(Mandatory = $true)][string[]] $MountArgs,
        [string] $LogFile = ''
    )

    $inv = Get-RcloneInvocation
    $all = @()
    if ($inv.PrefixArgs) { $all += $inv.PrefixArgs }
    $all += $MountArgs
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        $all += @('--log-file', $LogFile, '--log-level', 'INFO')
    }
    $argString = ConvertTo-RcloneArgumentString -Args $all
    Write-Host "rclone $argString"

    # ProcessStartInfo avoids Start-Process -ArgumentList quoting quirks (L:\ / spaces).
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $inv.Exe
    $psi.Arguments = $argString
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    if (-not $proc.Start()) {
        throw 'Failed to start rclone mount process.'
    }
    return $proc
}

function Show-RcloneMountLogTail {
    param([string] $LogFile, [int] $Lines = 40)
    if ([string]::IsNullOrWhiteSpace($LogFile) -or -not (Test-Path -LiteralPath $LogFile)) {
        Write-Host '(no rclone log file)'
        return
    }
    Write-Host "----- rclone log (last $Lines lines): $LogFile -----"
    Get-Content -LiteralPath $LogFile -Tail $Lines | ForEach-Object { Write-Host $_ }
    Write-Host '----- end rclone log -----'
}

function Watch-LoopSegmentsRcloneMount {
    param(
        [Parameter(Mandatory = $true)]$RcloneProcess,
        [Parameter(Mandatory = $true)][string] $HostName,
        [Parameter(Mandatory = $true)][int] $PortNum,
        [Parameter(Mandatory = $true)][string] $DriveRoot,
        [int] $PollSeconds = 15,
        [int] $DownSeconds = 60
    )

    Write-Host "LAN watch: probe http://${HostName}:${PortNum}/status.json every ${PollSeconds}s; kill rclone if down >= ${DownSeconds}s."
    Write-Host 'Ctrl+C also stops rclone and exits.'
    $lastOk = [datetime]::UtcNow
    $wasDown = $false
    $script:RcloneWatchReturned = $false

    try {
        while ($true) {
            Start-Sleep -Seconds $PollSeconds
            try { $RcloneProcess.Refresh() } catch {}
            if ($RcloneProcess.HasExited) {
                $code = 0
                try { $code = [int]$RcloneProcess.ExitCode } catch {}
                Write-Host "rclone exited (code $code)."
                $script:RcloneWatchReturned = $true
                return $code
            }

            if (Test-PhoneLanAlive -HostName $HostName -PortNum $PortNum) {
                if ($wasDown) {
                    Write-Host '[lan-watch] Phone LAN back up'
                    $wasDown = $false
                }
                $lastOk = [datetime]::UtcNow
                continue
            }

            $downFor = [int]([datetime]::UtcNow - $lastOk).TotalSeconds
            $wasDown = $true
            if ($downFor -ge $DownSeconds) {
                Write-Warning ('[lan-watch] Phone LAN unreachable for {0}s - killing rclone and exiting (avoids Explorer hang on dead L:).' -f $DownSeconds)
                try {
                    if (-not $RcloneProcess.HasExited) {
                        Stop-Process -Id $RcloneProcess.Id -Force -ErrorAction SilentlyContinue
                    }
                } catch {}
                Start-Sleep -Milliseconds 400
                $script:RcloneWatchReturned = $true
                return 2
            }
            Write-Host ('[lan-watch] LAN down {0}s / {1}s (rclone PID {2})...' -f $downFor, $DownSeconds, $RcloneProcess.Id)
        }
    } finally {
        try { $RcloneProcess.Refresh() } catch {}
        if (-not $RcloneProcess.HasExited) {
            Write-Host "Stopping rclone PID $($RcloneProcess.Id)..."
            Stop-Process -Id $RcloneProcess.Id -Force -ErrorAction SilentlyContinue
        }
        # WinFsp drop + This PC refresh (Ctrl+C, console X, LAN-watch kill, rclone exit).
        Start-Sleep -Milliseconds 400
        if (-not [string]::IsNullOrWhiteSpace($DriveRoot)) {
            Update-ExplorerForMappedDrive -DriveRoot $DriveRoot -Removed
            Write-Host ("[mount] Told Explorer {0} was removed." -f $DriveRoot)
        }
        # Ctrl+C / abort does not return to the caller — wipe the log here.
        # Normal return leaves the file for Show-RcloneMountLogTail, then the caller clears.
        if (-not $script:RcloneWatchReturned) {
            Start-Sleep -Milliseconds 200
            Clear-LoopSegmentsRcloneMountLog
        }
    }
}

try {
    $hostIp = Get-LoopSegmentsLANHost -Override $PhoneHost
    $portNum = Get-LoopSegmentsLanPort -Override $Port
    $driveLetter = Get-LoopSegmentsMountDriveLetter -Override $DriveLetter
    $remote = Get-LoopSegmentsRcloneRemoteName -Override $RemoteName
    $creds = Get-LoopSegmentsWebDAVCredentials -UserOverride $WebDAVUser -PasswordOverride $WebDAVPassword
    $webdavUrl = "http://${hostIp}:${portNum}/"
    $driveRoot = "${driveLetter}:\"
    $mountLabel = "${remote}:"
    $mountStartDir = ''

    if ($RemovePort80Proxy) {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
        if (-not $isAdmin) {
            Write-Warning 'Run PowerShell as Administrator to delete portproxy rules (netsh).'
        }
        Clear-LoopSegmentsPort80Proxy -PhoneHost $hostIp -PhonePort $portNum -DriveLetter $driveLetter
        exit 0
    }

    if ($Unstick -or $Remove) {
        Write-Host "Stopping phone rclone mount for ${driveLetter}: (remote $remote)..."
        $stopped = Stop-LoopSegmentsPhoneMountProcesses -DriveLetter $driveLetter -RemoteName $remote
        if (($stopped.Rclone + $stopped.PowerShell) -eq 0) {
            Write-Warning 'No matching rclone/mount PowerShell process found.'
        } else {
            Write-Host "Stopped rclone=$($stopped.Rclone) powershell=$($stopped.PowerShell)"
        }
        Start-Sleep -Milliseconds 500
        if (Test-Path -LiteralPath $driveRoot) {
            Write-Warning "${driveRoot} still present - Explorer may need a moment after restart."
        } else {
            Write-Host "${driveRoot} is gone (good)."
        }
        if (-not $Unstick) {
            Update-ExplorerForMappedDrive -DriveRoot $driveRoot -Removed
        }
        if ($Unstick) {
            Restart-WindowsExplorerShell
            Write-Host 'Unstick done. If Explorer is still wedged, Task Manager -> End task explorer.exe, then Run explorer.'
        }
        Clear-LoopSegmentsRcloneMountLog
        exit 0
    }

    if (-not $TestOnly) {
        if (-not (Test-LoopSegmentsWinFspInstalled)) {
            Write-Warning @'
WinFsp not detected. Set winfspDllPath or skipWinFspCheck in loop-segments-windows.json.
If Koofr rclone mount already works, run: ..\setup\Set-LoopSegmentsWindows.ps1 -SkipWinFspCheck
'@
        }
    }

    if ($TestOnly) {
        Test-PhoneLANExportWithOffSubnetRecovery -HostName $hostIp -PortNum $portNum -User $creds.User -Pass $creds.Password
        Ensure-RcloneRemote -Name $remote -Url $webdavUrl -User $creds.User -Pass $creds.Password
        Test-RcloneWebDAVRemote -Name $remote
        Write-Host 'OK - run without -TestOnly to mount.'
        exit 0
    }

    Test-PhoneLANExportWithOffSubnetRecovery -HostName $hostIp -PortNum $portNum -User $creds.User -Pass $creds.Password
    Ensure-RcloneRemote -Name $remote -Url $webdavUrl -User $creds.User -Pass $creds.Password
    if ($Quick) {
        Write-Host 'Quick mode: skipping rclone ls (companion already verified phone LAN).'
    } else {
        Test-RcloneWebDAVRemote -Name $remote
    }

    $driveLetter = Resolve-LoopSegmentsMountDriveLetter -Override $DriveLetter -PersistIfChanged
    $driveRoot = "${driveLetter}:\"
    if (Test-Path -LiteralPath $driveRoot) {
        if (Test-LoopSegmentsRcloneMountOnDrive -DriveLetter $driveLetter) {
            Write-Host "$driveRoot already mounted (loopsegments rclone). Reusing it."
        } else {
            throw "$driveRoot is still in use after picking a free letter. Close the other mapping or pass -DriveLetter."
        }
    }

    $settings = Get-LoopSegmentsWindowsSettings
    # rclone wants "L:" — trailing "L:\" can break WinFsp / Start-Process argument parsing.
    $mountPoint = "${driveLetter}:"
    if (Test-PhoneLanHasPcldIosMediaFolder -HostName $hostIp -PortNum $portNum -User $creds.User -Pass $creds.Password) {
        $mountStartDir = 'pcld_ios_media'
        $mountLabel = "${remote}:pcld_ios_media"
        Write-Host "Start directory: pcld_ios_media (present on phone LAN)"
    } else {
        Write-Host "Start directory: WebDAV root (pcld_ios_media not listed — L:\pcld_ios_media\ if the app creates it later)"
    }
    Write-Host ''
    $mountMode = if ($ReadOnly) { 'read-only' } else { 'read/write (phone blocks loop/, _working*, etc.)' }
    Write-Host "Mounting ${mountLabel} on $mountPoint ($mountMode). Ctrl+C stops the mount."
    if (-not $NoLanWatch) {
        Write-Host "LAN watch on: unmount if http://${hostIp}:${portNum}/ stays down for ${LanDownSeconds}s (poll ${LanPollSeconds}s)."
    }
    if ($mountStartDir) {
        if (-not $ReadOnly) {
            Write-Host "Bootstrap: copy your .ps1 to ${driveRoot} then run it (syncs scripts\ subfolders; <= 2 MB per file)."
        }
        Write-Host "DLNA / Explorer: ${driveRoot}loop\ (op_00|op_01) or ${driveRoot} (_working.mp4)"
    } else {
        if (-not $ReadOnly) {
            Write-Host "Bootstrap: copy your .ps1 to ${driveRoot}pcld_ios_media\ then run it (syncs scripts/ subfolders; <= 2 MB per file)."
        }
        Write-Host "DLNA / Explorer: ${driveRoot}pcld_ios_media\loop\ (op_00|op_01) or ${driveRoot}pcld_ios_media\ (_working.mp4)"
    }
    if (-not [string]::IsNullOrWhiteSpace($settings.dlnaFolder)) {
        Write-Host "Configured DLNA folder: $($settings.dlnaFolder)"
        Write-Host "  cmd /c mklink /J `"$($settings.dlnaFolder)\phone_exports`" `"$driveRoot`""
    }
    Write-Host ''

    $mountArgs = @(
        'mount', $mountLabel, $mountPoint,
        '--vfs-cache-mode', 'full',
        '--dir-cache-time', '5s',
        '--poll-interval', '10s',
        '--attr-timeout', '5s',
        '--volname', 'LoopSegments'
    )
    if ($ReadOnly) {
        $mountArgs += '--read-only'
    }

    if ($NoLanWatch) {
        try {
            Invoke-LoopSegmentsRclone @mountArgs
            $code = 0
            if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
            if ($code -ne 0) {
                Write-Host ('[Mount-LoopSegmentsRclone] rclone mount failed (exit {0}).' -f $code) -ForegroundColor Red
                Wait-EnterOnError -ExitCode $code
            }
        } finally {
            Start-Sleep -Milliseconds 400
            Update-ExplorerForMappedDrive -DriveRoot $driveRoot -Removed
            Write-Host ("[mount] Told Explorer {0} was removed." -f $driveRoot)
        }
        exit 0
    }

    $rcloneLog = Get-LoopSegmentsRcloneMountLogPath

    $rcloneProc = Find-LoopSegmentsRcloneMountProcess -DriveLetter $driveLetter -RemoteName $remote
    if ($null -ne $rcloneProc -and -not $rcloneProc.HasExited) {
        Write-Host "Reusing existing rclone mount PID $($rcloneProc.Id) for ${mountPoint} (skip second mount)."
        $existingCmd = ''
        try {
            $existingCmd = [string](Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $rcloneProc.Id) -ErrorAction SilentlyContinue).CommandLine
        } catch {}
        if ($mountStartDir -and $existingCmd -and ($existingCmd -notmatch '(?i)pcld_ios_media')) {
            Write-Warning "Existing mount is WebDAV root. -Unstick then remount to start in pcld_ios_media."
        }
        try { Register-LoopSegmentsRcloneLogConsoleGuard -RclonePid $rcloneProc.Id } catch {}
        if (Test-Path -LiteralPath $driveRoot) {
            Update-ExplorerForMappedDrive -DriveRoot $driveRoot
        }
    } else {
        if ((Test-Path -LiteralPath $driveRoot) -and $null -eq $rcloneProc) {
            Write-Warning "${driveRoot} exists but no matching rclone process - mount may fail. Try -Unstick first."
        }
        Clear-LoopSegmentsRcloneMountLog
        if (-not (Test-Path -LiteralPath $rcloneLog)) {
            try { New-Item -ItemType File -Path $rcloneLog -Force | Out-Null } catch {}
        }
        $rcloneProc = Start-LoopSegmentsRcloneMountProcess -MountArgs $mountArgs -LogFile $rcloneLog
        Write-Host "rclone mount started (PID $($rcloneProc.Id)); log: $rcloneLog"
        try { Register-LoopSegmentsRcloneLogConsoleGuard -RclonePid $rcloneProc.Id } catch {}
        # Brief settle so WinFsp can attach before the first LAN sleep cycle.
        Start-Sleep -Seconds 3
        try { $rcloneProc.Refresh() } catch {}
        if ($rcloneProc.HasExited) {
            $early = 1
            try { $early = [int]$rcloneProc.ExitCode } catch {}
            Write-Host ('[Mount-LoopSegmentsRclone] rclone exited immediately (exit {0}).' -f $early) -ForegroundColor Red
            Show-RcloneMountLogTail -LogFile $rcloneLog
            Write-Host "If ${mountPoint} was already mounted, run: .\Mount-LoopSegmentsRclone.ps1 -Unstick   then remount." -ForegroundColor Yellow
            # Archive to P: and delete Temp; companion tails Temp or the P: copy.
            Clear-LoopSegmentsRcloneMountLog
            Wait-EnterOnError -ExitCode $early
        }
        if (Wait-LoopSegmentsMountDrive -DriveRoot $driveRoot -TimeoutSec 12) {
            Update-ExplorerForMappedDrive -DriveRoot $driveRoot
            Write-Host ("[mount] Told Explorer {0} appeared." -f $driveRoot)
        } else {
            Write-Warning ("[mount] {0} not visible yet — Explorer This PC may need F5." -f $driveRoot)
        }
    }

    $code = Watch-LoopSegmentsRcloneMount `
        -RcloneProcess $rcloneProc `
        -HostName $hostIp `
        -PortNum $portNum `
        -DriveRoot $driveRoot `
        -PollSeconds $LanPollSeconds `
        -DownSeconds $LanDownSeconds

    if ($code -eq 2) {
        Write-Host '[Mount-LoopSegmentsRclone] Exited after prolonged LAN outage (rclone killed).'
        Show-RcloneMountLogTail -LogFile $rcloneLog
        Clear-LoopSegmentsRcloneMountLog
        exit 2
    }
    if ($code -ne 0) {
        Write-Host ('[Mount-LoopSegmentsRclone] rclone mount failed (exit {0}).' -f $code) -ForegroundColor Red
        Show-RcloneMountLogTail -LogFile $rcloneLog
        Clear-LoopSegmentsRcloneMountLog
        Wait-EnterOnError -ExitCode $code
    }
    Clear-LoopSegmentsRcloneMountLog
} catch {
    Write-Host ""
    Write-Host ('[Mount-LoopSegmentsRclone] {0}' -f $_.Exception.Message) -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    try {
        Show-RcloneMountLogTail -LogFile (Get-LoopSegmentsRcloneMountLogPath)
        Clear-LoopSegmentsRcloneMountLog
    } catch {}
    Wait-EnterOnError -ExitCode 1
}
