<#
.SYNOPSIS
  Quest control page: a small signed-in web page on this PC's LAN address for the Quest headset.

.DESCRIPTION
  Started hidden by the PC companion (quest\QuestCompanionHooks.ps1) and stopped at its close; exits
  by itself when -CompanionPid is gone. Opened in Quest Browser next to the phone LAN page by
  "Open on Quest" (questControlPageOnQuest).

  First actions: SKYBOX WebDAV server for the phone
    Push   : add 'Loop Segments' at the phone's current address with the current LAN login (and
             drop the servers this PC added at older addresses)
    Update : the same, but only if such a server is already in SKYBOX
    Clear  : remove every SKYBOX server this PC added
  Each runs quest\Watch-LoopSegmentsQuestLanTab.ps1 in the background; the page polls /status.json.

  3d_playlist_local: Space presses Space in the workflow's PowerShell window (pause / resume the leaf
  export); Enter runs 3d_playlist_local's Invoke-PlaylistLocalQuestShutdown.ps1 in the background (force-stop the
  Quest apps reading the workflow output and the configured players, Enter in the workflow window,
  Quest Browser tabs / history, sensor back on, Quest Wi-Fi off, then make sure the window exits).
  Also started without the companion by a 3d_playlist_local workflow
  (3d_playlist_local\individual_transcode\quest\Start-PlaylistLocalQuestSession.ps1, -CompanionPid = the workflow's PID).

  LAN bandwidth (PC -> Quest): on the headset the page downloads GET /speedtest/blob (64 MB) and posts
  bytes + milliseconds to POST /speedtest/result (only recorded from a non-loopback client, i.e. the
  headset). The result, with the recommended segment bitrate (80% of the measured Mbps, 5-100), goes
  to %TEMP%\loopsegments-quest-lan-throughput.json; 3d_playlist_local's segment encodes read it.

  LAN bandwidth (PC <-> phone): Measure LAN runs lan\Measure-LoopSegmentsLanThroughput.ps1 (HTTP,
  plus the rclone mount when it is up; never reboots routers) and shows its result file
  %TEMP%\loopsegments-lan-throughput.json, which the companion's startup probe also writes.

  Reachable from the LAN, so every request must pass all of:
    - client address is loopback or private (10/8, 172.16/12, 192.168/16, 169.254/16)
    - Host header is an IP literal or localhost (no DNS names: blocks DNS rebinding)
    - HTTP Basic auth = the phone LAN login (webdavUser + that phone's webdavPassword), the same
      login the phone LAN page uses; a failed login waits 1 s
    - actions: POST with header X-Quest-Control: 1 (a form or link on another site cannot send it,
      and the cross-origin preflight is refused)

  Settings (windows\loop-segments-windows.json): questControlPage, questControlPort (18766),
  questSkyboxWebDav (SKYBOX buttons). Log: %TEMP%\loopsegments-quest-lantab.log (actions) and
  %TEMP%\loopsegments-quest-control.log (this server).
#>
[CmdletBinding()]
param(
    [int] $Port = 0,
    # The companion's lan_config.json (phone address; re-read on every request).
    [string] $LanConfig = '',
    [int] $CompanionPid = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WindowsDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $WindowsDir 'lib\LoopSegments-Windows.ps1')
$script:WatchScript = Join-Path $PSScriptRoot 'Watch-LoopSegmentsQuestLanTab.ps1'
$script:QuestLog = Join-Path $env:TEMP 'loopsegments-quest-lantab.log'
$script:ServerLog = Join-Path $env:TEMP 'loopsegments-quest-control.log'
$script:StatePath = Join-Path $env:TEMP 'loopsegments-quest-control.json'
$script:SkyboxStatePath = Join-Path $env:TEMP 'loopsegments-skybox-webdav.json'
$script:LanBwScript = Join-Path $WindowsDir 'lan\Measure-LoopSegmentsLanThroughput.ps1'
# Written by the measure script (-ResultFile), also by the companion's startup probe.
$script:LanBwResultPath = Join-Path $env:TEMP 'loopsegments-lan-throughput.json'
$script:LanBwLog = Join-Path $env:TEMP 'loopsegments-quest-control-lanbw.log'

function Write-ControlLog {
    param([string] $Message)
    try { Add-Content -LiteralPath $script:ServerLog -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding utf8 } catch {}
}

function Get-ControlSettings { Get-LoopSegmentsWindowsSettings }

if ($Port -le 0) {
    $Port = 18766
    try { $p = [int](Get-ControlSettings).questControlPort; if ($p -gt 0) { $Port = $p } } catch {}
}

# ---- Phone address and login (re-read each time, like the rest of the Quest hooks) ----

function Get-ControlLanUrl {
    if ([string]::IsNullOrWhiteSpace($LanConfig) -or -not (Test-Path -LiteralPath $LanConfig)) { return $null }
    try {
        $c = Get-Content -LiteralPath $LanConfig -Raw | ConvertFrom-Json
        $h = ([string]$c.phoneLanHost).Trim()
        if ([string]::IsNullOrWhiteSpace($h)) { return $null }
        $pt = 8765
        if ($null -ne $c.lanPort -and [int]$c.lanPort -gt 0) { $pt = [int]$c.lanPort }
        return "http://${h}:${pt}/"
    } catch { return $null }
}

# webdavUser + the matching phoneLanHosts[].webdavPassword, else webdavPassword. Never logged.
function Get-ControlLogin {
    $cred = Get-LoopSegmentsWebDAVCredentials
    $pass = [string]$cred.Password
    $lan = Get-ControlLanUrl
    if ($lan) {
        $hostName = ([Uri]$lan).Host
        foreach ($raw in @((Get-ControlSettings).phoneLanHosts)) {
            if ($null -eq $raw) { continue }
            $e = ConvertTo-LoopSegmentsPhoneHostEntry -Raw $raw
            if ($e -and $e.Host -eq $hostName -and -not [string]::IsNullOrWhiteSpace([string]$e.Password)) { $pass = [string]$e.Password }
        }
    }
    return [pscustomobject]@{ User = [string]$cred.User; Password = $pass }
}

# ---- Request checks ----

function Test-ControlClientAllowed {
    param([System.Net.IPAddress] $Address)
    return (Test-LoopSegmentsPrivateLanAddress -Address $Address)
}

function Get-ControlHeader {
    param([string] $HeaderText, [string] $Name)
    foreach ($l in ($HeaderText -split "`r`n")) {
        if ($l -match ('^(?i)' + [regex]::Escape($Name) + ':\s*(.*)$')) { return $Matches[1].Trim() }
    }
    return $null
}

function Test-ControlHostHeader {
    param([string] $HeaderText)
    return (Test-LoopSegmentsIpLiteralHostHeader -HostHeader (Get-ControlHeader -HeaderText $HeaderText -Name 'Host'))
}

function Test-ControlAuth {
    param([string] $HeaderText)
    $a = Get-ControlHeader -HeaderText $HeaderText -Name 'Authorization'
    if (-not $a -or $a -notmatch '^(?i)Basic\s+(\S+)$') { return $false }
    try { $given = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1])) } catch { return $false }
    $login = Get-ControlLogin
    if ([string]::IsNullOrEmpty($login.Password)) { return $false }
    $want = [Text.Encoding]::UTF8.GetBytes(('{0}:{1}' -f $login.User, $login.Password))
    $got = [Text.Encoding]::UTF8.GetBytes($given)
    return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($want, $got)
}

# ---- PC browser sign-in (3d_playlist_local workflow start opens http://127.0.0.1:<port>/pc?t=<token>) ----

# Token written by 3d_playlist_local's Start-PlaylistLocalQuestSession.ps1; re-read per request (also works for the
# companion's server). Loopback clients only: /pc?t=<token> sets an HttpOnly cookie and redirects to
# the page, so the PC tab needs no Basic login and its session history stays one entry (the page
# can then close its own tab after Enter).
$script:PcTokenPath = Join-Path $env:TEMP 'loopsegments-quest-control-pctoken.txt'

function Get-ControlPcToken {
    try { $t = (Get-Content -LiteralPath $script:PcTokenPath -Raw -ErrorAction Stop).Trim(); if ($t.Length -ge 32) { return $t } } catch {}
    return $null
}

function Test-ControlTokenEqual {
    param([string] $A, [string] $B)
    if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B)) { return $false }
    return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals([Text.Encoding]::UTF8.GetBytes($A), [Text.Encoding]::UTF8.GetBytes($B))
}

function Test-ControlPcCookie {
    param([string] $HeaderText, [System.Net.IPAddress] $Remote)
    if (-not [System.Net.IPAddress]::IsLoopback($Remote)) { return $false }
    $c = Get-ControlHeader -HeaderText $HeaderText -Name 'Cookie'
    if (-not $c -or $c -notmatch '(?:^|;\s*)qcpc=([A-Za-z0-9]+)') { return $false }
    return (Test-ControlTokenEqual -A $Matches[1] -B (Get-ControlPcToken))
}

# ---- HTTP ----

function Read-ControlRequest {
    param([System.Net.Sockets.TcpClient] $Client)
    $stream = $Client.GetStream()
    $stream.ReadTimeout = 5000
    $buffer = New-Object byte[] 16384
    $ms = New-Object System.IO.MemoryStream
    while ($ms.Length -lt 65536) {
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { break }
        $ms.Write($buffer, 0, $read)
        $text = [Text.Encoding]::UTF8.GetString($ms.ToArray())
        $end = $text.IndexOf("`r`n`r`n")
        if ($end -lt 0) { continue }
        $headerText = $text.Substring(0, $end)
        # Bodies are not used (actions carry everything in the path); a Content-Length body is
        # left unread on purpose.
        return [pscustomobject]@{ RequestLine = ($headerText -split "`r`n")[0]; HeaderText = $headerText; Stream = $stream }
    }
    return $null
}

function Write-ControlResponse {
    param(
        [System.IO.Stream] $Stream,
        [int] $StatusCode,
        [string] $Body,
        [string] $ContentType = 'application/json; charset=utf-8',
        [string[]] $ExtraHeaders = @()
    )
    $reason = @{ 200 = 'OK'; 202 = 'Accepted'; 302 = 'Found'; 400 = 'Bad Request'; 401 = 'Unauthorized'; 403 = 'Forbidden'; 404 = 'Not Found'; 405 = 'Method Not Allowed'; 409 = 'Conflict' }[$StatusCode]
    if (-not $reason) { $reason = 'Error' }
    $payload = [Text.Encoding]::UTF8.GetBytes($Body)
    $h = "HTTP/1.1 $StatusCode $reason`r`nContent-Type: $ContentType`r`nContent-Length: $($payload.Length)`r`n" +
         "Cache-Control: no-store`r`nX-Frame-Options: DENY`r`nX-Content-Type-Options: nosniff`r`nReferrer-Policy: no-referrer`r`n" +
         "Content-Security-Policy: default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'`r`n"
    foreach ($x in $ExtraHeaders) { $h += "$x`r`n" }
    $h += "Connection: close`r`n`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($h)
    $Stream.Write($hb, 0, $hb.Length)
    $Stream.Write($payload, 0, $payload.Length)
    $Stream.Flush()
}

function ConvertTo-ControlJson { param($Object) ($Object | ConvertTo-Json -Compress -Depth 5) }

# ---- Actions (one at a time) ----

$script:Action = $null

function Get-ControlActionStatus {
    $a = $script:Action
    if (-not $a) { return [ordered]@{ name = ''; state = 'idle' } }
    $state = if ($a.Proc.HasExited) { 'done' } else { 'running' }
    $result = ''
    if (Test-Path -LiteralPath $a.StatusFile) { try { $result = (Get-Content -LiteralPath $a.StatusFile -Raw).Trim() } catch {} }
    $out = [ordered]@{ name = $a.Name; state = $state; result = $result; startedAt = $a.StartedAt.ToString('HH:mm:ss') }
    if ($state -eq 'done') { $out.exitCode = $a.Proc.ExitCode }
    return $out
}

function Start-ControlAction {
    param([ValidateSet('push', 'update', 'clear')] [string] $Name)
    if ($script:Action -and -not $script:Action.Proc.HasExited) { return $false }
    $switch = @{ push = '-SkyboxPush'; update = '-SkyboxUpdate'; clear = '-ClearSkyboxWebDav' }[$Name]
    $statusFile = Join-Path $env:TEMP 'loopsegments-quest-control-action.txt'
    Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue
    $pwsh = (Get-Process -Id $PID).Path
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwsh
    foreach ($a in @('-NoProfile', '-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:WatchScript,
            $switch, '-LanConfig', $LanConfig, '-StatusFile', $statusFile)) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $script:Action = [pscustomobject]@{ Name = $Name; Proc = $proc; StatusFile = $statusFile; StartedAt = (Get-Date) }
    Write-ControlLog "ACTION_START $Name (pid $($proc.Id))"
    return $true
}

# ---- LAN bandwidth (PC <-> phone): the same probe the companion runs at startup ----

$script:LanBw = $null

# HTTP + rclone mount when the mount drive is up, else HTTP only. Never reboots routers from a
# page click (-SkipLowThroughputGatewayReboot); only the companion's startup probe does that.
function Start-ControlLanBw {
    if ($script:LanBw -and -not $script:LanBw.Proc.HasExited) { return $false }
    $letter = Get-LoopSegmentsMountDriveLetter
    $mountUp = [bool](Test-Path -LiteralPath "${letter}:\" -ErrorAction SilentlyContinue)
    $q = { param($s) "'" + ([string]$s -replace "'", "''") + "'" }
    $cmd = "& $(& $q $script:LanBwScript) -NoWaitEnter -SkipLowThroughputGatewayReboot -DriveLetter $letter " +
           $(if ($mountUp) { '-WaitMountSec 15' } else { '-WaitMountSec 0 -HttpOnly' }) +
           " -ResultFile $(& $q $script:LanBwResultPath) *>&1 | ForEach-Object { Add-Content -LiteralPath $(& $q $script:LanBwLog) -Value (`"`$_`") -Encoding utf8 }; exit `$LASTEXITCODE"
    Remove-Item -LiteralPath $script:LanBwLog -Force -ErrorAction SilentlyContinue
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Process -Id $PID).Path
    foreach ($a in @('-NoProfile', '-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $script:LanBw = [pscustomobject]@{ Proc = $proc; StartedAt = (Get-Date); Mount = $mountUp }
    Write-ControlLog "ACTION_START lan-measure (pid $($proc.Id), mount $(if ($mountUp) { 'up' } else { 'down: HTTP only' }))"
    return $true
}

function Get-ControlLanBwStatus {
    $out = [ordered]@{ state = 'idle'; result = $null; lines = @() }
    $a = $script:LanBw
    if ($a) {
        $out.state = if ($a.Proc.HasExited) { 'done' } else { 'running' }
        $out.startedAt = $a.StartedAt.ToString('HH:mm:ss')
        $out.mount = $a.Mount
        if ($a.Proc.HasExited) { $out.exitCode = $a.Proc.ExitCode }
        if (Test-Path -LiteralPath $script:LanBwLog) {
            try { $out.lines = @(Get-Content -LiteralPath $script:LanBwLog -Tail 60 | Where-Object { $_.Trim() } | Select-Object -Last 12) } catch {}
        }
    }
    if (Test-Path -LiteralPath $script:LanBwResultPath) {
        try { $out.result = Get-Content -LiteralPath $script:LanBwResultPath -Raw | ConvertFrom-Json } catch {}
    }
    return $out
}

# ---- 3d_playlist_local: press Space in its PowerShell window (pause / resume leaf DLNA export) ----

$script:SpaceScript = Join-Path $PSScriptRoot 'Send-PlaylistLocalSpaceKey.ps1'

# Runs the helper in its own process (it detaches from its console to attach to the target's) and
# waits for it: a few seconds at most. Returns the helper's JSON object.
function Invoke-ControlPlaylistSpace {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Process -Id $PID).Path
    foreach ($a in @('-NoProfile', '-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:SpaceScript)) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(20000)) {
        try { $proc.Kill($true) } catch {}
        Write-ControlLog 'PLAYLIST_SPACE timed out'
        return [ordered]@{ ok = $false; sent = 0; error = 'timed out' }
    }
    $text = ($outTask.Result -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    $r = $null
    if ($text) { try { $r = $text | ConvertFrom-Json } catch {} }
    if (-not $r) {
        $e = ($errTask.Result + ' ' + $outTask.Result).Trim()
        if ($e.Length -gt 300) { $e = $e.Substring(0, 300) }
        $r = [pscustomobject]@{ ok = $false; sent = 0; error = $(if ($e) { $e } else { "exit $($proc.ExitCode)" }) }
    }
    $who = @(@($r.PSObject.Properties['consoles'] | ForEach-Object { $_.Value }) | Where-Object { $_ } | ForEach-Object { '{0} pid {1}' -f $_.script, $_.pid }) -join ', '
    Write-ControlLog ("PLAYLIST_SPACE sent={0} {1}{2}" -f $r.sent, $who, $(if ($r.PSObject.Properties['error'] -and $r.error) { " error: $($r.error)" } else { '' }))
    return $r
}

# ---- LAN bandwidth PC -> Quest (the page on the headset downloads a blob from here) ----

$script:QuestLanResultPath = Join-Path $env:TEMP 'loopsegments-quest-lan-throughput.json'
$script:BlobChunk = $null

# Raw octet-stream body of -Bytes bytes (random 1 MiB chunk repeated: not compressible).
function Write-ControlBlob {
    param([System.IO.Stream] $Stream, [long] $Bytes)
    if (-not $script:BlobChunk) {
        $script:BlobChunk = [byte[]]::new(1MB)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($script:BlobChunk)
    }
    try { $Stream.WriteTimeout = 20000 } catch {}
    $h = "HTTP/1.1 200 OK`r`nContent-Type: application/octet-stream`r`nContent-Length: $Bytes`r`nCache-Control: no-store`r`n" +
         "X-Content-Type-Options: nosniff`r`nConnection: close`r`n`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($h)
    $Stream.Write($hb, 0, $hb.Length)
    $left = $Bytes
    while ($left -gt 0) {
        $n = [int][Math]::Min([long]$script:BlobChunk.Length, $left)
        $Stream.Write($script:BlobChunk, 0, $n)
        $left -= $n
    }
    $Stream.Flush()
}

function Save-ControlQuestLanResult {
    param([long] $Bytes, [double] $Ms, [string] $Client)
    $mbps = [Math]::Round(($Bytes * 8.0) / ($Ms / 1000.0) / 1e6, 1)
    $rec = [int][Math]::Floor($mbps * 0.8)
    if ($rec -lt 5) { $rec = 5 }
    if ($rec -gt 100) { $rec = 100 }
    $o = [ordered]@{
        ok = $true; path = 'pc->quest'; measuredMbps = $mbps; recommendedMaxMediaBitrateMbps = $rec; recommendHeadroom = 0.8
        bytes = $Bytes; seconds = [Math]::Round($Ms / 1000.0, 2); client = $Client; measuredAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $tmp = "$($script:QuestLanResultPath).tmp"
    ($o | ConvertTo-Json -Compress) | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $script:QuestLanResultPath -Force
    Write-ControlLog ("QUEST_LAN {0} Mbps from {1} ({2} bytes in {3} ms) -> segment bitrate {4} Mbps" -f $mbps, $Client, $Bytes, [int]$Ms, $rec)
    return $o
}

function Get-ControlQuestLanStatus {
    if (-not (Test-Path -LiteralPath $script:QuestLanResultPath)) { return $null }
    try {
        $j = Get-Content -LiteralPath $script:QuestLanResultPath -Raw | ConvertFrom-Json
        $at = [DateTime]::Parse([string]$j.measuredAtUtc, $null, [Globalization.DateTimeStyles]::RoundtripKind)
        $j | Add-Member -NotePropertyName ageSec -NotePropertyValue ([int]([DateTime]::UtcNow - $at.ToUniversalTime()).TotalSeconds) -Force
        return $j
    } catch { return $null }
}

# ---- 3d_playlist_local Enter: stop the workflow + Quest cleanup (Invoke-PlaylistLocalQuestShutdown.ps1) ----

# The script lives in 3d_playlist_local (individual_transcode\quest); each workflow registers its
# own copy in %TEMP%\loopsegments-playlist-session.json. Newest running one wins.
$script:PlaylistSessionPath = Join-Path $env:TEMP 'loopsegments-playlist-session.json'
$script:DefaultShutdownScript = 'P:\all_scripts\3d_playlist_local\individual_transcode\quest\Invoke-PlaylistLocalQuestShutdown.ps1'

function Get-ControlShutdownScript {
    try {
        $list = @((Get-Content -LiteralPath $script:PlaylistSessionPath -Raw -ErrorAction Stop | ConvertFrom-Json).sessions)
        [array]::Reverse($list)
        foreach ($e in $list) {
            if (-not $e -or -not $e.PSObject.Properties['shutdownScript']) { continue }
            if (-not (Get-Process -Id ([int]$e.pid) -ErrorAction SilentlyContinue)) { continue }
            if (Test-Path -LiteralPath ([string]$e.shutdownScript) -PathType Leaf) { return [string]$e.shutdownScript }
        }
    } catch {}
    if (Test-Path -LiteralPath $script:DefaultShutdownScript -PathType Leaf) { return $script:DefaultShutdownScript }
    return $null
}
$script:ShutdownStatusPath = Join-Path $env:TEMP 'loopsegments-playlist-shutdown.json'

function Get-ControlPlaylistStop {
    if (-not (Test-Path -LiteralPath $script:ShutdownStatusPath)) { return $null }
    try { $j = Get-Content -LiteralPath $script:ShutdownStatusPath -Raw | ConvertFrom-Json } catch { return $null }
    # A run that died mid-way (killed, PC restarted) is not 'running' any more.
    if ($j.state -eq 'running' -and -not (Get-Process -Id ([int]$j.pid) -ErrorAction SilentlyContinue)) { $j.state = 'stopped' }
    return $j
}

# Detached from this server on purpose: the workflow exits during the run, and this server stops
# with it (-CompanionPid), while the run goes on with the Quest steps.
function Start-ControlPlaylistShutdown {
    $cur = Get-ControlPlaylistStop
    if ($cur -and $cur.state -eq 'running') { return 'running' }
    $shutdownPath = Get-ControlShutdownScript
    if (-not $shutdownPath) { Write-ControlLog 'PLAYLIST_ENTER no Invoke-PlaylistLocalQuestShutdown.ps1 found'; return 'missing' }
    # Started through WMI (Win32_Process.Create), so its parent is not this server: the companion's
    # quit kills this server with its whole process tree, and the run has to outlive that.
    $exe = (Get-Process -Id $PID).Path
    $cmd = '"{0}" -NoProfile -NoLogo -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}"' -f $exe, $shutdownPath
    $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; ProcessStartupInformation = $startup }
    if ($r.ReturnValue -ne 0) { Write-ControlLog "PLAYLIST_ENTER Win32_Process.Create failed ($($r.ReturnValue))"; return 'missing' }
    $newPid = [int]$r.ProcessId
    try { @{ pid = $newPid; state = 'running'; startedAt = (Get-Date -Format 'HH:mm:ss'); steps = @() } | ConvertTo-Json -Compress | Set-Content -LiteralPath $script:ShutdownStatusPath -Encoding utf8 } catch {}
    Write-ControlLog "PLAYLIST_ENTER started End session (pid $newPid, detached, $shutdownPath)"
    return 'started'
}

# For the End session button: registered 3d_playlist_local workflows still running, and the companion
# (its launcher shell or its Chromium; not its REST log sink, which can outlive it).
function Get-ControlSessionParts {
    $wf = @()
    try {
        foreach ($e in @((Get-Content -LiteralPath $script:PlaylistSessionPath -Raw -ErrorAction Stop | ConvertFrom-Json).sessions)) {
            if ($e -and (Get-Process -Id ([int]$e.pid) -ErrorAction SilentlyContinue)) { $wf += [string]$e.name }
        }
    } catch {}
    $comp = @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe' OR Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $c = [string]$_.CommandLine
                ($_.Name -ne 'chrome.exe' -and $c -match '(?i)pcloud_web_companion[\\/]+(Run-PCloudWebCompanion|_run_chromium)\.ps1') -or
                ($_.Name -eq 'chrome.exe' -and $c -notlike '*--type=*' -and $c -match '(?i)pcloud_web_companion[\\/]+chromium-profile')
            }).Count -gt 0
    return [ordered]@{ workflows = @($wf); companion = $comp }
}

function Get-ControlStatus {
    $s = Get-ControlSettings
    $lan = Get-ControlLanUrl
    $added = @()
    if (Test-Path -LiteralPath $script:SkyboxStatePath) {
        try { $added = @((Get-Content -LiteralPath $script:SkyboxStatePath -Raw | ConvertFrom-Json).urls | Where-Object { $_ }) } catch {}
    }
    $log = @()
    if (Test-Path -LiteralPath $script:QuestLog) {
        try { $log = @(Get-Content -LiteralPath $script:QuestLog -Tail 400 | Where-Object { $_ -match ' SKYBOX:' } | Select-Object -Last 8) } catch {}
    }
    $login = Get-ControlLogin
    return [ordered]@{
        ok            = $true
        skyboxEnabled = [bool]$s.questSkyboxWebDav
        phoneLanUrl   = $lan
        skyboxUrl     = $(if ($lan) { 'webdav://{0}:{1}/' -f ([Uri]$lan).Host, ([Uri]$lan).Port } else { $null })
        user          = $login.User
        hasPassword   = -not [string]::IsNullOrEmpty($login.Password)
        addedByThisPc = $added
        action        = (Get-ControlActionStatus)
        log           = $log
        lanBw         = (Get-ControlLanBwStatus)
        playlistStop  = (Get-ControlPlaylistStop)
        session       = (Get-ControlSessionParts)
        questLan      = (Get-ControlQuestLanStatus)
    }
}

# ---- Page ----

$script:PageHtml = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Quest control</title>
<style>
  :root { color-scheme: dark; --bg:#111418; --panel:#1b2027; --line:#2c333d; --text:#e8ecf1; --muted:#9aa5b1; --accent:#4c9aff; --ok:#3fb950; --warn:#d29922; --bad:#f85149; }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font:18px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
  main { max-width: 1440px; margin: 0 auto; padding: 14px 16px 12px; }
  header { display:flex; flex-wrap: wrap; align-items: baseline; gap: 4px 14px; margin: 0 0 16px; }
  h1 { font-size: 26px; margin: 0; }
  .sub { color: var(--muted); margin: 0; font-size: 15px; }
  /* Tiles side by side on a wide window (Quest Browser is landscape), one column on a phone. */
  /* Two columns that each stack their own tiles (no shared row height, so no gap under a short
     tile), wrapping to one column on a phone. */
  .tiles { display:flex; flex-wrap: wrap; gap: 12px; align-items: flex-start; }
  .tiles .col { flex: 1 1 420px; min-width: 0; display:flex; flex-direction: column; gap: 12px; }
  .tiles .wide { flex-basis: 100%; }
  section { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 14px 16px; min-width: 0; }
  #log { max-height: 7.5em; overflow-y: auto; }
  #msg:empty, .msg:empty { display: none; }
  #bwLines { max-height: 9em; overflow-y: auto; }
  h2 { font-size: 19px; margin: 0 0 10px; }
  dl { display:grid; grid-template-columns: max-content 1fr; gap: 4px 14px; margin: 0 0 12px; font-size: 16px; }
  dt { color: var(--muted); }
  dd { margin: 0; overflow-wrap: anywhere; font-family: ui-monospace, Consolas, monospace; font-size: 15px; }
  .buttons { display:flex; flex-wrap: wrap; gap: 12px; }
  button { font: inherit; font-size: 16px; font-weight: 600; min-height: 40px; min-width: 96px; padding: 0 16px; border-radius: 8px; border: 1px solid var(--line); background: #252c35; color: var(--text); cursor: pointer; }
  button.primary { background: var(--accent); border-color: var(--accent); color: #0b1320; }
  button.danger { border-color: #6e2b2b; color: #ffb4ae; }
  button:disabled { opacity: .45; cursor: default; }
  .note { color: var(--muted); font-size: 14px; margin: 10px 0 0; }
  #msg, .msg { margin-top: 10px; min-height: 1.4em; font-size: 16px; }
  .ok { color: var(--ok); } .warn { color: var(--warn); } .bad { color: var(--bad); }
  #bwLines { margin-top: 10px; }
  pre { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; font: 13px/1.5 ui-monospace, Consolas, monospace; color: var(--muted); }
</style>
</head>
<body>
<main>
  <header>
    <h1>Quest control</h1>
    <p class="sub">Loop Segments PC companion / 3d_playlist_local</p>
  </header>

  <div class="tiles">
  <div class="col">
    <section>
      <h2>SKYBOX: phone as a WebDAV server</h2>
      <dl>
        <dt>Phone LAN page</dt><dd id="lan">-</dd>
        <dt>SKYBOX server</dt><dd id="dav">-</dd>
        <dt>Login</dt><dd id="user">-</dd>
        <dt>Added by this PC</dt><dd id="added">-</dd>
      </dl>
      <div class="buttons">
        <button id="push" class="primary" data-action="push">Push</button>
        <button id="update" data-action="update">Update</button>
        <button id="clear" class="danger" data-action="clear">Clear</button>
      </div>
      <div id="msg" role="status" aria-live="polite"></div>
      <p class="note">Push adds "Loop Segments" to SKYBOX's Network list at the phone's current address with the current login (and removes older addresses). Update does the same only if it is already there. Clear removes it. SKYBOX restarts if it is open when the server changes; it is also removed when the companion quits.</p>
    </section>
    <section>
      <h2>3d_playlist_local</h2>
      <div class="buttons">
        <button id="plSpace" class="primary">Space: pause / resume export</button>
        <button id="plEnter" class="danger">End session: stop all</button>
      </div>
      <div id="plParts" class="msg"></div>
      <div id="plMsg" class="msg" role="status" aria-live="polite"></div>
      <pre id="plStop" hidden></pre>
      <p class="note">Space presses Space once in the 3d_playlist_local PowerShell window on the PC (run_batch_*.ps1 / Run-TranscodeOrchestrator.ps1), the same as pressing it there: while a clip runs it pauses or resumes the leaf DLNA export. The window does not need focus.</p>
      <p class="note">End session stops whatever is running, in this order, and skips what is not: force-stops the Quest apps reading the segments and the configured players (SKYBOX); presses Enter in every 3d_playlist_local window and waits for it to exit (killed after a few minutes); closes the Loop Segments companion's Chromium, so its normal quit runs (Quest tabs, history, SKYBOX, sensor, Wi-Fi off, the phone mount, iPhone Home). Without the companion it cleans up the headset itself: closes these tabs, deletes their history, turns the sensor back on, switches the Wi-Fi off. The Quest history is deleted once either way.</p>
    </section>
  </div>

  <div class="col">
    <section>
      <h2>LAN bandwidth: PC &rarr; Quest</h2>
      <dl>
        <dt>Result</dt><dd id="qlMbps">-</dd>
        <dt>Segment bitrate</dt><dd id="qlRec">-</dd>
        <dt>Measured</dt><dd id="qlAt">-</dd>
      </dl>
      <div class="buttons">
        <button id="qlMeasure" class="primary">Measure PC &rarr; Quest</button>
      </div>
      <div id="qlMsg" class="msg" role="status" aria-live="polite"></div>
      <p class="note">The headset downloads 64 MB from this PC (the same Wi-Fi path DLNA uses). Runs by itself each time this page opens on the Quest at a 3d_playlist_local workflow start; 3d_playlist_local encodes the next minute segments at 80% of the result (5-100 Mbps). Only the headset can run it.</p>
    </section>
    <section>
      <h2>LAN bandwidth: PC &harr; phone</h2>
      <dl>
        <dt>Result</dt><dd id="bwMbps">-</dd>
        <dt>HTTP / mount</dt><dd id="bwPaths">-</dd>
        <dt>Max segment bitrate</dt><dd id="bwRec">-</dd>
        <dt>Measured</dt><dd id="bwAt">-</dd>
      </dl>
      <div class="buttons">
        <button id="bwMeasure" class="primary">Measure LAN</button>
      </div>
      <div id="bwMsg" class="msg" role="status" aria-live="polite"></div>
      <pre id="bwLines" hidden></pre>
      <p class="note">Runs the same probe as the companion at startup (lan\Measure-LoopSegmentsLanThroughput.ps1): downloads up to 64 MB of a phone video over HTTP, and copies it from the rclone mount when the mount is up, then uses the lower number. It never reboots routers from here. Takes about 10-60 s; pause a Virtual Desktop session first or the number comes out low.</p>
    </section>
  </div>

  <section class="wide">
    <h2>Recent SKYBOX log</h2>
    <pre id="log">-</pre>
  </section>
  </div>
</main>
<script>
(() => {
  const $ = (id) => document.getElementById(id);
  const buttons = [...document.querySelectorAll('button[data-action]')];
  const verbs = { added: 'added', updated: 'updated', unchanged: 'already up to date', removed: 'removed', absent: 'not there', failed: 'failed', 'not installed': 'SKYBOX is not installed', unreachable: 'headset not on adb' };
  let running = false, timer = null, lastShown = '';

  function setMsg(text, cls) { const m = $('msg'); m.textContent = text; m.className = cls || ''; }

  function render(s) {
    $('lan').textContent = s.phoneLanUrl || 'unknown (no lan_config.json)';
    $('dav').textContent = s.skyboxUrl || '-';
    $('user').textContent = s.user + (s.hasPassword ? '' : ' (no password set on the PC)');
    $('added').textContent = (s.addedByThisPc && s.addedByThisPc.length) ? s.addedByThisPc.join('\n') : 'none';
    $('log').textContent = (s.log && s.log.length) ? s.log.join('\n') : 'nothing yet';
    const a = s.action || {};
    running = a.state === 'running';
    const usable = s.skyboxEnabled && s.hasPassword && !!s.phoneLanUrl;
    buttons.forEach(b => b.disabled = running || !usable);
    if (!s.skyboxEnabled) setMsg('SKYBOX buttons are off (questSkyboxWebDav=false on the PC).', 'warn');
    else if (running) setMsg(a.name[0].toUpperCase() + a.name.slice(1) + ' running (started ' + a.startedAt + ')...', 'warn');
    else if (a.state === 'done') {
      const key = a.name + a.startedAt;
      const word = verbs[a.result] || (a.exitCode === 0 ? 'done' : 'failed');
      const ok = a.exitCode === 0 && a.result !== 'failed';
      const text = a.name[0].toUpperCase() + a.name.slice(1) + ' at ' + a.startedAt + ': ' + word + '.';
      if (key !== lastShown || $('msg').textContent === '') { setMsg(text, ok ? 'ok' : 'bad'); lastShown = key; }
    }
    const bwRunning = renderBw(s.lanBw || {});
    const stopRunning = renderStop(s.playlistStop);
    renderParts(s.session);
    renderQuestLan(s.questLan);
    schedule((running || bwRunning || stopRunning) ? 1500 : 10000);
  }

  function mbps(v) { return (v === null || v === undefined) ? '-' : Number(v).toFixed(1) + ' Mbps'; }

  // Returns true while a measurement runs.
  function renderBw(b) {
    const r = b.result, m = $('bwMsg');
    if (r && r.ok) {
      const low = r.belowMin;
      $('bwMbps').textContent = mbps(r.measuredMbps) + ' (' + r.measureMethod + ')' + (low ? '  LOW: under ' + r.minLanThroughputMbps + ' Mbps' : '');
      $('bwMbps').className = low ? 'bad' : 'ok';
      $('bwPaths').textContent = mbps(r.measuredHttpMbps) + ' / ' + (r.measuredMountMbps === null ? 'not measured' : mbps(r.measuredMountMbps));
      $('bwRec').textContent = r.recommendedMaxMediaBitrateMbps + ' Mbps (min LAN ' + r.minLanThroughputMbps + ' Mbps)';
    } else if (r && !r.ok) {
      $('bwMbps').textContent = 'failed: ' + (r.error || 'unknown error'); $('bwMbps').className = 'bad';
      $('bwPaths').textContent = '-'; $('bwRec').textContent = '-';
    }
    if (r && r.measuredAtUtc) {
      const d = new Date(r.measuredAtUtc);
      $('bwAt').textContent = d.toLocaleString() + (r.virtualDesktopRunning ? '  (Virtual Desktop was running: may read low)' : '');
    }
    const running = b.state === 'running';
    $('bwMeasure').disabled = running;
    const lines = b.lines || [];
    $('bwLines').hidden = !(running || (b.state === 'done' && lines.length));
    $('bwLines').textContent = lines.join('\n');
    if (running) { m.textContent = 'Measuring (started ' + b.startedAt + (b.mount ? '' : ', mount not up: HTTP only') + ')...'; m.className = 'msg warn'; }
    else if (b.state === 'done') {
      const ok = b.exitCode === 0 && r && r.ok;
      m.textContent = 'Measurement at ' + b.startedAt + ': ' + (ok ? 'done.' : 'failed (exit ' + b.exitCode + ').'); m.className = 'msg ' + (ok ? 'ok' : 'bad');
    } else if (!r) { m.textContent = 'No measurement yet.'; m.className = 'msg'; }
    return running;
  }

  $('bwMeasure').addEventListener('click', async () => {
    $('bwMeasure').disabled = true;
    const m = $('bwMsg'); m.textContent = 'Starting...'; m.className = 'msg warn';
    try {
      const r = await fetch('lan/measure', { method: 'POST', headers: { 'X-Quest-Control': '1' } });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) { m.textContent = j.error || ('HTTP ' + r.status); m.className = 'msg bad'; }
    } catch (e) { m.textContent = 'Request failed: ' + e.message; m.className = 'msg bad'; }
    schedule(800);
  });

  // ---- PC -> Quest bandwidth (runs on the headset only) ----
  let qlRunning = false, qlAutoDone = false;
  function renderQuestLan(q) {
    if (q && q.ok) {
      $('qlMbps').textContent = Number(q.measuredMbps).toFixed(1) + ' Mbps (' + (q.bytes / 1048576).toFixed(0) + ' MB in ' + q.seconds + ' s, ' + q.client + ')';
      $('qlMbps').className = 'ok';
      $('qlRec').textContent = q.recommendedMaxMediaBitrateMbps + ' Mbps (80%, 5-100)';
      $('qlAt').textContent = new Date(q.measuredAtUtc).toLocaleString();
    }
    $('qlMeasure').disabled = qlRunning || !onQuest;
    if (!onQuest && !qlRunning && !$('qlMsg').textContent) { $('qlMsg').textContent = 'Run it from the headset (this page on the Quest measures by itself when it opens).'; $('qlMsg').className = 'msg'; }
    // A fresh page on the headset measures once (unless a result under 2 min old exists).
    if (onQuest && !qlAutoDone && !qlRunning) { qlAutoDone = true; if (!(q && q.ok && q.ageSec < 120)) measureQuestLan(); }
  }

  async function measureQuestLan() {
    const m = $('qlMsg');
    qlRunning = true; $('qlMeasure').disabled = true;
    m.textContent = 'Measuring PC -> Quest (64 MB)...'; m.className = 'msg warn';
    try {
      const r = await fetch('speedtest/blob?bytes=' + (64 * 1048576) + '&n=' + Date.now(), { cache: 'no-store' });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      const reader = r.body.getReader();
      let got = 0, t0 = null;
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        if (t0 === null) t0 = performance.now();   // from the first byte: leaves out the request latency
        got += value.length;
      }
      const ms = performance.now() - t0;
      const p = await fetch('speedtest/result?bytes=' + got + '&ms=' + ms.toFixed(1), { method: 'POST', headers: { 'X-Quest-Control': '1' } });
      const j = await p.json().catch(() => ({}));
      if (!p.ok) throw new Error(j.error || ('HTTP ' + p.status));
      m.textContent = 'Measured ' + Number(j.measuredMbps).toFixed(1) + ' Mbps at ' + new Date().toLocaleTimeString() + ': segments now ' + j.recommendedMaxMediaBitrateMbps + ' Mbps.'; m.className = 'msg ok';
      renderQuestLan(j);
    } catch (e) { m.textContent = 'Measurement failed: ' + e.message; m.className = 'msg bad'; }
    qlRunning = false; $('qlMeasure').disabled = !onQuest;
  }
  $('qlMeasure').addEventListener('click', () => { if (!qlRunning) measureQuestLan(); });

  // Enter run progress; returns true while it runs.
  function renderStop(j) {
    const pre = $('plStop'), b = $('plEnter');
    if (!j) { pre.hidden = true; b.disabled = false; return false; }
    const running = j.state === 'running';
    b.disabled = running;
    const mark = { ok: 'ok  ', warn: 'warn', bad: 'FAIL', running: '... ', skip: '--  ' };
    const lines = ['End session ' + (running ? 'running' : j.state) + ' (started ' + j.startedAt + (j.doneAt ? ', done ' + j.doneAt : '') + ')'];
    (j.steps || []).forEach(st => lines.push((mark[st.level] || '    ') + ' ' + st.name + ': ' + st.result));
    pre.textContent = lines.join('\n');
    pre.hidden = false;
    return running;
  }

  // After Enter: on the PC the tab closes itself (one history entry, so the browser allows it). On the
  // Quest the cleanup's history step closes it within seconds: it keeps one tab open, which Quest
  // Browser's History list needs, so closing it from here could leave no tab and block the delete.
  const onQuest = /OculusBrowser|Quest/i.test(navigator.userAgent);
  function closeOwnTab() {
    if (onQuest) { $('plMsg').textContent += ' (closed by the Quest cleanup in a few seconds)'; return; }
    setTimeout(() => {
      window.close();
      setTimeout(() => { $('plMsg').textContent = 'End session started. The browser did not let this tab close itself: close it by hand.'; }, 600);
    }, 1200);
  }

  // What End session would stop right now.
  let partsText = '';
  function renderParts(p) {
    const list = [];
    if (p && p.workflows && p.workflows.length) list.push('3d_playlist_local (' + p.workflows.join(', ') + ')');
    if (p && p.companion) list.push('Loop Segments companion');
    partsText = list.length ? list.join(' + ') : 'nothing running: Quest cleanup only';
    $('plParts').textContent = 'End session stops: ' + partsText;
  }

  $('plEnter').addEventListener('click', async () => {
    const b = $('plEnter'), m = $('plMsg');
    b.disabled = true; m.textContent = 'Starting End session...'; m.className = 'msg warn';
    try {
      const r = await fetch('playlist/enter', { method: 'POST', headers: { 'X-Quest-Control': '1' } });
      const j = await r.json().catch(() => ({}));
      if (r.ok) {
        m.textContent = 'End session started at ' + new Date().toLocaleTimeString() + '. This tab closes now.'; m.className = 'msg ok';
        closeOwnTab();
      }
      else { m.textContent = 'Not started: ' + (j.error || ('HTTP ' + r.status)) + '.'; m.className = 'msg bad'; b.disabled = false; }
    } catch (e) { m.textContent = 'Request failed: ' + e.message; m.className = 'msg bad'; b.disabled = false; }
    schedule(800);
  });

  $('plSpace').addEventListener('click', async () => {
    const b = $('plSpace'), m = $('plMsg');
    b.disabled = true; m.textContent = 'Pressing Space...'; m.className = 'msg warn';
    try {
      const r = await fetch('playlist/space', { method: 'POST', headers: { 'X-Quest-Control': '1' } });
      const j = await r.json().catch(() => ({}));
      const t = new Date().toLocaleTimeString();
      if (r.ok && j.ok) {
        const who = (j.consoles || []).filter(c => c.ok).map(c => c.script + ' (pid ' + c.pid + ')').join(', ');
        m.textContent = 'Space sent at ' + t + ' to ' + who + '.'; m.className = 'msg ok';
      } else { m.textContent = 'Not sent at ' + t + ': ' + (j.error || ('HTTP ' + r.status)) + '.'; m.className = 'msg bad'; }
    } catch (e) { m.textContent = 'Request failed: ' + e.message; m.className = 'msg bad'; }
    b.disabled = false;
  });

  async function refresh() {
    try {
      const r = await fetch('status.json', { cache: 'no-store' });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      render(await r.json());
    } catch (e) {
      setMsg('PC not reachable (' + e.message + '). This page stops when the companion or the 3d_playlist_local workflow quits.', 'bad');
      buttons.forEach(b => b.disabled = true);
      $('bwMeasure').disabled = true;
      schedule(5000);
    }
  }

  function schedule(ms) { clearTimeout(timer); timer = setTimeout(refresh, ms); }

  buttons.forEach(b => b.addEventListener('click', async () => {
    const name = b.dataset.action;
    if (name === 'clear' && !confirm('Remove the Loop Segments WebDAV server from SKYBOX?')) return;
    buttons.forEach(x => x.disabled = true);
    setMsg(name[0].toUpperCase() + name.slice(1) + ' starting...', 'warn');
    try {
      const r = await fetch('skybox/' + name, { method: 'POST', headers: { 'X-Quest-Control': '1' } });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) setMsg(j.error || ('HTTP ' + r.status), 'bad');
    } catch (e) { setMsg('Request failed: ' + e.message, 'bad'); }
    schedule(800);
  }));

  refresh();
})();
</script>
</body>
</html>
'@

# ---- Main loop ----

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
try {
    $listener.Start()
} catch {
    Write-ControlLog "START_FAILED port $Port : $($_.Exception.Message)"
    exit 1
}
try { Set-Content -LiteralPath $script:StatePath -Value (@{ port = $Port; pid = $PID } | ConvertTo-Json -Compress) -Encoding utf8 } catch {}
Write-ControlLog "LISTENING 0.0.0.0:$Port (companion pid $CompanionPid)"

# One request on a connection that has data waiting.
function Invoke-ControlClient {
    param([System.Net.Sockets.TcpClient] $Client)
    $client = $Client
    $remote = ([System.Net.IPEndPoint]$client.Client.RemoteEndPoint).Address
    if (-not (Test-ControlClientAllowed -Address $remote)) { Write-ControlLog "REFUSED non-private client $remote"; return }
    $req = Read-ControlRequest -Client $client
    if (-not $req) { return }
    $s = $req.Stream
    if ($req.RequestLine -notmatch '^(\S+)\s+(\S+)') { Write-ControlResponse -Stream $s -StatusCode 400 -Body '{"ok":false}'; return }
    $method = $Matches[1].ToUpperInvariant()
    $target = $Matches[2]
    $path = ($target -split '\?')[0]
    $query = if ($target.Contains('?')) { $target.Substring($target.IndexOf('?') + 1) } else { '' }
    if (-not (Test-ControlHostHeader -HeaderText $req.HeaderText)) {
        Write-ControlResponse -Stream $s -StatusCode 400 -Body '{"ok":false,"error":"use the IP address"}'
        return
    }
    if ($method -eq 'GET' -and $path -eq '/pc') {
        $given = if ($query -match '(?:^|&)t=([A-Za-z0-9]+)') { $Matches[1] } else { '' }
        $tok = Get-ControlPcToken
        if ([System.Net.IPAddress]::IsLoopback($remote) -and (Test-ControlTokenEqual -A $given -B $tok)) {
            Write-ControlResponse -Stream $s -StatusCode 302 -Body '' -ContentType 'text/plain' -ExtraHeaders @('Location: /', "Set-Cookie: qcpc=$tok; Path=/; HttpOnly; SameSite=Strict")
        } else {
            Write-ControlLog "PC_TOKEN_REFUSED from $remote"
            Start-Sleep -Seconds 1
            Write-ControlResponse -Stream $s -StatusCode 403 -Body '{"ok":false,"error":"bad or expired link"}'
        }
        return
    }
    if (-not (Test-ControlPcCookie -HeaderText $req.HeaderText -Remote $remote) -and -not (Test-ControlAuth -HeaderText $req.HeaderText)) {
        if (Get-ControlHeader -HeaderText $req.HeaderText -Name 'Authorization') {
            Write-ControlLog "AUTH_FAILED from $remote"
            Start-Sleep -Seconds 1
        }
        Write-ControlResponse -Stream $s -StatusCode 401 -Body '{"ok":false,"error":"login required"}' -ExtraHeaders @('WWW-Authenticate: Basic realm="Loop Segments Quest control", charset="UTF-8"')
        return
    }
    if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
        Write-ControlResponse -Stream $s -StatusCode 200 -Body $script:PageHtml -ContentType 'text/html; charset=utf-8'
    } elseif ($method -eq 'GET' -and $path -eq '/status.json') {
        Write-ControlResponse -Stream $s -StatusCode 200 -Body (ConvertTo-ControlJson (Get-ControlStatus))
    } elseif ($path -match '^/skybox/(push|update|clear)$') {
        $name = $Matches[1]
        if ($method -ne 'POST') { Write-ControlResponse -Stream $s -StatusCode 405 -Body '{"ok":false,"error":"POST only"}'; return }
        if ((Get-ControlHeader -HeaderText $req.HeaderText -Name 'X-Quest-Control') -ne '1') {
            Write-ControlResponse -Stream $s -StatusCode 403 -Body '{"ok":false,"error":"missing X-Quest-Control header"}'
            return
        }
        if (-not [bool](Get-ControlSettings).questSkyboxWebDav) {
            Write-ControlResponse -Stream $s -StatusCode 403 -Body '{"ok":false,"error":"SKYBOX buttons are off (questSkyboxWebDav=false)"}'
            return
        }
        if (Start-ControlAction -Name $name) {
            Write-ControlResponse -Stream $s -StatusCode 202 -Body (ConvertTo-ControlJson @{ ok = $true; action = $name; state = 'running' })
        } else {
            Write-ControlResponse -Stream $s -StatusCode 409 -Body '{"ok":false,"error":"another action is still running"}'
        }
    } elseif ($path -eq '/lan/measure') {
        if ($method -ne 'POST') { Write-ControlResponse -Stream $s -StatusCode 405 -Body '{"ok":false,"error":"POST only"}'; return }
        if ((Get-ControlHeader -HeaderText $req.HeaderText -Name 'X-Quest-Control') -ne '1') {
            Write-ControlResponse -Stream $s -StatusCode 403 -Body '{"ok":false,"error":"missing X-Quest-Control header"}'
            return
        }
        if (Start-ControlLanBw) {
            Write-ControlResponse -Stream $s -StatusCode 202 -Body '{"ok":true,"action":"lan-measure","state":"running"}'
        } else {
            Write-ControlResponse -Stream $s -StatusCode 409 -Body '{"ok":false,"error":"a measurement is already running"}'
        }
    } elseif ($path -eq '/playlist/space') {
        if ($method -ne 'POST') { Write-ControlResponse -Stream $s -StatusCode 405 -Body '{"ok":false,"error":"POST only"}'; return }
        if ((Get-ControlHeader -HeaderText $req.HeaderText -Name 'X-Quest-Control') -ne '1') {
            Write-ControlResponse -Stream $s -StatusCode 403 -Body '{"ok":false,"error":"missing X-Quest-Control header"}'
            return
        }
        $r = Invoke-ControlPlaylistSpace
        Write-ControlResponse -Stream $s -StatusCode $(if ($r.ok) { 200 } else { 409 }) -Body (ConvertTo-ControlJson $r)
    } elseif ($method -eq 'GET' -and $path -eq '/speedtest/blob') {
        $n = [long](64MB)
        if ($query -match '(?:^|&)bytes=(\d+)') { $n = [long]$Matches[1] }
        $n = [Math]::Max([long]1MB, [Math]::Min([long]128MB, $n))
        Write-ControlLog ("QUEST_LAN_BLOB {0} bytes to {1}" -f $n, $remote)
        Write-ControlBlob -Stream $s -Bytes $n
    } elseif ($path -eq '/speedtest/result') {
        if ($method -ne 'POST') { Write-ControlResponse -Stream $s -StatusCode 405 -Body '{"ok":false,"error":"POST only"}'; return }
        if ((Get-ControlHeader -HeaderText $req.HeaderText -Name 'X-Quest-Control') -ne '1') {
            Write-ControlResponse -Stream $s -StatusCode 403 -Body '{"ok":false,"error":"missing X-Quest-Control header"}'
            return
        }
        # PC -> PC (loopback) says nothing about the headset's link.
        if ([System.Net.IPAddress]::IsLoopback($remote)) {
            Write-ControlResponse -Stream $s -StatusCode 409 -Body '{"ok":false,"error":"run the test from the headset"}'
            return
        }
        $b = 0L; $ms = 0.0
        if ($query -match '(?:^|&)bytes=(\d+)') { $b = [long]$Matches[1] }
        if ($query -match '(?:^|&)ms=(\d+(?:\.\d+)?)') { $ms = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) }
        if ($b -lt 1MB -or $b -gt 128MB -or $ms -lt 20 -or $ms -gt 600000) {
            Write-ControlResponse -Stream $s -StatusCode 400 -Body '{"ok":false,"error":"bad measurement"}'
            return
        }
        $o = Save-ControlQuestLanResult -Bytes $b -Ms $ms -Client ([string]$remote)
        Write-ControlResponse -Stream $s -StatusCode 200 -Body (ConvertTo-ControlJson $o)
    } elseif ($path -eq '/playlist/enter') {
        if ($method -ne 'POST') { Write-ControlResponse -Stream $s -StatusCode 405 -Body '{"ok":false,"error":"POST only"}'; return }
        if ((Get-ControlHeader -HeaderText $req.HeaderText -Name 'X-Quest-Control') -ne '1') {
            Write-ControlResponse -Stream $s -StatusCode 403 -Body '{"ok":false,"error":"missing X-Quest-Control header"}'
            return
        }
        $st = Start-ControlPlaylistShutdown
        if ($st -eq 'started') {
            Write-ControlResponse -Stream $s -StatusCode 202 -Body '{"ok":true,"action":"playlist-enter","state":"running"}'
        } elseif ($st -eq 'missing') {
            Write-ControlResponse -Stream $s -StatusCode 409 -Body '{"ok":false,"error":"3d_playlist_local Invoke-PlaylistLocalQuestShutdown.ps1 not found"}'
        } else {
            Write-ControlResponse -Stream $s -StatusCode 409 -Body '{"ok":false,"error":"End session is already running"}'
        }
    } elseif ($method -eq 'OPTIONS') {
        # No CORS: cross-origin preflights fail, so other sites cannot send the action header.
        Write-ControlResponse -Stream $s -StatusCode 405 -Body '{"ok":false}'
    } else {
        Write-ControlResponse -Stream $s -StatusCode 404 -Body '{"ok":false,"error":"not found"}'
    }
}

# Browsers open spare connections that may never send a request (Quest Browser does). Reading one
# would block every other request, so accepted connections wait in $pending and are handled only
# once data has arrived; ones still silent after 10 s are closed.
$pending = [System.Collections.Generic.List[object]]::new()
$lastParentCheck = [DateTime]::UtcNow
try {
    while ($true) {
        if ($CompanionPid -gt 0 -and ([DateTime]::UtcNow - $lastParentCheck).TotalSeconds -ge 2) {
            $lastParentCheck = [DateTime]::UtcNow
            if (-not (Get-Process -Id $CompanionPid -ErrorAction SilentlyContinue)) { Write-ControlLog 'Companion gone - stopping.'; break }
        }
        while ($listener.Pending()) {
            $c = $listener.AcceptTcpClient()
            $remote = ([System.Net.IPEndPoint]$c.Client.RemoteEndPoint).Address
            if (-not (Test-ControlClientAllowed -Address $remote)) {
                Write-ControlLog "REFUSED non-private client $remote"
                try { $c.Close() } catch {}
                continue
            }
            $pending.Add([pscustomobject]@{ Client = $c; Since = [DateTime]::UtcNow })
        }
        $ready = @($pending | Where-Object { try { $_.Client.Available -gt 0 } catch { $false } })
        $stale = @($pending | Where-Object { ([DateTime]::UtcNow - $_.Since).TotalSeconds -ge 10 -and $ready -notcontains $_ })
        foreach ($p in $stale) { [void]$pending.Remove($p); try { $p.Client.Close() } catch {} }
        if ($ready.Count -eq 0) { Start-Sleep -Milliseconds 50; continue }
        foreach ($p in $ready) {
            [void]$pending.Remove($p)
            try {
                Invoke-ControlClient -Client $p.Client
            } catch {
                Write-ControlLog "REQUEST_ERROR $($_.Exception.Message)"
            } finally {
                try { $p.Client.Close() } catch {}
            }
        }
    }
} finally {
    foreach ($p in $pending) { try { $p.Client.Close() } catch {} }
    try { $listener.Stop() } catch {}
    Remove-Item -LiteralPath $script:StatePath -Force -ErrorAction SilentlyContinue
}
