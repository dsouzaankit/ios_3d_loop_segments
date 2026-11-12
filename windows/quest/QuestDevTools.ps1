# Quest Browser over its DevTools socket (the one chrome://inspect uses), via adb forward.
# Dot-sourced by Watch-LoopSegmentsQuestLanTab.ps1; needs Invoke-Adb, Write-QuestLog, $BrowserPackage.
# Never logs URLs that carry the LAN login.

$script:QuestCdpPort = 0
$script:QuestCdpSerial = ''

function Open-QuestDevTools {
    param([string] $DeviceSerial)
    Close-QuestDevTools
    $f = Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $DeviceSerial, 'forward', 'tcp:0', 'localabstract:chrome_devtools_remote')
    $port = 0
    if (-not [int]::TryParse(([string]$f.Out).Trim(), [ref]$port) -or $port -le 0) {
        Write-QuestLog "DevTools forward failed: $((([string]$f.Out) + ' ' + ([string]$f.Err)).Trim())"
        return $false
    }
    $script:QuestCdpPort = $port
    $script:QuestCdpSerial = $DeviceSerial
    return $true
}

function Close-QuestDevTools {
    if ($script:QuestCdpPort -gt 0) {
        [void](Invoke-Adb -TimeoutSec 5 -Arguments @('-s', $script:QuestCdpSerial, 'forward', '--remove', "tcp:$($script:QuestCdpPort)"))
    }
    $script:QuestCdpPort = 0
}

# Every DevTools target (pages plus the browser's own UI, which is not type 'page').
function Get-QuestTargets {
    # Invoke-RestMethod emits the JSON array as one object: enumerate it explicitly.
    try {
        return @((Invoke-RestMethod -Uri "http://127.0.0.1:$($script:QuestCdpPort)/json/list" -TimeoutSec 4 -NoProxy) | ForEach-Object { $_ })
    } catch {
        return @()
    }
}

function Get-QuestTabs { @(Get-QuestTargets | Where-Object { $_.type -eq 'page' -and ([string]$_.url) -notlike 'chrome://panel-app-nav/' }) }

function Get-QuestBrowserUi { (Get-QuestTargets | Where-Object { ([string]$_.url) -eq 'chrome://panel-app-nav/' } | Select-Object -First 1) }

function Get-QuestTab { param([string] $Id) (Get-QuestTabs | Where-Object { $_.id -eq $Id } | Select-Object -First 1) }

function Close-QuestTab {
    param([string] $Id)
    try { [void](Invoke-WebRequest -Uri "http://127.0.0.1:$($script:QuestCdpPort)/json/close/$Id" -TimeoutSec 4 -NoProxy) } catch {}
}

function ConvertTo-QuestBareUrl { param([string] $U) (([string]$U) -replace '^(https?://)[^/@]*@', '$1').TrimEnd('/') }

# One CDP call on a tab's websocket; waits for the matching id (events are skipped).
function Invoke-QuestCdp {
    param($Tab, [string] $Method, [hashtable] $Params = @{}, [int] $TimeoutSec = 15)
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    try {
        $wsUrl = ([string]$Tab.webSocketDebuggerUrl) -replace '^ws://[^/]+', "ws://127.0.0.1:$($script:QuestCdpPort)"
        if (-not $ws.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None).Wait($TimeoutSec * 1000)) { throw "connect timeout" }
        $msg = @{ id = 1; method = $Method; params = $Params } | ConvertTo-Json -Compress -Depth 10
        $b = [Text.Encoding]::UTF8.GetBytes($msg)
        [void]$ws.SendAsync([ArraySegment[byte]]::new($b), 'Text', $true, [Threading.CancellationToken]::None).Wait($TimeoutSec * 1000)
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
        $buf = New-Object byte[] 1048576
        $ms = [IO.MemoryStream]::new()
        while ([DateTime]::UtcNow -lt $deadline) {
            $task = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [Threading.CancellationToken]::None)
            $left = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if (-not $task.Wait($left)) { throw "$Method timeout" }
            $ms.Write($buf, 0, $task.Result.Count)
            if (-not $task.Result.EndOfMessage) { continue }
            $j = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json -Depth 30
            $ms.SetLength(0)
            if ($j.PSObject.Properties['id'] -and $j.id -eq 1) {
                if ($j.PSObject.Properties['error']) { throw "$Method error: $($j.error.message)" }
                return $j.result
            }
        }
        throw "$Method timeout"
    } finally {
        try { $ws.Abort() } catch {}
        $ws.Dispose()
    }
}

# Runtime.evaluate (awaits promises); returns the value, throws on a page exception.
function Invoke-QuestEval {
    param($Tab, [string] $Expression, [int] $TimeoutSec = 20)
    $r = Invoke-QuestCdp -Tab $Tab -Method 'Runtime.evaluate' -TimeoutSec $TimeoutSec -Params @{
        expression = $Expression; awaitPromise = $true; returnByValue = $true
    }
    if ($r.PSObject.Properties['exceptionDetails']) {
        throw ("page error: " + [string]$r.exceptionDetails.exception.description)
    }
    return $r.result.value
}

# Open a new normal tab with a VIEW intent and return it (retried: the browser sometimes drops
# the first intent while it is busy).
function New-QuestViewTab {
    param([string] $DeviceSerial, [string] $PlainUrl, [int] $Attempts = 3)
    $want = ConvertTo-QuestBareUrl $PlainUrl
    $before = @(Get-QuestTabs | ForEach-Object { $_.id })
    for ($a = 1; $a -le $Attempts; $a++) {
        $r = Invoke-Adb -TimeoutSec 15 -Arguments @('-s', $DeviceSerial, 'shell', 'am', 'start',
            '-a', 'android.intent.action.VIEW', '-d', ("'" + ($PlainUrl -replace "'", '') + "'"), '-p', $BrowserPackage)
        if ($r.Code -ne 0) { Write-QuestLog "am start failed (code $($r.Code))"; continue }
        for ($i = 0; $i -lt 16; $i++) {
            Start-Sleep -Milliseconds 500
            $t = (Get-QuestTabs | Where-Object { $before -notcontains $_.id -and (ConvertTo-QuestBareUrl $_.url) -eq $want } | Select-Object -First 1)
            if ($t) { return $t }
        }
        Write-QuestLog "VIEW intent attempt $a opened no new tab - retrying."
    }
    return $null
}

function Wait-QuestTabUrl {
    param([string] $Id, [scriptblock] $Match, [int] $TimeoutSec = 10)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        $t = Get-QuestTab -Id $Id
        if ($t -and (& $Match ([string]$t.url))) { return $t }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

# Normal tab, signed in: VIEW intent (plain URL) -> Page.navigate login URL (caches the HTTP
# login) -> Page.navigate plain URL (a page whose URL has user:pass@ cannot fetch()) ->
# drop the tab's back/forward entries. LoginUrl may equal PlainUrl (no login).
function Open-QuestSignedInTab {
    param([string] $DeviceSerial, [string] $PlainUrl, [string] $LoginUrl)
    $tab = New-QuestViewTab -DeviceSerial $DeviceSerial -PlainUrl $PlainUrl
    if (-not $tab) { Write-QuestLog 'Normal tab: VIEW intent never opened a tab.'; return $false }
    if ($LoginUrl -eq $PlainUrl) { return $true }
    $want = ConvertTo-QuestBareUrl $PlainUrl
    [void](Invoke-QuestCdp -Tab $tab -Method 'Page.navigate' -Params @{ url = $LoginUrl })
    $signed = Wait-QuestTabUrl -Id $tab.id -TimeoutSec 10 -Match { param($u) $u -match '^https?://[^/@]*@' -and (ConvertTo-QuestBareUrl $u) -eq $want }
    if (-not $signed) { Write-QuestLog 'Normal tab: signed-in load not seen - reloading without the login anyway.' }
    Start-Sleep -Milliseconds 600
    $tab = Get-QuestTab -Id $tab.id
    if (-not $tab) { Write-QuestLog 'Normal tab closed during sign-in.'; return $false }
    [void](Invoke-QuestCdp -Tab $tab -Method 'Page.navigate' -Params @{ url = $PlainUrl })
    $plainTab = Wait-QuestTabUrl -Id $tab.id -TimeoutSec 10 -Match { param($u) $u -notmatch '^https?://[^/@]*@' -and (ConvertTo-QuestBareUrl $u) -eq $want }
    if (-not $plainTab) {
        Write-QuestLog 'Normal tab: could not reload without the login - page fetches (status_lists.json) will fail.'
        return $true
    }
    # Back must not lead to the URL with the login in it.
    try { [void](Invoke-QuestCdp -Tab $plainTab -Method 'Page.resetNavigationHistory') } catch {}
    return $true
}

# ---- chrome://flags: unsafely-treat-insecure-origin-as-secure -------------------------------

$script:QuestFlagName = 'unsafely-treat-insecure-origin-as-secure'

function Get-QuestFlagsJs {
    param([string] $Action, [string] $Value = '')
    $valueJson = ($Value | ConvertTo-Json -Compress)
    return @"
(async () => {
  const name = '$($script:QuestFlagName)';
  const find = () => { const app = document.querySelector('flags-app'); const sr = app && app.shadowRoot;
    return [...((sr || document).querySelectorAll('flags-experiment'))].find(e => e.id === name); };
  // The experiment's data lives on .data or .feature_ depending on the flags page build.
  const info = e => e && (e.data || e.feature_);
  let el = null; for (let i = 0; i < 40 && !info(el = find()); i++) await new Promise(r => setTimeout(r, 250));
  const f = info(el);
  if (!f) return JSON.stringify({ ok: false, error: 'flag not on chrome://flags' });
  const action = '$Action';
  if (action === 'set') {
    chrome.send('setOriginListFlag', [name, $valueJson]);
    chrome.send('enableExperimentalFeature', [name, 'true']);
    return JSON.stringify({ ok: true });
  }
  if (action === 'restart') { chrome.send('restartBrowser'); return JSON.stringify({ ok: true }); }
  return JSON.stringify({ ok: true, enabled: !!f.enabled, value: f.origin_list_value || '' });
})()
"@
}

# Make sure every origin in -Origins is in the flag and the flag is enabled. Uses its own
# helper tab (closed afterwards). Restarts Quest Browser only when something changed.
# Returns 'ok', 'changed', or 'failed'.
function Sync-QuestInsecureOriginFlag {
    param([string] $DeviceSerial, [string[]] $Origins, [string] $HelperUrl)
    $tab = New-QuestViewTab -DeviceSerial $DeviceSerial -PlainUrl $HelperUrl
    if (-not $tab) { Write-QuestLog 'Flags: could not open a helper tab.'; return 'failed' }
    try {
        [void](Invoke-QuestCdp -Tab $tab -Method 'Page.navigate' -Params @{ url = "chrome://flags/#$($script:QuestFlagName)" })
        $tab = Wait-QuestTabUrl -Id $tab.id -TimeoutSec 8 -Match { param($u) $u -like 'chrome://flags*' }
        if (-not $tab) { Write-QuestLog 'Flags: chrome://flags did not load.'; return 'failed' }
        $cur = Invoke-QuestEval -Tab $tab -Expression (Get-QuestFlagsJs -Action 'read') | ConvertFrom-Json
        if (-not $cur.ok) { Write-QuestLog "Flags: $($cur.error)"; return 'failed' }
        $have = @(([string]$cur.value) -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('/') })
        $missing = @($Origins | ForEach-Object { $_.TrimEnd('/') } | Where-Object { $o = $_; -not ($have | Where-Object { $_ -ieq $o }) } | Select-Object -Unique)
        if ($cur.enabled -and $missing.Count -eq 0) {
            Write-QuestLog "Flags: insecure-origin flag already covers $($Origins -join ', ')."
            return 'ok'
        }
        $newValue = (@($have) + @($missing) | Select-Object -Unique) -join ','
        $set = Invoke-QuestEval -Tab $tab -Expression (Get-QuestFlagsJs -Action 'set' -Value $newValue) | ConvertFrom-Json
        if (-not $set.ok) { Write-QuestLog "Flags: set failed: $($set.error)"; return 'failed' }
        # The flags page keeps showing the old value until the browser restarts, so restart from
        # this helper tab (it goes away with the browser) and confirm afterwards. Quest Browser
        # does not restore open tabs after this restart.
        Write-QuestLog "Flags: setting insecure-origin flag to '$newValue' (was enabled=$($cur.enabled), '$($cur.value)'); restarting Quest Browser."
        try { [void](Invoke-QuestEval -Tab $tab -Expression (Get-QuestFlagsJs -Action 'restart') -TimeoutSec 5) } catch {}
        $tab = $null
        $back = $false
        for ($i = 0; $i -lt 40 -and -not $back; $i++) {
            Start-Sleep -Milliseconds 750
            $back = [bool](Get-QuestBrowserUi)
        }
        if (-not $back) { Write-QuestLog 'Flags: Quest Browser did not come back after the restart.'; return 'failed' }
        Start-Sleep -Seconds 1
        $tab = New-QuestViewTab -DeviceSerial $DeviceSerial -PlainUrl $HelperUrl
        if (-not $tab) { Write-QuestLog 'Flags: restarted, but could not open a helper tab to confirm.'; return 'changed' }
        [void](Invoke-QuestCdp -Tab $tab -Method 'Page.navigate' -Params @{ url = "chrome://flags/#$($script:QuestFlagName)" })
        $tab = Wait-QuestTabUrl -Id $tab.id -TimeoutSec 8 -Match { param($u) $u -like 'chrome://flags*' }
        if (-not $tab) { Write-QuestLog 'Flags: restarted, but chrome://flags did not load to confirm.'; return 'changed' }
        $chk = Invoke-QuestEval -Tab $tab -Expression (Get-QuestFlagsJs -Action 'read') | ConvertFrom-Json
        $absent = @($missing | Where-Object { ([string]$chk.value) -notmatch [regex]::Escape($_) })
        if (-not ($chk.ok -and $chk.enabled -and $absent.Count -eq 0)) {
            Write-QuestLog "Flags: after restart the flag is enabled=$($chk.enabled), '$($chk.value)' - change did not stick."
            return 'failed'
        }
        Write-QuestLog "Flags: confirmed after restart: '$($chk.value)'."
        return 'changed'
    } finally {
        if ($tab) { Close-QuestTab -Id $tab.id }
    }
}

# ---- Clear browsing history (History only, All time) through the browser's own dialog ----

$script:QuestClearHistoryJs = @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const findStore = () => { for (const el of [document.body, ...document.body.children]) { const k = Object.keys(el).find(k => k.startsWith("__reactContainer") || k.startsWith("__reactFiber")); if (!k) continue; let s = [el[k]], n = 0; while (s.length && n++ < 20000) { const f = s.pop(); if (!f) continue; const p = f.memoizedProps; if (p && p.store && p.store.getState) return p.store; if (f.child) s.push(f.child); if (f.sibling) s.push(f.sibling); } } return null; };
  const store = findStore(); if (!store) return JSON.stringify({ ok: false, error: "browser UI store not found" });
  const st = () => store.getState().clearData;
  const close = () => { if (store.getState().modal.modalId === "clear") store.dispatch({ type: "modal/hideModal", payload: "clear" }); };
  const fb = !!(store.getState().facebookLogin || {}).isLoggedIn;
  const prevItems = Object.fromEntries(Object.entries(st().clearItems).map(([k, v]) => [k, v.selected]));
  const prevTime = st().selectedTimeIndex;
  const restore = () => { for (const [id, sel] of Object.entries(prevItems)) store.dispatch({ type: "clearData/setItemSelected", payload: { id, selected: sel } }); store.dispatch({ type: "clearData/setSelectedTimeIndex", payload: { selectedTimeIndex: prevTime, isFBLoggedIn: fb } }); };
  store.dispatch({ type: "modal/showModal", payload: "clear" });
  for (let i = 0; i < 30 && !(st().subtitles || []).length; i++) await sleep(200);
  const subs = st().subtitles || [];
  const allIdx = subs.findIndex(s => s.id === "all");
  if (allIdx < 0) { close(); return JSON.stringify({ ok: false, error: "no 'all time' option", subs: subs.map(s => s.id) }); }
  const before = subs[allIdx].historyCount;
  // History only: never cookies, cache, passwords, forms or settings.
  for (const id of Object.keys(st().clearItems)) store.dispatch({ type: "clearData/setItemSelected", payload: { id, selected: id === "history" } });
  store.dispatch({ type: "clearData/setSelectedTimeIndex", payload: { selectedTimeIndex: allIdx, isFBLoggedIn: fb } });
  await sleep(300);
  const sel = Object.fromEntries(Object.entries(st().clearItems).map(([k, v]) => [k, v.selected]));
  if (!sel.history || Object.entries(sel).some(([k, v]) => k !== "history" && v)) { close(); restore(); return JSON.stringify({ ok: false, error: "selection not history-only" }); }
  const footer = [...document.querySelectorAll("[class*='clear_modal-module__responsive-buttons-footer']")].pop();
  const btn = footer ? [...footer.querySelectorAll("button")].find(b => !b.disabled && (b.textContent || "").trim() && !/done|cancel/i.test(b.textContent)) : null;
  if (!btn) { close(); restore(); return JSON.stringify({ ok: false, error: "Clear data button not found" }); }
  btn.click();
  await sleep(1500);
  close(); restore();
  return JSON.stringify({ ok: true, historyBefore: before });
})()
'@

# Returns 'cleared', 'failed' or 'skipped'.
function Clear-QuestBrowserHistory {
    param([string] $DeviceSerial, [string] $HelperUrl)
    $helper = $null
    $ui = Get-QuestBrowserUi
    if (-not $ui) {
        # Browser not running: open it with a helper tab (that visit is cleared too).
        $helper = New-QuestViewTab -DeviceSerial $DeviceSerial -PlainUrl $HelperUrl
        for ($i = 0; $i -lt 20 -and -not $ui; $i++) { Start-Sleep -Milliseconds 500; $ui = Get-QuestBrowserUi }
    }
    if (-not $ui) {
        if ($helper) { Close-QuestTab -Id $helper.id }
        Write-QuestLog 'History: Quest Browser UI not found - not cleared.'
        return 'failed'
    }
    try {
        if ($helper) { Close-QuestTab -Id $helper.id; Start-Sleep -Milliseconds 500 }
        $r = Invoke-QuestEval -Tab $ui -Expression $script:QuestClearHistoryJs -TimeoutSec 30 | ConvertFrom-Json
        if ($r.ok) { Write-QuestLog 'History: cleared Quest Browser history (all time, history only).'; return 'cleared' }
        Write-QuestLog "History: not cleared - $($r.error)"
        return 'failed'
    } catch {
        Write-QuestLog "History: not cleared - $($_.Exception.Message)"
        return 'failed'
    }
}
