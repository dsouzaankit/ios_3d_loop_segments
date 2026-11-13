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
    if ($Address.IsIPv4MappedToIPv6) { $Address = $Address.MapToIPv4() }
    if ([System.Net.IPAddress]::IsLoopback($Address)) { return $true }
    if ($Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $b = $Address.GetAddressBytes()
    return ($b[0] -eq 10) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 169 -and $b[1] -eq 254)
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
    $h = Get-ControlHeader -HeaderText $HeaderText -Name 'Host'
    if (-not $h) { return $false }
    return ($h -match '^(\d{1,3}(\.\d{1,3}){3}|localhost|\[[0-9a-fA-F:]+\])(:\d+)?$')
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
    $reason = @{ 200 = 'OK'; 202 = 'Accepted'; 400 = 'Bad Request'; 401 = 'Unauthorized'; 403 = 'Forbidden'; 404 = 'Not Found'; 405 = 'Method Not Allowed'; 409 = 'Conflict' }[$StatusCode]
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
  .tiles { display:grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 420px), 1fr)); gap: 16px; align-items: start; }
  .tiles .wide { grid-column: 1 / -1; }
  section { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 18px; min-width: 0; }
  #log { max-height: 7.5em; overflow-y: auto; }
  #msg:empty, .msg:empty { display: none; }
  #bwLines { max-height: 9em; overflow-y: auto; }
  h2 { font-size: 19px; margin: 0 0 12px; }
  dl { display:grid; grid-template-columns: max-content 1fr; gap: 6px 14px; margin: 0 0 16px; font-size: 16px; }
  dt { color: var(--muted); }
  dd { margin: 0; overflow-wrap: anywhere; font-family: ui-monospace, Consolas, monospace; font-size: 15px; }
  .buttons { display:flex; flex-wrap: wrap; gap: 12px; }
  button { font: inherit; font-weight: 600; min-height: 56px; min-width: 140px; padding: 0 22px; border-radius: 10px; border: 1px solid var(--line); background: #252c35; color: var(--text); cursor: pointer; }
  button.primary { background: var(--accent); border-color: var(--accent); color: #0b1320; }
  button.danger { border-color: #6e2b2b; color: #ffb4ae; }
  button:disabled { opacity: .45; cursor: default; }
  .note { color: var(--muted); font-size: 14px; margin: 12px 0 0; }
  #msg, .msg { margin-top: 14px; min-height: 1.4em; font-size: 16px; }
  .ok { color: var(--ok); } .warn { color: var(--warn); } .bad { color: var(--bad); }
  #bwLines { margin-top: 10px; }
  pre { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; font: 13px/1.5 ui-monospace, Consolas, monospace; color: var(--muted); }
</style>
</head>
<body>
<main>
  <header>
    <h1>Quest control</h1>
    <p class="sub">Loop Segments PC companion</p>
  </header>

  <div class="tiles">
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
    schedule((running || bwRunning) ? 1500 : 10000);
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

  async function refresh() {
    try {
      const r = await fetch('status.json', { cache: 'no-store' });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      render(await r.json());
    } catch (e) {
      setMsg('Companion not reachable (' + e.message + '). It stops when the companion quits.', 'bad');
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
    $path = ($Matches[2] -split '\?')[0]
    if (-not (Test-ControlHostHeader -HeaderText $req.HeaderText)) {
        Write-ControlResponse -Stream $s -StatusCode 400 -Body '{"ok":false,"error":"use the IP address"}'
        return
    }
    if (-not (Test-ControlAuth -HeaderText $req.HeaderText)) {
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
