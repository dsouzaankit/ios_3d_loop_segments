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

# Open page tabs on any of -Origins (http://host:port), login in the URL ignored.
function Get-QuestLanTabs {
    param([string[]] $Origins)
    $os = @($Origins | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('/').ToLowerInvariant() })
    if ($os.Count -eq 0) { return @() }
    return @(Get-QuestTabs | Where-Object {
            $b = (ConvertTo-QuestBareUrl $_.url).ToLowerInvariant()
            @($os | Where-Object { $b -eq $_ -or $b.StartsWith("${_}/") -or $b.StartsWith("${_}#") -or $b.StartsWith("${_}?") }).Count -gt 0
        })
}

# Bring Quest Browser to the front (starts it if it is closed) and switch to a tab.
function Show-QuestBrowserTab {
    param([string] $DeviceSerial, [string] $Id)
    [void](Invoke-Adb -TimeoutSec 8 -Arguments @('-s', $DeviceSerial, 'shell', 'monkey', '-p', $BrowserPackage, '-c', 'android.intent.category.LAUNCHER', '1'))
    if ($Id) { try { [void](Invoke-WebRequest -Uri "http://127.0.0.1:$($script:QuestCdpPort)/json/activate/$Id" -TimeoutSec 4 -NoProxy) } catch {} }
}

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
# -Origins: reuse an already open tab on one of these origins (and close the other ones) instead of
# opening a new tab on every click. Sets $script:QuestReusedTab.
function Open-QuestSignedInTab {
    param([string] $DeviceSerial, [string] $PlainUrl, [string] $LoginUrl, [string[]] $Origins = @())
    $want = ConvertTo-QuestBareUrl $PlainUrl
    $script:QuestReusedTab = $false
    $existing = @(Get-QuestLanTabs -Origins $Origins)
    # Tabs Quest Browser restored after it was stopped (force-stop, or closed from the headset) can
    # stay unloaded and not answer DevTools: close those and open a fresh tab instead.
    $dead = @($existing | Where-Object { $t = $_; try { [void](Invoke-QuestEval -Tab $t -Expression '1' -TimeoutSec 5); $false } catch { $true } })
    if ($dead.Count -gt 0) {
        foreach ($t in $dead) { Close-QuestTab -Id $t.id }
        Write-QuestLog "Normal tab: closed $($dead.Count) open tab(s) on $want that did not answer (restored, not loaded) - opening a new one."
        $existing = @($existing | Where-Object { $dead.id -notcontains $_.id })
    }
    if ($existing.Count -gt 0) {
        $tab = ($existing | Where-Object { (ConvertTo-QuestBareUrl $_.url) -eq $want } | Select-Object -First 1)
        if (-not $tab) { $tab = $existing[0] }
        foreach ($t in $existing) { if ($t.id -ne $tab.id) { Close-QuestTab -Id $t.id } }
        if ($existing.Count -gt 1) { Write-QuestLog "Normal tab: closed $($existing.Count - 1) extra LAN tab(s)." }
        Show-QuestBrowserTab -DeviceSerial $DeviceSerial -Id $tab.id
        $script:QuestReusedTab = $true
        if ($LoginUrl -eq $PlainUrl) {
            [void](Invoke-QuestCdp -Tab $tab -Method 'Page.navigate' -Params @{ url = $PlainUrl })
            return $true
        }
    } else {
        $tab = New-QuestViewTab -DeviceSerial $DeviceSerial -PlainUrl $PlainUrl
        if (-not $tab) { Write-QuestLog 'Normal tab: VIEW intent never opened a tab.'; return $false }
        if ($LoginUrl -eq $PlainUrl) { return $true }
    }
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
    # The tab list keeps the requested URL even when loading failed; check the real document.
    if (-not (Test-QuestTabLoaded -Tab $plainTab)) {
        Write-QuestLog 'Normal tab: the phone LAN page did not load (phone app closed or off Wi-Fi?).'
        return $false
    }
    return $true
}

# $false when the tab shows Chromium's error page (server down / unreachable) instead of the page.
function Test-QuestTabLoaded {
    param($Tab, [int] $TimeoutSec = 8)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $s = [string](Invoke-QuestEval -Tab $Tab -TimeoutSec 4 -Expression 'JSON.stringify({ href: location.href, ready: document.readyState })' | ConvertFrom-Json | ForEach-Object { "$($_.ready)|$($_.href)" })
            if ($s -match '\|chrome-error://') { return $false }
            if ($s -match '^complete\|') { return $true }
        } catch {}
        Start-Sleep -Milliseconds 400
    }
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
        if ($tab) { Close-QuestHelperTab -Tab $tab -HelperUrl $HelperUrl }
    }
}

# Close our tabs (on -Origins). Quest Browser's History list only answers while the browser has at
# least one tab open (seen: deleted with one tab open, 'history query never answered' right after
# its last tab was closed), so when our tabs are the only ones the last of them is kept, turned into
# a blank page with no back/forward entries (about:blank is never in history) instead of closed.
# The force-stop that closes a browser Loop Segments started removes it without a Recently closed
# item. Returns the number of tabs closed (the blanked one not counted).
function Close-QuestOurTabs {
    param([string[]] $Origins)
    $ours = @(Get-QuestLanTabs -Origins $Origins)
    if ($ours.Count -eq 0) { return 0 }
    $others = @(Get-QuestTabs | Where-Object { $ours.id -notcontains $_.id })
    $keep = $null
    if ($others.Count -eq 0) {
        $keep = $ours[0]
        try {
            [void](Invoke-QuestCdp -Tab $keep -Method 'Page.navigate' -Params @{ url = 'about:blank' } -TimeoutSec 8)
            $b = Wait-QuestTabUrl -Id $keep.id -TimeoutSec 6 -Match { param($u) $u -eq 'about:blank' }
            if ($b) { $keep = $b }
            try { [void](Invoke-QuestCdp -Tab $keep -Method 'Page.resetNavigationHistory' -TimeoutSec 5) } catch {}
            Write-QuestLog 'Tabs: kept one tab as a blank page (the History list needs an open tab).'
        } catch {
            $keep = $null
        }
    }
    $n = 0
    foreach ($t in $ours) { if (-not $keep -or $t.id -ne $keep.id) { Close-QuestTab -Id $t.id; $n++ } }
    return $n
}

# Close a helper tab without leaving "Experiments" (chrome://flags) in Quest Browser's Recently
# closed list. Every closed tab goes there, and nothing removes an item except deleting its pages
# from history - chrome:// pages are never in history. So the tab first goes back to the phone page
# (a page in history) with its back/forward list reset: the item then holds only that page, and the
# quit-time history delete of the phone origin removes it.
function Close-QuestHelperTab {
    param($Tab, [string] $HelperUrl)
    try {
        if ($HelperUrl -and ([string]$Tab.url) -notlike "$(ConvertTo-QuestBareUrl $HelperUrl)*") {
            [void](Invoke-QuestCdp -Tab $Tab -Method 'Page.navigate' -Params @{ url = $HelperUrl } -TimeoutSec 8)
            $back = Wait-QuestTabUrl -Id $Tab.id -TimeoutSec 6 -Match { param($u) $u -like 'http*' }
            if ($back) { $Tab = $back }
        }
        [void](Invoke-QuestCdp -Tab $Tab -Method 'Page.resetNavigationHistory' -TimeoutSec 5)
    } catch {}
    Close-QuestTab -Id $Tab.id
}

# Recently closed items that are only ours: every tab in them is on one of -Origins, a new-tab page,
# a blank page or chrome://flags. They also show as tiles on the new-tab page, and deleting their pages from
# history does not reliably drop them (seen: items for a deleted page and for chrome:// pages
# lasting for days). Each is reopened, sent to -HelperUrl with its back/forward list reset and
# closed (Close-QuestHelperTab): the new item then holds only the phone page, which the caller's
# next history delete removes. Returns the number cleaned, or -1 if the list could not be read.
$script:QuestClosedCommonJs = @'
  const roots = () => { const r = []; if (!document.body) return r; for (const el of [document.body, ...document.body.children]) { const k = Object.keys(el).find(k => k.startsWith("__reactContainer") || k.startsWith("__reactFiber")); if (k) r.push(el[k]); } return r; };
  const walk = cb => { for (const root of roots()) { let st = [root], n = 0; while (st.length && n++ < 80000) { const f = st.pop(); if (!f) continue; if (cb(f) === false) return; if (f.child) st.push(f.child); if (f.sibling) st.push(f.sibling); } } };
  let store = null; walk(f => { const p = f.memoizedProps; if (p && p.store && p.store.getState) { store = p.store; return false; } });
  let menu = null; walk(f => { const sn = f.stateNode; try { if (sn && sn.props && typeof Object.getPrototypeOf(sn).handleReopenClosedTab === "function") { menu = sn; return false; } } catch (e) {} });
'@

function Invoke-QuestRecentlyClosedSweep {
    param([string[]] $Origins, [string] $HelperUrl, [double] $BudgetSec = 20)
    $t0 = [DateTime]::UtcNow
    $ui = Get-QuestBrowserUi
    if (-not $ui) { return -1 }
    $os = ConvertTo-Json -Compress -InputObject @($Origins | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('/').ToLowerInvariant() })
    $listJs = "(() => {`n$($script:QuestClosedCommonJs)`n  if (!store) return JSON.stringify({ ok: false });`n  const O = new Set($os);`n  const mine = u => { if (u === 'about:blank' || /^chrome:\/\/(flags|panel-app-nav\/ntp)/.test(u)) return true; try { return O.has(new URL(u).origin.toLowerCase()); } catch (e) { return false; } };`n  const ids = (store.getState().history.recentlyClosedTabs || []).filter(e => e.type === 'tab' && e.tabs && e.tabs.length && e.tabs.every(t => mine(String(t.url || '')))).map(e => e.sessionId);`n  return JSON.stringify({ ok: true, menu: !!menu, ids });`n})()"
    try { $l = Invoke-QuestEval -Tab $ui -Expression $listJs -TimeoutSec 8 | ConvertFrom-Json } catch { return -1 }
    if (-not $l.ok) { return -1 }
    $ids = @($l.ids)
    if ($ids.Count -eq 0) { return 0 }
    if (-not $l.menu) { Write-QuestLog "Recently closed: $($ids.Count) Loop Segments item(s), but the reopen handler was not found - left."; return -1 }
    $done = 0
    foreach ($sid in $ids) {
        if (([DateTime]::UtcNow - $t0).TotalSeconds -gt $BudgetSec) { Write-QuestLog 'Recently closed: out of time - the rest is left.'; break }
        $before = @(Get-QuestTabs | ForEach-Object { $_.id })
        try { [void](Invoke-QuestEval -Tab $ui -TimeoutSec 5 -Expression "(() => {`n$($script:QuestClosedCommonJs)`n  Object.getPrototypeOf(menu).handleReopenClosedTab.call(menu, $sid); return 1;`n})()") } catch { continue }
        $new = $null
        for ($i = 0; $i -lt 20 -and -not $new; $i++) { Start-Sleep -Milliseconds 300; $new = @(Get-QuestTabs | Where-Object { $before -notcontains $_.id })[0] }
        if (-not $new) { continue }
        Close-QuestHelperTab -Tab $new -HelperUrl $HelperUrl
        $done++
    }
    Write-QuestLog ("Recently closed: cleaned {0} of {1} Loop Segments / new-tab / blank / chrome://flags item(s)." -f $done, $ids.Count)
    return $done
}

# ---- Delete this app's history entries (phone LAN page, control page) through the browser's own History list ----

# The History modal (chrome://panel-app-nav) asks the browser for entries with its
# requestMoreHistory (webui_action_query_history -> store.history.items: {url, host, date, ...})
# and each row's remove button runs handleDelete (webui_action_delete_history). Both are called
# here with only this app's origins; every other entry is left alone. Re-queried at the end: any
# matching entry left = failed.
$script:QuestDeleteHistoryJs = @'
(async () => {
  const ORIGINS = __ORIGINS__;
  const WAIT_MS = __WAIT_MS__;
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const t0 = Date.now();
  const left = () => WAIT_MS - (Date.now() - t0);
  const roots = () => { const r = []; if (!document.body) return r; for (const el of [document.body, ...document.body.children]) { const k = Object.keys(el).find(k => k.startsWith("__reactContainer") || k.startsWith("__reactFiber")); if (k) r.push(el[k]); } return r; };
  const walk = cb => { for (const root of roots()) { let st = [root], n = 0; while (st.length && n++ < 60000) { const f = st.pop(); if (!f) continue; if (cb(f) === false) return; if (f.child) st.push(f.child); if (f.sibling) st.push(f.sibling); } } };
  const findStore = () => { let s = null; walk(f => { const p = f.memoizedProps; if (p && p.store && p.store.getState) { s = p.store; return false; } }); return s; };
  // A mounted component instance that has method m (the History modal, one of its rows).
  const findInst = m => { let i = null; walk(f => { const sn = f.stateNode; if (sn && typeof sn[m] === "function" && sn.props) { i = sn; return false; } }); return i; };
  // Right after the browser comes to the front its UI page may still be loading (no body yet).
  let store = findStore();
  while (!store && left() > 0) { await sleep(200); store = findStore(); }
  if (!store) return JSON.stringify({ ok: false, error: "browser UI store not found" });
  const H = () => store.getState().history;
  const originOf = u => { try { return new URL(u).origin.toLowerCase(); } catch (e) { return ""; } };
  const want = new Set(ORIGINS.map(originOf).filter(o => o && o !== "null"));
  if (!want.size) return JSON.stringify({ ok: false, error: "no origins" });
  const isOurs = it => want.has(originOf(it.url));
  const opened = store.getState().modal.modalId !== "history";
  if (opened) store.dispatch({ type: "modal/showModal", payload: "history" });
  const finish = r => { if (opened && store.getState().modal.modalId === "history") store.dispatch({ type: "modal/hideModal", payload: "history" }); return JSON.stringify(r); };
  let modal = findInst("requestMoreHistory");
  while (!modal && left() > 0) { await sleep(200); modal = findInst("requestMoreHistory"); }
  if (!modal) return finish({ ok: false, error: "History list not found" });
  const query = async max => {
    const before = H().items;
    modal.requestMoreHistory.call({ props: { lastQuery: "" } }, max);
    const q0 = Date.now();
    while (H().items === before && Date.now() - q0 < 4000 && left() > 0) await sleep(150);
    await sleep(150);
    return H().items !== before;
  };
  // Whole history: maxResults grows until the browser says it reached the beginning.
  let max = 500, answered = false;
  for (let i = 0; i < 6 && left() > 0; i++) {
    answered = (await query(max)) || answered;
    if (H().queryReachedBeginning || H().items.length < max) break;
    max *= 4;
  }
  if (!answered) return finish({ ok: false, error: "history query never answered" });
  const total = H().items.length;
  let ours = H().items.filter(isOurs);
  const found = ours.length;
  if (!found) return finish({ ok: true, found: 0, total, kept: total });
  // A row of the list (its remove button's handler). Sometimes not drawn yet: ask for the list
  // again after 3 s and wait up to 7 s in all.
  let row = findInst("handleDelete");
  const r0 = Date.now();
  let requeried = false;
  while (!row && Date.now() - r0 < 7000 && left() > 0) {
    await sleep(200);
    row = findInst("handleDelete");
    if (!row && !requeried && Date.now() - r0 > 3000) { requeried = true; await query(max); }
  }
  if (!row) return finish({ ok: false, error: "History row not found" });
  const del = Object.getPrototypeOf(row).handleDelete;
  let calls = 0, rounds = 0;
  while (ours.length && rounds++ < 20 && left() > 1500) {
    for (const item of ours) {
      if (left() <= 500) break;
      const before = H().items;
      del.call({ props: { data: item, lastQuery: "", maxResults: max } });
      calls++;
      const d0 = Date.now();
      while (H().items === before && Date.now() - d0 < 3000 && left() > 0) await sleep(100);
    }
    await query(max);
    ours = H().items.filter(isOurs);
  }
  const kept = H().items.length - ours.length;
  if (ours.length) return finish({ ok: false, error: ours.length + " matching entries left (time ran out?)", found, total, kept });
  return finish({ ok: true, found, calls, total, kept });
})()
'@

# ---- Fallback: clear browsing history (History only) for a fixed range through the browser's own dialog ----
# Used only when the match-only delete above fails; __TIME_ID__ is a dialog range id (hour, day,
# week, fourweeks, all). Cookies, cache, passwords, forms and settings are never ticked.

$script:QuestClearHistoryJs = @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const findStore = () => { if (!document.body) return null; for (const el of [document.body, ...document.body.children]) { const k = Object.keys(el).find(k => k.startsWith("__reactContainer") || k.startsWith("__reactFiber")); if (!k) continue; let s = [el[k]], n = 0; while (s.length && n++ < 20000) { const f = s.pop(); if (!f) continue; const p = f.memoizedProps; if (p && p.store && p.store.getState) return p.store; if (f.child) s.push(f.child); if (f.sibling) s.push(f.sibling); } } return null; };
  // Right after the browser comes to the front its UI page may still be loading (no body yet).
  const t0 = Date.now();
  let store = findStore();
  while (!store && Date.now() - t0 < __OPTIONS_WAIT_MS__) { await sleep(200); store = findStore(); }
  if (!store) return JSON.stringify({ ok: false, error: "browser UI store not found" });
  const st = () => store.getState().clearData;
  const close = () => { if (store.getState().modal.modalId === "clear") store.dispatch({ type: "modal/hideModal", payload: "clear" }); };
  const fb = !!(store.getState().facebookLogin || {}).isLoggedIn;
  const prevItems = Object.fromEntries(Object.entries(st().clearItems).map(([k, v]) => [k, v.selected]));
  const prevTime = st().selectedTimeIndex;
  const restore = () => { for (const [id, sel] of Object.entries(prevItems)) store.dispatch({ type: "clearData/setItemSelected", payload: { id, selected: sel } }); store.dispatch({ type: "clearData/setSelectedTimeIndex", payload: { selectedTimeIndex: prevTime, isFBLoggedIn: fb } }); };
  store.dispatch({ type: "modal/showModal", payload: "clear" });
  // The browser fills the time options in asynchronously (slower right after a cold start).
  // One wait for both: the store wait above and this one share __OPTIONS_WAIT_MS__ from t0.
  while (!(st().subtitles || []).length && Date.now() - t0 < __OPTIONS_WAIT_MS__) await sleep(200);
  const subs = st().subtitles || [];
  const allIdx = subs.findIndex(s => s.id === __TIME_ID__);
  if (allIdx < 0) { close(); return JSON.stringify({ ok: false, error: subs.length ? ("no " + __TIME_ID__ + " option (" + subs.map(s => s.id).join(",") + ")") : "dialog time options never arrived" }); }
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

# The front activity's component (com.pkg/.Activity), or '' if unknown.
function Get-QuestFrontActivity {
    param([string] $DeviceSerial)
    $r = Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $DeviceSerial, 'shell', 'dumpsys', 'activity', 'activities')
    $top = @(([string]$r.Out) -split "`r?`n" | Where-Object { $_ -match 'topResumedActivity=' } | Select-Object -First 1)
    if ($top.Count -gt 0 -and $top[0] -match '\s(\S+/\S+)\s') { return $Matches[1] }
    return ''
}

# True only for the browser's 2D window (BrowserActivity), where the History list lives.
# Immersive WebXR/video (WebVRActivity, VideoImmersiveActivity, ...) is the same package but a
# separate task: while it is in front the 2D window is hidden and the list may never fill in.
function Test-QuestBrowserInFront {
    param([string] $DeviceSerial)
    return ((Get-QuestFrontActivity -DeviceSerial $DeviceSerial) -like "$BrowserPackage/*.BrowserActivity")
}

# Deletes the history entries on -Origins (http://host:port) and keeps every other one.
# Returns 'cleared' (none of ours left), 'fallback' (that failed, so all history from
# -FallbackRange was cleared instead) or 'failed'. -FallbackRange '' = no fallback. Everything
# fits in -BudgetSec (one deadline, not per-step limits; the fallback keeps 10 s of it). The
# History list only fills in while Quest Browser is the front app, so the browser is brought to
# the front (and started, if it was closed) first. A cold start rarely fits a short budget.
function Clear-QuestBrowserHistory {
    param([string] $DeviceSerial, [string] $HelperUrl, [string[]] $Origins, [double] $BudgetSec = 25,
        [ValidateSet('', 'hour', 'day', 'week', 'fourweeks', 'all')] [string] $FallbackRange = 'day')
    $deadline = [DateTime]::UtcNow.AddSeconds($BudgetSec)
    $left = { [Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalSeconds) }
    $Origins = @($Origins | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('/') } | Select-Object -Unique)
    if ($Origins.Count -eq 0) { Write-QuestLog 'History: no Loop Segments origins to delete - skipped.'; return 'failed' }
    # Keep this much for the delete itself.
    $reserve = 6
    $was = Get-QuestFrontActivity -DeviceSerial $DeviceSerial
    if ($was -notlike "$BrowserPackage/*.BrowserActivity") {
        # Launcher intent: starts the browser if needed and brings its 2D window to the front (also
        # out of an immersive /xr session). A VIEW intent on a cold start only opened a new-tab
        # page, so no helper tab is used. Sent again once if the first one did not take.
        $launch = { [void](Invoke-Adb -TimeoutSec ([int][Math]::Max(2, [Math]::Min(8, (& $left) - $reserve))) -Arguments @('-s', $DeviceSerial, 'shell', 'monkey', '-p', $BrowserPackage, '-c', 'android.intent.category.LAUNCHER', '1')) }
        & $launch
        $front = $false
        $resent = $false
        $t0 = [DateTime]::UtcNow
        while (-not $front -and (& $left) -gt $reserve) {
            Start-Sleep -Milliseconds 400
            $front = Test-QuestBrowserInFront -DeviceSerial $DeviceSerial
            if (-not $front -and -not $resent -and ([DateTime]::UtcNow - $t0).TotalSeconds -gt 3) { & $launch; $resent = $true }
        }
        $now = Get-QuestFrontActivity -DeviceSerial $DeviceSerial
        if ($front) {
            Write-QuestLog ("History: brought the Quest Browser window to the front (was '{0}')." -f $(if ($was) { $was } else { 'unknown' }))
        } else {
            Write-QuestLog ("History: Quest Browser window did not come to the front in time (was '{0}', now '{1}') - trying anyway." -f $was, $now)
        }
    }
    $ui = Get-QuestBrowserUi
    while (-not $ui -and (& $left) -gt $reserve) { Start-Sleep -Milliseconds 400; $ui = Get-QuestBrowserUi }
    if (-not $ui) {
        Write-QuestLog ("History: Quest Browser UI not ready within the {0:0} s budget (cold start?) - not cleared." -f $BudgetSec)
        return 'failed'
    }
    # Leave time for the fallback range clear when there is one.
    $fallbackSec = if ($FallbackRange) { 10 } else { 0 }
    try {
        $evalSec = [Math]::Max(3, (& $left) - $fallbackSec)
        # The page script's own deadline: its share of what is left, minus a little for the reply.
        $waitMs = [int][Math]::Max(2000, ($evalSec - 1.5) * 1000)
        $js = $script:QuestDeleteHistoryJs.Replace('__ORIGINS__', (ConvertTo-Json -InputObject @($Origins) -Compress)).Replace('__WAIT_MS__', "$waitMs")
        $r = Invoke-QuestEval -Tab $ui -Expression $js -TimeoutSec ([int][Math]::Ceiling($evalSec) + 2) | ConvertFrom-Json
        $on = $Origins -join ', '
        if ($r.ok) {
            if ([int]$r.found -eq 0) { Write-QuestLog ("History: no entries on {0} (kept {1})." -f $on, $r.kept) }
            else { Write-QuestLog ("History: deleted {0} entr{1} on {2}; kept the other {3}." -f $r.found, $(if ([int]$r.found -eq 1) { 'y' } else { 'ies' }), $on, $r.kept) }
            return 'cleared'
        }
        Write-QuestLog "History: selective delete failed - $($r.error)"
    } catch {
        Write-QuestLog "History: selective delete failed - $($_.Exception.Message)"
    }
    if (-not $FallbackRange) { return 'failed' }
    $ui = Get-QuestBrowserUi
    if (-not $ui) { Write-QuestLog 'History: fallback skipped - Quest Browser UI gone.'; return 'failed' }
    $fb = Clear-QuestBrowserHistoryRange -Ui $ui -Range $FallbackRange -BudgetSec ([Math]::Max(3, (& $left)))
    return $(if ($fb) { 'fallback' } else { 'failed' })
}

# Fallback: clear ALL history (History only) for one of the dialog's fixed ranges (hour, day,
# week, fourweeks, all) through Quest Browser's Clear browsing data dialog; the dialog's previous
# ticks and range are put back. Returns $true when cleared.
function Clear-QuestBrowserHistoryRange {
    param($Ui, [ValidateSet('hour', 'day', 'week', 'fourweeks', 'all')] [string] $Range, [double] $BudgetSec = 10)
    $label = @{ hour = 'last hour'; day = 'last 24 hours'; week = 'last 7 days'; fourweeks = 'last 4 weeks'; all = 'all time' }[$Range]
    try {
        $evalSec = [Math]::Max(3, $BudgetSec)
        $optionsMs = [int][Math]::Max(1000, [Math]::Min(15000, ($evalSec - 3) * 1000))
        $js = $script:QuestClearHistoryJs.Replace('__OPTIONS_WAIT_MS__', "$optionsMs").Replace('__TIME_ID__', (ConvertTo-Json -InputObject $Range -Compress))
        $r = Invoke-QuestEval -Tab $Ui -Expression $js -TimeoutSec ([int][Math]::Ceiling($evalSec) + 2) | ConvertFrom-Json
        if ($r.ok) { Write-QuestLog "History: fallback cleared ALL Quest Browser history from the $label (history only)."; return $true }
        Write-QuestLog "History: fallback ($label) not cleared - $($r.error)"
    } catch {
        Write-QuestLog "History: fallback ($label) not cleared - $($_.Exception.Message)"
    }
    return $false
}
