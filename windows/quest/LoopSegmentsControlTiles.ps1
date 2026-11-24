# Loop Segments tiles on the shared Quest control page (quest_tools QuestControlHost.ps1).
# Registered by the PC companion at startup (QuestCompanionHooks.ps1 Start-QuestControlPageInBackground,
# through quest_tools Register-QuestControlTiles.ps1 -Owner loopsegments) for as long as it runs.
# The host dot-sources this file once and keeps the returned hashtable; everything here is prefixed
# LsTiles so it cannot clash with the host or another project's tiles.
#
#   SKYBOX: phone as a WebDAV server  Push / Update / Clear: Watch-LoopSegmentsQuestLanTab.ps1
#                                     -SkyboxPush / -SkyboxUpdate / -ClearSkyboxWebDav in the background
#   LAN bandwidth: PC <-> phone       Measure LAN: lan\Measure-LoopSegmentsLanThroughput.ps1 (HTTP, plus
#                                     the rclone mount when it is up; never reboots routers); result in
#                                     %TEMP%\loopsegments-lan-throughput.json (the companion's startup probe writes it too)
#   Recent SKYBOX log
#   Login: the phone LAN login (webdavUser + that phone's webdavPassword) also signs in to the page
#   (HTTP Basic), as Open on Quest types it.
#
# Settings (windows\loop-segments-windows.json): questSkyboxWebDav (SKYBOX buttons).

$script:LsTilesQuestDir = $PSScriptRoot
$script:LsTilesWindowsDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:LsTilesWindowsDir 'lib\LoopSegments-Windows.ps1')
$script:LsTilesWatchScript = Join-Path $PSScriptRoot 'Watch-LoopSegmentsQuestLanTab.ps1'
# The extension's lan_config.json: the phone address the companion found (re-read on every request).
$script:LsTilesLanConfig = Join-Path $script:LsTilesWindowsDir 'pcloud_web_companion\lan_config.json'
$script:LsTilesQuestLog = Join-Path $env:TEMP 'loopsegments-quest-lantab.log'
$script:LsTilesSkyboxStatePath = Join-Path $env:TEMP 'loopsegments-skybox-webdav.json'
$script:LsTilesLanBwScript = Join-Path $script:LsTilesWindowsDir 'lan\Measure-LoopSegmentsLanThroughput.ps1'
$script:LsTilesLanBwResultPath = Join-Path $env:TEMP 'loopsegments-lan-throughput.json'
$script:LsTilesLanBwLog = Join-Path $env:TEMP 'loopsegments-quest-control-lanbw.log'
$script:LsTilesAction = $null
$script:LsTilesLanBw = $null

function Get-LsTilesLanUrl {
    if (-not (Test-Path -LiteralPath $script:LsTilesLanConfig)) { return $null }
    try {
        $c = Get-Content -LiteralPath $script:LsTilesLanConfig -Raw | ConvertFrom-Json
        $h = ([string]$c.phoneLanHost).Trim()
        if ([string]::IsNullOrWhiteSpace($h)) { return $null }
        $pt = 8765
        if ($null -ne $c.lanPort -and [int]$c.lanPort -gt 0) { $pt = [int]$c.lanPort }
        return "http://${h}:${pt}/"
    } catch { return $null }
}

# webdavUser + the matching phoneLanHosts[].webdavPassword, else webdavPassword. Never logged.
function Get-LsTilesLogin {
    $cred = Get-LoopSegmentsWebDAVCredentials
    $pass = [string]$cred.Password
    $lan = Get-LsTilesLanUrl
    if ($lan) {
        $hostName = ([Uri]$lan).Host
        foreach ($raw in @((Get-LoopSegmentsWindowsSettings).phoneLanHosts)) {
            if ($null -eq $raw) { continue }
            $e = ConvertTo-LoopSegmentsPhoneHostEntry -Raw $raw
            if ($e -and $e.Host -eq $hostName -and -not [string]::IsNullOrWhiteSpace([string]$e.Password)) { $pass = [string]$e.Password }
        }
    }
    return [pscustomobject]@{ User = [string]$cred.User; Password = $pass }
}

# ---- SKYBOX actions (one at a time) ----

function Get-LsTilesActionStatus {
    $a = $script:LsTilesAction
    if (-not $a) { return [ordered]@{ name = ''; state = 'idle' } }
    $state = if ($a.Proc.HasExited) { 'done' } else { 'running' }
    $result = ''
    if (Test-Path -LiteralPath $a.StatusFile) { try { $result = (Get-Content -LiteralPath $a.StatusFile -Raw).Trim() } catch {} }
    $out = [ordered]@{ name = $a.Name; state = $state; result = $result; startedAt = $a.StartedAt.ToString('HH:mm:ss') }
    if ($state -eq 'done') { $out.exitCode = $a.Proc.ExitCode }
    return $out
}

function Start-LsTilesAction {
    param([ValidateSet('push', 'update', 'clear')] [string] $Name)
    if ($script:LsTilesAction -and -not $script:LsTilesAction.Proc.HasExited) { return $false }
    $switch = @{ push = '-SkyboxPush'; update = '-SkyboxUpdate'; clear = '-ClearSkyboxWebDav' }[$Name]
    $statusFile = Join-Path $env:TEMP 'loopsegments-quest-control-action.txt'
    Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Process -Id $PID).Path
    foreach ($a in @('-NoProfile', '-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:LsTilesWatchScript,
            $switch, '-LanConfig', $script:LsTilesLanConfig, '-StatusFile', $statusFile)) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $script:LsTilesAction = [pscustomobject]@{ Name = $Name; Proc = $proc; StatusFile = $statusFile; StartedAt = (Get-Date) }
    Write-QuestControlLog "SKYBOX_ACTION_START $Name (pid $($proc.Id))"
    return $true
}

function Invoke-LsTilesSkyboxRoute {
    param([string] $Name)
    if (-not [bool](Get-LoopSegmentsWindowsSettings).questSkyboxWebDav) {
        return @{ Code = 403; Body = @{ ok = $false; error = 'SKYBOX buttons are off (questSkyboxWebDav=false)' } }
    }
    if (Start-LsTilesAction -Name $Name) { return @{ Code = 202; Body = @{ ok = $true; action = $Name; state = 'running' } } }
    return @{ Code = 409; Body = @{ ok = $false; error = 'another action is still running' } }
}

# ---- LAN bandwidth (PC <-> phone): the same probe the companion runs at startup ----

# HTTP + rclone mount when the mount drive is up, else HTTP only. Never reboots routers from a
# page click (-SkipLowThroughputGatewayReboot); only the companion's startup probe does that.
function Start-LsTilesLanBw {
    if ($script:LsTilesLanBw -and -not $script:LsTilesLanBw.Proc.HasExited) { return $false }
    $letter = Get-LoopSegmentsMountDriveLetter
    $mountUp = [bool](Test-Path -LiteralPath "${letter}:\" -ErrorAction SilentlyContinue)
    $q = { param($s) "'" + ([string]$s -replace "'", "''") + "'" }
    $cmd = "& $(& $q $script:LsTilesLanBwScript) -NoWaitEnter -SkipLowThroughputGatewayReboot -DriveLetter $letter " +
           $(if ($mountUp) { '-WaitMountSec 15' } else { '-WaitMountSec 0 -HttpOnly' }) +
           " -ResultFile $(& $q $script:LsTilesLanBwResultPath) *>&1 | ForEach-Object { Add-Content -LiteralPath $(& $q $script:LsTilesLanBwLog) -Value (`"`$_`") -Encoding utf8 }; exit `$LASTEXITCODE"
    Remove-Item -LiteralPath $script:LsTilesLanBwLog -Force -ErrorAction SilentlyContinue
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Process -Id $PID).Path
    foreach ($a in @('-NoProfile', '-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $script:LsTilesLanBw = [pscustomobject]@{ Proc = $proc; StartedAt = (Get-Date); Mount = $mountUp }
    Write-QuestControlLog "LAN_MEASURE_START (pid $($proc.Id), mount $(if ($mountUp) { 'up' } else { 'down: HTTP only' }))"
    return $true
}

function Get-LsTilesLanBwStatus {
    $out = [ordered]@{ state = 'idle'; result = $null; lines = @() }
    $a = $script:LsTilesLanBw
    if ($a) {
        $out.state = if ($a.Proc.HasExited) { 'done' } else { 'running' }
        $out.startedAt = $a.StartedAt.ToString('HH:mm:ss')
        $out.mount = $a.Mount
        if ($a.Proc.HasExited) { $out.exitCode = $a.Proc.ExitCode }
        if (Test-Path -LiteralPath $script:LsTilesLanBwLog) {
            try { $out.lines = @(Get-Content -LiteralPath $script:LsTilesLanBwLog -Tail 60 | Where-Object { $_.Trim() } | Select-Object -Last 12) } catch {}
        }
    }
    if (Test-Path -LiteralPath $script:LsTilesLanBwResultPath) {
        try { $out.result = Get-Content -LiteralPath $script:LsTilesLanBwResultPath -Raw | ConvertFrom-Json } catch {}
    }
    return $out
}

# ---- End session (companion-only sessions) ----
# 3d_playlist_local's Session Control tile has the same button while one of its workflows runs; this
# one is for a session with only the companion (the page hides it while that tile is there). Both run
# 3d_playlist_local's Invoke-PlaylistLocalQuestShutdown.ps1, which closes the companion's Chromium so
# its normal quit cleans up the Quest (and does the Quest cleanup itself if the companion did not).

$script:LsTilesShutdownStatePath = Join-Path $env:TEMP 'loopsegments-playlist-shutdown.json'
$script:LsTilesPlaylistSessionPath = Join-Path $env:TEMP 'loopsegments-playlist-session.json'

# A running workflow's registered copy, else 3d_playlist_local next to 'iOS apps'
# ($env:PLAYLIST_LOCAL_REPO overrides that).
function Get-LsTilesShutdownScript {
    try {
        $list = @((Get-Content -LiteralPath $script:LsTilesPlaylistSessionPath -Raw -ErrorAction Stop | ConvertFrom-Json).sessions)
        [array]::Reverse($list)
        foreach ($e in $list) {
            if (-not $e -or -not $e.PSObject.Properties['shutdownScript']) { continue }
            if (-not (Get-Process -Id ([int]$e.pid) -ErrorAction SilentlyContinue)) { continue }
            if (Test-Path -LiteralPath ([string]$e.shutdownScript) -PathType Leaf) { return [string]$e.shutdownScript }
        }
    } catch {}
    $repo = $env:PLAYLIST_LOCAL_REPO
    if ([string]::IsNullOrWhiteSpace($repo)) {
        $repo = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $script:LsTilesWindowsDir))) '3d_playlist_local'
    }
    $p = Join-Path $repo 'individual_transcode\quest\Invoke-PlaylistLocalQuestShutdown.ps1'
    if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    return $null
}

function Get-LsTilesEndStatus {
    if (-not (Test-Path -LiteralPath $script:LsTilesShutdownStatePath)) { return $null }
    try { $j = Get-Content -LiteralPath $script:LsTilesShutdownStatePath -Raw | ConvertFrom-Json } catch { return $null }
    if ($j.state -eq 'running' -and -not (Get-Process -Id ([int]$j.pid) -ErrorAction SilentlyContinue)) { $j.state = 'stopped' }
    return $j
}

# Detached through WMI (its parent is not the host): the companion quits during the run, the host
# stops with it, and the run goes on. Without 3d_playlist_local: close the companion's Chromium
# gracefully (taskkill without /F), so its normal quit runs the Quest cleanup.
function Start-LsTilesEndSession {
    $cur = Get-LsTilesEndStatus
    if ($cur -and $cur.state -eq 'running') { return 'running' }
    $exe = (Get-Process -Id $PID).Path
    $shutdown = Get-LsTilesShutdownScript
    if ($shutdown) {
        $cmd = '"{0}" -NoProfile -NoLogo -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}"' -f $exe, $shutdown
    } else {
        $chrome = @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $c = [string]$_.CommandLine; $c -notlike '*--type=*' -and $c -match '(?i)pcloud_web_companion[\\/]+chromium-profile' })
        if ($chrome.Count -eq 0) { Write-QuestControlLog 'LS_END no shutdown script and no companion Chromium'; return 'nothing' }
        $cmd = 'taskkill.exe ' + (($chrome | ForEach-Object { '/PID ' + $_.ProcessId }) -join ' ')
    }
    $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; ProcessStartupInformation = $startup }
    if ($r.ReturnValue -ne 0) { Write-QuestControlLog "LS_END Win32_Process.Create failed ($($r.ReturnValue))"; return 'failed' }
    if ($shutdown) {
        try { @{ pid = [int]$r.ProcessId; state = 'running'; startedAt = (Get-Date -Format 'HH:mm:ss'); steps = @() } | ConvertTo-Json -Compress | Set-Content -LiteralPath $script:LsTilesShutdownStatePath -Encoding utf8 } catch {}
    }
    Write-QuestControlLog "LS_END started (pid $($r.ProcessId)): $cmd"
    return $(if ($shutdown) { 'started' } else { 'companion' })
}

function Get-LsTilesStatus {
    $s = Get-LoopSegmentsWindowsSettings
    $lan = Get-LsTilesLanUrl
    $added = @()
    if (Test-Path -LiteralPath $script:LsTilesSkyboxStatePath) {
        try { $added = @((Get-Content -LiteralPath $script:LsTilesSkyboxStatePath -Raw | ConvertFrom-Json).urls | Where-Object { $_ }) } catch {}
    }
    $log = @()
    if (Test-Path -LiteralPath $script:LsTilesQuestLog) {
        try { $log = @(Get-Content -LiteralPath $script:LsTilesQuestLog -Tail 400 | Where-Object { $_ -match ' SKYBOX:' } | Select-Object -Last 8) } catch {}
    }
    $login = Get-LsTilesLogin
    return [ordered]@{
        skyboxEnabled = [bool]$s.questSkyboxWebDav
        phoneLanUrl   = $lan
        skyboxUrl     = $(if ($lan) { 'webdav://{0}:{1}/' -f ([Uri]$lan).Host, ([Uri]$lan).Port } else { $null })
        user          = $login.User
        hasPassword   = -not [string]::IsNullOrEmpty($login.Password)
        addedByThisPc = $added
        action        = (Get-LsTilesActionStatus)
        log           = $log
        lanBw         = (Get-LsTilesLanBwStatus)
        endSession    = (Get-LsTilesEndStatus)
        endScript     = [bool](Get-LsTilesShutdownScript)
    }
}

$script:LsTilesSkyboxHtml = @'
    <section>
      <h2>SKYBOX: phone as a WebDAV server</h2>
      <dl>
        <dt>Phone LAN page</dt><dd id="lsLan">-</dd>
        <dt>SKYBOX server</dt><dd id="lsDav">-</dd>
        <dt>Login</dt><dd id="lsUser">-</dd>
        <dt>Added by this PC</dt><dd id="lsAdded">-</dd>
      </dl>
      <div class="buttons">
        <button class="primary" data-ls-action="push">Push</button>
        <button data-ls-action="update">Update</button>
        <button class="danger" data-ls-action="clear">Clear</button>
      </div>
      <div id="lsMsg" class="msg" role="status" aria-live="polite"></div>
      <p class="note">Push adds "Loop Segments" to SKYBOX's Network list at the phone's current address with the current login (and removes older addresses). Update does the same only if it is already there. Clear removes it. SKYBOX restarts if it is open when the server changes; it is also removed when the companion quits.</p>
    </section>
'@

$script:LsTilesLanHtml = @'
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
      <pre id="bwLines" class="scroll" hidden></pre>
      <p class="note">Runs the same probe as the companion at startup (lan\Measure-LoopSegmentsLanThroughput.ps1): downloads up to 64 MB of a phone video over HTTP, and copies it from the rclone mount when the mount is up, then uses the lower number. It never reboots routers from here. Takes about 10-60 s; pause a Virtual Desktop session first or the number comes out low.</p>
    </section>
'@

$script:LsTilesEndHtml = @'
    <section id="lsEndTile">
      <h2>Session</h2>
      <div class="buttons">
        <button id="lsEnd" class="danger">End session: stop all</button>
      </div>
      <div id="lsEndMsg" class="msg" role="status" aria-live="polite"></div>
      <pre id="lsEndSteps" hidden></pre>
      <p class="note">Closes the Loop Segments PC companion's Chromium, so its normal quit runs: Quest tabs, history, SKYBOX, sensor, Wi-Fi off, the phone mount, iPhone Home. Run through 3d_playlist_local's End session when that repo is on this PC, which also does the Quest cleanup itself if the companion's quit did not. While a 3d_playlist_local workflow runs, its Session Control tile has this button instead.</p>
    </section>
'@

$script:LsTilesLogHtml = @'
    <section>
      <h2>Recent SKYBOX log</h2>
      <pre id="lsLog" class="scroll">-</pre>
    </section>
'@

$script:LsTilesScript = @'
  const { $, mbps } = QC;
  const buttons = [...document.querySelectorAll('button[data-ls-action]')];
  const verbs = { added: 'added', updated: 'updated', unchanged: 'already up to date', removed: 'removed', absent: 'not there', failed: 'failed', 'not installed': 'SKYBOX is not installed', unreachable: 'headset not on adb' };
  let lastShown = '';
  function setMsg(text, cls) { const m = $('lsMsg'); m.textContent = text; m.className = 'msg ' + (cls || ''); }

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

  // End session progress (3d_playlist_local's shutdown file); returns true while it runs.
  function renderEnd(j) {
    const pre = $('lsEndSteps');
    if (!j) { pre.hidden = true; return false; }
    const running = j.state === 'running';
    const mark = { ok: 'ok  ', warn: 'warn', bad: 'FAIL', running: '... ', skip: '--  ' };
    const lines = ['End session ' + (running ? 'running' : j.state) + ' (started ' + j.startedAt + (j.doneAt ? ', done ' + j.doneAt : '') + ')'];
    (j.steps || []).forEach(st => lines.push((mark[st.level] || '    ') + ' ' + st.name + ': ' + st.result));
    pre.textContent = lines.join('\n');
    pre.hidden = false;
    return running;
  }

  QC.register('loopsegments', (s, all) => {
    if (!s) return;
    // 3d_playlist_local's Session Control tile has its own End session: show only one.
    $('lsEndTile').hidden = !!(all && (all.ownerNames || []).includes('playlist'));
    const endRunning = renderEnd(s.endSession);
    if (!$('lsEnd').dataset.busy) $('lsEnd').disabled = endRunning;
    $('lsLan').textContent = s.phoneLanUrl || 'unknown (no lan_config.json)';
    $('lsDav').textContent = s.skyboxUrl || '-';
    $('lsUser').textContent = s.user + (s.hasPassword ? '' : ' (no password set on the PC)');
    $('lsAdded').textContent = (s.addedByThisPc && s.addedByThisPc.length) ? s.addedByThisPc.join('\n') : 'none';
    $('lsLog').textContent = (s.log && s.log.length) ? s.log.join('\n') : 'nothing yet';
    const a = s.action || {};
    const running = a.state === 'running';
    const usable = s.skyboxEnabled && s.hasPassword && !!s.phoneLanUrl;
    buttons.forEach(b => b.disabled = running || !usable);
    if (!s.skyboxEnabled) setMsg('SKYBOX buttons are off (questSkyboxWebDav=false on the PC).', 'warn');
    else if (running) setMsg(a.name[0].toUpperCase() + a.name.slice(1) + ' running (started ' + a.startedAt + ')...', 'warn');
    else if (a.state === 'done') {
      const key = a.name + a.startedAt;
      const word = verbs[a.result] || (a.exitCode === 0 ? 'done' : 'failed');
      const ok = a.exitCode === 0 && a.result !== 'failed';
      const text = a.name[0].toUpperCase() + a.name.slice(1) + ' at ' + a.startedAt + ': ' + word + '.';
      if (key !== lastShown || $('lsMsg').textContent === '') { setMsg(text, ok ? 'ok' : 'bad'); lastShown = key; }
    }
    const bwRunning = renderBw(s.lanBw || {});
    return (running || bwRunning || endRunning) ? 1500 : 10000;
  });

  $('lsEnd').addEventListener('click', async () => {
    if (!confirm('End the session? This closes the Loop Segments PC companion and cleans up the Quest.')) return;
    const b = $('lsEnd'), m = $('lsEndMsg');
    b.disabled = true; b.dataset.busy = '1'; m.textContent = 'Starting End session...'; m.className = 'msg warn';
    const r = await QC.post('ls/end-session');
    if (r.ok) {
      m.textContent = 'End session started at ' + new Date().toLocaleTimeString() + '.' +
        (r.json.via === 'companion' ? ' Closing the companion (3d_playlist_local not found: its quit does the cleanup).' : '') +
        (QC.onQuest ? ' This tab is closed by the Quest cleanup in a few seconds.' : ' This page stops with the companion: close the tab.');
      m.className = 'msg ok';
    } else { m.textContent = 'Not started: ' + (r.json.error || ('HTTP ' + r.status)) + '.'; m.className = 'msg bad'; b.disabled = false; delete b.dataset.busy; }
    QC.schedule(800);
  });

  $('bwMeasure').addEventListener('click', async () => {
    $('bwMeasure').disabled = true;
    const m = $('bwMsg'); m.textContent = 'Starting...'; m.className = 'msg warn';
    const r = await QC.post('lan/measure');
    if (!r.ok) { m.textContent = r.json.error || ('HTTP ' + r.status); m.className = 'msg bad'; }
    QC.schedule(800);
  });

  buttons.forEach(b => b.addEventListener('click', async () => {
    const name = b.dataset.lsAction;
    if (name === 'clear' && !confirm('Remove the Loop Segments WebDAV server from SKYBOX?')) return;
    buttons.forEach(x => x.disabled = true);
    setMsg(name[0].toUpperCase() + name.slice(1) + ' starting...', 'warn');
    const r = await QC.post('skybox/' + name);
    if (!r.ok) setMsg(r.json.error || ('HTTP ' + r.status), 'bad');
    QC.schedule(800);
  }));
'@

@{
    Label  = 'Loop Segments PC companion'
    Tiles  = @(
        @{ Column = 0; Order = 10; Html = $script:LsTilesSkyboxHtml }
        @{ Column = 0; Order = 30; Html = $script:LsTilesEndHtml }
        @{ Column = 1; Order = 20; Html = $script:LsTilesLanHtml }
        @{ Column = 'wide'; Order = 10; Html = $script:LsTilesLogHtml }
    )
    Script = $script:LsTilesScript
    Status = { Get-LsTilesStatus }
    Login  = { Get-LsTilesLogin }
    Routes = @{
        '/skybox/push'   = { param($Ctx) Invoke-LsTilesSkyboxRoute -Name 'push' }
        '/skybox/update' = { param($Ctx) Invoke-LsTilesSkyboxRoute -Name 'update' }
        '/skybox/clear'  = { param($Ctx) Invoke-LsTilesSkyboxRoute -Name 'clear' }
        '/ls/end-session' = {
            param($Ctx)
            switch (Start-LsTilesEndSession) {
                'started'   { @{ Code = 202; Body = @{ ok = $true; action = 'end-session'; via = 'playlist'; state = 'running' } } }
                'companion' { @{ Code = 202; Body = @{ ok = $true; action = 'end-session'; via = 'companion'; state = 'running' } } }
                'running'   { @{ Code = 409; Body = @{ ok = $false; error = 'End session is already running' } } }
                'nothing'   { @{ Code = 409; Body = @{ ok = $false; error = 'no 3d_playlist_local shutdown script and no companion Chromium found' } } }
                default     { @{ Code = 500; Body = @{ ok = $false; error = 'could not start End session' } } }
            }
        }
        '/lan/measure'   = {
            param($Ctx)
            if (Start-LsTilesLanBw) { @{ Code = 202; Body = @{ ok = $true; action = 'lan-measure'; state = 'running' } } }
            else { @{ Code = 409; Body = @{ ok = $false; error = 'a measurement is already running' } } }
        }
    }
}
