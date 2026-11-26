<#
.SYNOPSIS
  Open the phone LAN page in Quest Browser over adb; keep its flags set; clear its history.

.DESCRIPTION
  Default (-Once, used by the "Open on Quest" button through the companion sink): opens -Url in a
  NORMAL Quest Browser tab, signed in:
    1. VIEW intent for the plain URL (retried; the browser sometimes drops the first one),
    2. over the browser's DevTools socket: navigate that tab to http://admin:<password>@host/
       (caches the LAN login), then back to the plain URL, then drop its back/forward entries.
       A page whose URL still has user:pass@ cannot fetch() (status_lists.json would fail).
    3. reads window.isSecureContext in the opened tab. It is true only while chrome://flags
       "unsafely-treat-insecure-origin-as-secure" lists the page's origin (WebXR needs it), so
       chrome://flags is opened only when it is false: the flag gets every phone LAN origin,
       Quest Browser restarts (closing its tabs) and steps 1-2 run again.
  The password comes from loop-segments-windows.json (per-phone phoneLanHosts[].webdavPassword,
  else webdavPassword); it is never logged or put on a command line. -NoLanLogin /
  questSendLanLogin=false opens the plain URL (you sign in on the headset).

  Always a normal tab, never a private one: Quest Browser disables immersive WebXR in private tabs, so
  the XR player could not enter VR there.

  -WaitMinutes N : when opening the page, a headset that is asleep or off adb is not an error: keep polling
                   for up to N minutes and open the page when it wakes (the button uses 7).
                   -StatusFile gets 'queued' / 'opening' so the companion sink can report it.
  -EnsureFlags   : only the chrome://flags fix of step 3, for any phone LAN origin missing from
                   the flag (by hand; the companion no longer runs it at startup).
  -ClearHistory  : (-CloseLanTabs first closes every tab on a phone LAN origin; -SkipHistoryClear
                   then stops there) delete the Quest Browser history entries on the phone LAN
                   origins and the Quest control page (through the browser's own History list);
                   other history, cookies, cache, passwords, forms, settings are kept. If that
                   fails, clears ALL history from the questClearHistoryFallback range (default
                   last 24 hours, history only) through the Clear browsing data dialog. Companion
                   runs it on close.
  -EnableProximity : turn the proximity sensor back on (undoes a `prox_close` override, so the
                   headset sleeps again when taken off). Companion runs it on close. Needs no -Url.
  -DisableProximity : hold the proximity sensor off (`prox_close`; headset stays awake when taken
                   off). -ToggleProximity flips it. Both need no -Url; quest\Set-LoopSegmentsQuestProximitySensor.ps1
                   wraps all three.
  -WifiOff       : switch the headset's Wi-Fi off now (Settings > Wi-Fi opened first on an awake
                   headset), whatever questWifiOffOnExit says; adb drops right after.
                   quest\Set-LoopSegmentsQuestWifiOff.ps1 wraps it. Needs no -Url.
  -ResetFlags    : reset every Quest Browser chrome://flags entry to its default ("Reset all") and
                   restart Quest Browser (closes its tabs). The next Open on Quest sets the
                   insecure-origin flag again. quest\Reset-QuestBrowserFlags.ps1 wraps it.
  -SkyboxPush    : put WebDAV server 'Loop Segments' in SKYBOX's Network list at the phone's current
                   address (-LanConfig lan_config.json, else -Url) with the current LAN login, and drop
                   the ones this PC added at older addresses (quest_tools QuestSkybox.ps1; stops SKYBOX only when
                   the row changes). The Quest control page's Push button.
  -SkyboxUpdate  : the same, only if such a server is already there (Update button).
  -ClearSkyboxWebDav : remove every SKYBOX server this PC added (with -ClearHistory: after the
                   history step). Needs no -Url.
  After-quit helper: a -ClearHistory whose history delete fails (Quest Browser does not answer
                   while nobody wears the headset) or that finds no headset hands it to quest_tools'
                   after-quit helper (Invoke-QuestHistoryRetry.ps1, detached): it deletes those entries
                   once the headset is worn (same questClearHistoryFallback range as the quit), and
                   stops when done, after questHistoryRetryMinutes (120), or when the companion starts
                   again. Exit 4 from -ClearHistory = only the history step was handed to it.
  -KeepAwakeSession : until -ParentPid exits, every ~20 s: when the headset is on adb, awake, and the
                   proximity override is not CLOSE, send `prox_close` (headset acts as worn and does
                   not sleep, so it stays on adb). A headset in standby is left alone (prox_close
                   would wake it); it gets the override once someone puts it on. Re-applies after a headset reboot. Never re-enables
                   the sensor itself (the companion's cleanup does, after clearing history).
                   Also, while one of our pages plays on the Quest (quest_tools Get-QuestMediaActivity:
                   a media request in the last 3 min, e.g. 3d_playlist_local's XR page) AND a
                   3d_playlist_local workflow runs from the L: mount (its registered copy is on L:),
                   POST /keep_alive.json reset to the phone every 10 min, so the
                   phone's 60 min Keep Alive (its LAN server, the L: mount) does not run out mid-session
                   (-LanConfig = the companion's lan_config.json, for the phone's current address).

  -KeepAwakeSession -RestoreProximity : as -KeepAwakeSession, and turn the sensor back on once -ParentPid exits.

  Without a mode switch it opens the page once, like -Once (there is no keep-watching mode).

  The generic headset code (adb, finding the headset, proximity sensor, keep-awake, Wi-Fi off, Quest
  Browser DevTools / chrome://flags / history, SKYBOX database) is in the quest_tools repo
  ($env:QUEST_TOOLS_REPO, else P:\all_scripts\quest_tools next to this repo's parent folder; see
  quest\QuestToolsPath.ps1); this script loads it and exits 2 when it is missing. The proximity,
  Wi-Fi and keep-awake modes here are the same as quest_tools\Invoke-QuestHeadset.ps1's.

  Needs developer mode on the Quest and adb on this PC (winget install Google.PlatformTools).
  Wireless adb is switched off by every Quest reboot; the adb-auto-enable app
  (https://github.com/project-SIMPLE/adb-auto-enable) keeps it on. Setup: quest_tools\README.md.

  Finding the headset (quest_tools\lib\QuestAdb.ps1):
    1. A device already in `adb devices -l` whose model looks like a Quest (or -Serial).
    2. `adb connect <questAdbHost>:<questAdbPort>` (default port 5555) when questAdbHost is set.
    3. `adb connect` to the last ip:port the headset was on adb at (%TEMP%\loopsegments-quest-last-adb.txt):
       the port survives until a reboot / wireless-debugging toggle, and mDNS can take minutes.
    4. `adb mdns services` _adb-tls-connect entries (wireless-debugging TLS port, already paired).
    5. Not found for questAdbRediscoverSec (60 s) and no adb device connected: restart the adb server
       once and look over mDNS again (at most every 5 min across processes; 0 = off).

  Log: %TEMP%\loopsegments-quest-lantab.log
  Exit codes: 0 ok, 1 headset not reachable / asleep, 2 no adb or bad arguments, 3 step failed,
  4 (-ClearHistory) everything else done, history delete postponed to the after-quit helper.

.EXAMPLE
  .\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://10.0.100.10:8765/ -Once

.EXAMPLE
  .\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://10.0.100.10:8765/ -EnsureFlags

.EXAMPLE
  .\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://10.0.100.10:8765/ -ClearHistory

.EXAMPLE
  .\Watch-LoopSegmentsQuestLanTab.ps1 -EnableProximity


#>
[CmdletBinding()]
param(
    [string] $Url = '',
    [int] $ParentPid = 0,
    [int] $PollSeconds = 5,
    [string] $AdbExe = '',
    [string] $Serial = '',
    [string] $QuestHost = '',
    [int] $Port = 0,
    # Open the page once and exit (also the default; kept for the companion sink's command line).
    [switch] $Once,
    # Opening the page: wait up to this many minutes for an asleep / unreachable headset to wake.
    [int] $WaitMinutes = 0,
    # Opening the page: file that gets 'queued' / 'opening' (read by the companion sink).
    [string] $StatusFile = '',

    # Do not sign the tab in with admin:<password>@ (you sign in on the headset).
    [switch] $NoLanLogin,
    # Only make sure the insecure-origin chrome://flags entry covers the phone LAN origins.
    [switch] $EnsureFlags,
    # Only clear Quest Browser history (History only, All time).
    [switch] $ClearHistory,
    # With -ClearHistory: first close every tab on a phone LAN origin.
    [switch] $CloseLanTabs,
    # With -ClearHistory -CloseLanTabs: close the tabs but keep history.
    [switch] $SkipHistoryClear,
    # With -ClearHistory: afterwards turn the proximity sensor back on (companion close, one process).
    [switch] $EnableProximityAfter,
    # Do not check isSecureContext / touch chrome://flags after opening the tab.
    [switch] $NoFlags,
    # Only turn the proximity sensor back on (am broadcast ...vrpowermanager.automation_disable).
    [switch] $EnableProximity,
    # Only hold the proximity sensor off (am broadcast ...vrpowermanager.prox_close): headset stays awake.
    [switch] $DisableProximity,
    # Only flip the proximity sensor: off if it is on, on if it is held off.
    [switch] $ToggleProximity,
    # Keep the headset awake (prox_close) while -ParentPid runs.
    [switch] $KeepAwakeSession,
    # Only reset all Quest Browser chrome://flags to their defaults (and restart the browser).
    [switch] $ResetFlags,
    # Only switch the headset's Wi-Fi off (by hand; ignores questWifiOffOnExit).
    [switch] $WifiOff,
    # Quest control page: put the phone in SKYBOX as WebDAV server 'Loop Segments' (current address
    # and login), dropping older addresses this PC added.
    [switch] $SkyboxPush,
    # Same, but only if such a server is already in SKYBOX.
    [switch] $SkyboxUpdate,
    # Remove that SKYBOX WebDAV server (alone, or with -ClearHistory after the history step).
    [switch] $ClearSkyboxWebDav,
    # The companion's lan_config.json: phone address for the SKYBOX steps (re-read every poll).
    [string] $LanConfig = '',
    # Opening a page: owner name it is registered under in quest_tools' shared origin list
    # (%TEMP%\quest-browser-origins.json), which every -ClearHistory also closes and deletes.
    [string] $Owner = 'loopsegments',
    # With -KeepAwakeSession: once -ParentPid exits, turn the sensor back on (3d_playlist_local
    # workflow session; the companion's cleanup does that itself).
    [switch] $RestoreProximity,
    # Read-only: print every Quest Browser history entry (origin + path, no login, no query string)
    # and whether the history delete would match it. Nothing is deleted or logged.
    [switch] $ListHistory,
    # Read-only: print open tabs, Recently closed items and the browser UI's handlers / store actions
    # that look like they remove Recently closed items (to fix the sweep). Nothing is changed.
    [switch] $ProbeRecentlyClosed,
    # Diagnostic: is a helper-page visit recorded in history when made from the open new-tab page
    # directly, and via about:blank? (Restores the new-tab page afterwards.)
    [switch] $TestHelperVisit
)

Set-StrictMode -Version Latest
$script:StartedAt = [DateTime]::UtcNow
$ErrorActionPreference = 'Stop'

# Generic headset layer (adb, headset discovery, proximity sensor, Wi-Fi, Quest Browser DevTools,
# SKYBOX database, Write-QuestLog -> %TEMP%\loopsegments-quest-lantab.log): the quest_tools repo
# ($env:QUEST_TOOLS_REPO, else a quest_tools folder next to this repo's parent folders).
. (Join-Path $PSScriptRoot 'QuestToolsPath.ps1')
if (-not $script:QuestToolsRepo) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), 'quest_tools not found (set QUEST_TOOLS_REPO) - Quest helpers disabled.'
    try { Add-Content -LiteralPath (Join-Path $env:TEMP 'loopsegments-quest-lantab.log') -Value $line -Encoding utf8 } catch {}
    Write-Host "[quest] $line"
    exit 2
}
. (Join-Path $script:QuestToolsRepo 'QuestTools.ps1')
$BrowserPackage = 'com.oculus.browser'
$script:Cfg = $null

# Per-PC overrides from windows\loop-segments-windows.json (params win).
$script:AdbRediscoverSec = 60
$WindowsLib = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\LoopSegments-Windows.ps1'
if (Test-Path -LiteralPath $WindowsLib) {
    try {
        . $WindowsLib
        $cfg = Get-LoopSegmentsWindowsSettings
        $script:Cfg = $cfg
        if ([string]::IsNullOrWhiteSpace($AdbExe)) { $AdbExe = [string]$cfg.questAdbExe }
        if ([string]::IsNullOrWhiteSpace($QuestHost)) { $QuestHost = [string]$cfg.questAdbHost }
        if ([string]::IsNullOrWhiteSpace($Serial)) { $Serial = [string]$cfg.questAdbSerial }
        if ($Port -le 0 -and $null -ne $cfg.questAdbPort) { $Port = [int]$cfg.questAdbPort }
        if ($null -ne $cfg.questAdbRediscoverSec) { $script:AdbRediscoverSec = [int]$cfg.questAdbRediscoverSec }
        if ($cfg.Contains('questEnsureInsecureOriginFlag') -and $cfg.questEnsureInsecureOriginFlag -eq $false) { $NoFlags = $true }
        if ($cfg.Contains('questSendLanLogin') -and $cfg.questSendLanLogin -eq $false) { $NoLanLogin = $true }
    } catch {
        Write-QuestLog "Config read failed: $($_.Exception.Message)"
    }
}
if ($Port -le 0) { $Port = 5555 }
Initialize-QuestTools -AdbExe $AdbExe -Serial $Serial -QuestHost $QuestHost -Port $Port -RediscoverSec $script:AdbRediscoverSec

# Opening a page (VIEW intent, signed-in normal tab, isSecureContext, flag fix):
# quest_tools lib\QuestOpen.ps1 (Open-QuestPage). This script supplies the phone login, the control
# page tab, the helper page and the Loop Segments origins.
# Phone Keep Alive (POST /keep_alive.json on the phone LAN, build 440+). Its window is 60 min from the
# app's last foreground or the last LAN reset; WebDAV and Quest traffic do not extend it, and once it
# ends in the background the phone's LAN server (and the rclone L: mount) stops.
#   Send-PhoneKeepAlive                         the one POST (both callers below)
#   Invoke-PhoneKeepAliveExtendAfterQuestOpen   after Open on Quest succeeds: extend +60 min
#   Invoke-PhoneKeepAliveOnQuestPlayback        -KeepAwakeSession tick: reset to 60 min while the Quest plays

# Returns [pscustomobject]{ Status = HTTP code; Json = parsed reply or $null }. HTTP errors come back as
# a Status; network errors (phone server down, timeout) throw.
function Send-PhoneKeepAlive {
    param([Parameter(Mandatory)] [string] $LanUrl, [Parameter(Mandatory)] [string] $Action, [string] $Reason = '')
    $u = [Uri]$LanUrl
    $login = Get-QuestLanLogin -ForUrl $LanUrl
    $pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(('{0}:{1}' -f $login.User, $login.Password)))
    $body = [ordered]@{ action = $Action; reason = $Reason } | ConvertTo-Json -Compress
    $r = Invoke-WebRequest -Uri ('{0}://{1}/keep_alive.json' -f $u.Scheme, $u.Authority) -Method Post -Body $body `
        -ContentType 'application/json; charset=utf-8' -Headers @{ Authorization = "Basic $pair" } `
        -NoProxy -TimeoutSec 15 -UseBasicParsing -SkipHttpErrorCheck
    # Without a text Content-Type, Invoke-WebRequest hands back bytes.
    $text = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
    $json = $null
    try { $json = $text | ConvertFrom-Json -ErrorAction Stop } catch {}
    return [pscustomobject]@{ Status = [int]$r.StatusCode; Json = $json }
}

function Get-PhoneKeepAliveError {
    param($Reply)
    if ($Reply.Status -eq 404 -or $Reply.Status -eq 405) { return 'phone build missing /keep_alive.json (need 440+)' }
    if ($null -ne $Reply.Json -and $Reply.Json.PSObject.Properties['error'] -and $Reply.Json.error) { return [string]$Reply.Json.error }
    return "HTTP $($Reply.Status)"
}

function Invoke-PhoneKeepAliveExtendAfterQuestOpen {
    param([string] $LanUrl = $Url)
    if ([string]::IsNullOrWhiteSpace($LanUrl)) {
        Write-QuestLog 'Keep Alive: no LAN URL - skip +60 min extend.'
        return
    }
    if (-not (Get-Command Get-LoopSegmentsWebDAVCredentials -ErrorAction SilentlyContinue)) {
        Write-QuestLog 'Keep Alive: auth helper missing - skip +60 min extend.'
        return
    }
    try {
        $r = Send-PhoneKeepAlive -LanUrl $LanUrl -Action 'extend' -Reason 'quest_open'
        $j = $r.Json
        if ($r.Status -eq 200 -and $null -ne $j -and $j.ok -eq $true -and $j.extended -eq $true) {
            $left = if ($null -ne $j.sessionRemainingSeconds) { ' (~{0:N0}s remaining)' -f [double]$j.sessionRemainingSeconds } else { '' }
            Write-QuestLog ("Keep Alive: +60 min after Open on Quest{0}." -f $left)
        } elseif ($r.Status -eq 200 -and $null -ne $j -and $j.ok -eq $true -and $j.exportSession -eq $true) {
            Write-QuestLog 'Keep Alive: export running - +60 min extend skipped.'
        } elseif ($r.Status -eq 404 -or $r.Status -eq 405) {
            Write-QuestLog 'Keep Alive: phone build missing /keep_alive.json (need 440+) - skip.'
        } else {
            Write-QuestLog "Keep Alive: extend failed ($(Get-PhoneKeepAliveError $r))."
        }
    } catch {
        Write-QuestLog ("Keep Alive: extend request failed: {0}" -f $_.Exception.Message)
    }
}

# Running 3d_playlist_local workflows whose copy lives on the phone's rclone mount (L:\archive\...),
# from %TEMP%\loopsegments-playlist-session.json (3d_playlist_local Register-PlaylistQuestSession:
# shutdownScript = that workflow's own copy). Same PID-and-start-time check as 3d_playlist_local, so a
# reused PID does not count. Returns the workflow names (empty = none runs from L:).
$script:PlaylistSessionPath = Join-Path $env:TEMP 'loopsegments-playlist-session.json'
function Get-PlaylistWorkflowsOnPhoneMount {
    if (-not (Test-Path -LiteralPath $script:PlaylistSessionPath)) { return @() }
    try { $list = @((Get-Content -LiteralPath $script:PlaylistSessionPath -Raw -ErrorAction Stop | ConvertFrom-Json).sessions) } catch { return @() }
    # The configured letter (mountDriveLetter, default L) plus any letter our rclone mount actually runs
    # on (remote loopsegments: in its command line, so the Koofr or other rclone mounts never count).
    $letters = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $configured = 'L'
    if (Get-Command Get-LoopSegmentsMountDriveLetter -ErrorAction SilentlyContinue) {
        try { $configured = [string](Get-LoopSegmentsMountDriveLetter) } catch {}
    }
    [void]$letters.Add($configured)
    if (Get-Command Get-LoopSegmentsRcloneMountedDriveLetters -ErrorAction SilentlyContinue) {
        # It returns its HashSet as one object (return ,$set): enumerate that, not @() around it.
        try { $mounted = Get-LoopSegmentsRcloneMountedDriveLetters; foreach ($m in $mounted) { if ($m) { [void]$letters.Add([string]$m) } } } catch {}
    }
    return @($list | Where-Object {
            $_ -and $_.PSObject.Properties['shutdownScript'] -and [int]$_.pid -gt 0 -and
            ([string]$_.shutdownScript) -match '^([A-Za-z]):\\' -and $letters.Contains($Matches[1]) -and
            (Get-QuestProcessStartStamp -ProcessId ([int]$_.pid)) -eq [string]$_.started
        } | ForEach-Object { [string]$_.name })
}

# Every running 3d_playlist_local workflow (wherever its copy lives), same PID-and-start-time check.
function Get-PlaylistLiveWorkflows {
    if (-not (Test-Path -LiteralPath $script:PlaylistSessionPath)) { return @() }
    try { $list = @((Get-Content -LiteralPath $script:PlaylistSessionPath -Raw -ErrorAction Stop | ConvertFrom-Json).sessions) } catch { return @() }
    return @($list | Where-Object {
            $_ -and [int]$_.pid -gt 0 -and (Get-QuestProcessStartStamp -ProcessId ([int]$_.pid)) -eq [string]$_.started
        } | ForEach-Object { [string]$_.name })
}

# -KeepAwakeSession tick: close the companion once the phone's Keep Alive has run out.
# Every KaPollSec, GET /keep_alive.json. A reply sets the expected end: now + sessionRemainingSeconds for
# a running 60 min session; none (never closes) for an export-owned one (it runs until the export ends),
# no auto-stop, Keep Alive off, or the app in front (it answers while not active). Expired = that end
# plus companionCloseAfterKeepAliveMinutes has passed and the phone has not answered for as long (any
# reply recomputes the end, so a renewal or bringing the app to the front cancels it). Then, once no
# 3d_playlist_local workflow runs (its playback would lose the Quest: the quit turns Wi-Fi off), close
# the companion's Chromium without /F, so its normal quit runs, as if you closed it. Once per run.
$script:KaPollSec = 60
$script:KaLastPoll = [DateTime]::MinValue
$script:KaLastOkUtc = [DateTime]::MinValue
$script:KaEndsUtc = $null
$script:KaCloseDone = $false
$script:KaWaitLogged = ''

function Get-PhoneKeepAliveStatus {
    param([Parameter(Mandatory)] [string] $LanUrl)
    $u = [Uri]$LanUrl
    $login = Get-QuestLanLogin -ForUrl $LanUrl
    $pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(('{0}:{1}' -f $login.User, $login.Password)))
    $r = Invoke-WebRequest -Uri ('{0}://{1}/keep_alive.json' -f $u.Scheme, $u.Authority) -Method Get `
        -Headers @{ Authorization = "Basic $pair" } -NoProxy -TimeoutSec 10 -UseBasicParsing -SkipHttpErrorCheck
    if ([int]$r.StatusCode -ne 200) { return $null }
    $text = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
    try { return ($text | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Get-CompanionChromiumProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $c = [string]$_.CommandLine; $c -notlike '*--type=*' -and $c -match '(?i)pcloud_web_companion[\\/]+chromium-profile' })
}

function Invoke-CompanionCloseOnKeepAliveExpiry {
    if ($script:KaCloseDone) { return }
    $minutes = 5
    try { $minutes = [double](Get-LoopSegmentsWindowsSettings).companionCloseAfterKeepAliveMinutes } catch {}
    if ($minutes -le 0) { return }
    $now = [DateTime]::UtcNow
    if (($now - $script:KaLastPoll).TotalSeconds -ge $script:KaPollSec) {
        $script:KaLastPoll = $now
        $lan = Get-QuestSkyboxCurrentLanUrl
        $j = $null
        if ($lan) { try { $j = Get-PhoneKeepAliveStatus -LanUrl $lan } catch { $j = $null } }
        if ($null -ne $j) {
            $script:KaLastOkUtc = $now
            $left = $j.PSObject.Properties['sessionRemainingSeconds']
            if ($j.enabled -ne $false -and $j.active -eq $true -and $j.exportSession -ne $true -and $left -and $null -ne $left.Value) {
                $script:KaEndsUtc = $now.AddSeconds([double]$left.Value)
            } else {
                $script:KaEndsUtc = $null
            }
            $script:KaWaitLogged = ''
        }
    }
    if ($null -eq $script:KaEndsUtc) { return }
    $grace = [TimeSpan]::FromMinutes($minutes)
    if ($now -lt $script:KaEndsUtc.Add($grace) -or ($now - $script:KaLastOkUtc) -lt $grace) { return }
    $endLocal = $script:KaEndsUtc.ToLocalTime().ToString('HH:mm')
    $running = @(Get-PlaylistLiveWorkflows)
    if ($running.Count -gt 0) {
        $key = $running -join ', '
        if ($script:KaWaitLogged -ne $key) {
            Write-QuestLog "Keep Alive: the phone's Keep Alive ran out at $endLocal (no answer since) - closing the companion once 3d_playlist_local ends ($key running)."
            $script:KaWaitLogged = $key
        }
        return
    }
    $script:KaCloseDone = $true
    $chrome = @(Get-CompanionChromiumProcesses)
    if ($chrome.Count -eq 0) {
        Write-QuestLog "Keep Alive: the phone's Keep Alive ran out at $endLocal, but no companion Chromium is running - nothing to close."
        return
    }
    Write-QuestLog ("Keep Alive: the phone's Keep Alive ran out at {0} and the phone has not answered for {1:N0} min; no 3d_playlist_local workflow runs - closing the companion's Chromium (its normal quit runs)." -f $endLocal, ($now - $script:KaLastOkUtc).TotalMinutes)
    $pidArgs = @($chrome | ForEach-Object { '/PID'; [string]$_.ProcessId })
    try { & taskkill.exe @pidArgs | Out-Null } catch { Write-QuestLog "Keep Alive: closing the companion's Chromium failed: $($_.Exception.Message)" }
}

# -KeepAwakeSession tick (the companion's, every ~20 s). Playing = one of our pages served a media
# request in the last QuestPlaybackFreshSec (quest_tools Get-QuestMediaActivity: per-owner files such
# as 3d_playlist_local's XR server's; other Quest Browser playback does not count). While playing AND
# a 3d_playlist_local workflow runs from the phone's L: mount (Get-PlaylistWorkflowsOnPhoneMount; it
# may need its own scripts from L: even when no video is read from there): reset (a fresh 60 min) every
# QuestPlaybackResetSec. Otherwise nothing: the phone's timer runs out (rclone video reads on L: renew
# it on the phone itself, app build 452+).
$script:QuestPlaybackFreshSec = 180
$script:QuestPlaybackResetSec = 600
$script:QuestPlaybackRetrySec = 60
$script:QuestPlaybackPlaying = $false
$script:QuestPlaybackLastReset = [DateTime]::MinValue
$script:QuestPlaybackLastTry = [DateTime]::MinValue
$script:QuestPlaybackLastError = ''
$script:QuestPlaybackOffMountLogged = $false

function Invoke-PhoneKeepAliveOnQuestPlayback {
    $act = @(Get-QuestMediaActivity -FreshSec $script:QuestPlaybackFreshSec)
    $now = [DateTime]::UtcNow
    $onMount = @()
    if ($act.Count -gt 0) { $onMount = @(Get-PlaylistWorkflowsOnPhoneMount) }
    if ($act.Count -eq 0 -or $onMount.Count -eq 0) {
        if ($script:QuestPlaybackPlaying) {
            $why = if ($act.Count -eq 0) { 'Quest playback stopped' } else { 'no 3d_playlist_local workflow runs from L: any more' }
            Write-QuestLog "Keep Alive: $why - the phone Keep Alive runs out on its own timer (<= 60 min)."
            $script:QuestPlaybackPlaying = $false
            $script:QuestPlaybackLastReset = [DateTime]::MinValue
        }
        if ($act.Count -eq 0) {
            $script:QuestPlaybackOffMountLogged = $false
        } elseif (-not $script:QuestPlaybackOffMountLogged) {
            Write-QuestLog 'Keep Alive: Quest playing, but no 3d_playlist_local workflow runs from L: - phone Keep Alive not renewed.'
            $script:QuestPlaybackOffMountLogged = $true
        }
        return
    }
    $script:QuestPlaybackOffMountLogged = $false
    if (($now - $script:QuestPlaybackLastReset).TotalSeconds -lt $script:QuestPlaybackResetSec) { return }
    if (($now - $script:QuestPlaybackLastTry).TotalSeconds -lt $script:QuestPlaybackRetrySec) { return }
    $script:QuestPlaybackLastTry = $now
    $lan = Get-QuestSkyboxCurrentLanUrl
    $err = ''
    if (-not $lan) {
        $err = 'no phone LAN address (-LanConfig / -Url)'
    } else {
        try {
            $r = Send-PhoneKeepAlive -LanUrl $lan -Action 'reset' -Reason 'quest_playback'
            if ($r.Status -eq 200 -and $null -ne $r.Json -and $r.Json.ok -eq $true) {
                $script:QuestPlaybackLastReset = $now
                $script:QuestPlaybackLastError = ''
                if (-not $script:QuestPlaybackPlaying) {
                    $what = if ($r.Json.reset -eq $true) { 'reset to 60 min' } else { 'left to the running export' }
                    $who = ($act | ForEach-Object { $_.Owner }) -join ', '
                    Write-QuestLog ("Keep Alive: Quest playing ({0}, last media {1:N0} s ago; workflow on L: {2}) - phone session {3}; renewed every {4} min while it plays." -f $who, $act[0].AgeSec, ($onMount -join ', '), $what, ($script:QuestPlaybackResetSec / 60))
                    $script:QuestPlaybackPlaying = $true
                }
                return
            }
            $err = Get-PhoneKeepAliveError $r
        } catch {
            $err = $_.Exception.Message
        }
    }
    if ($err -ne $script:QuestPlaybackLastError) {
        Write-QuestLog "Keep Alive: Quest playing but the phone reset failed ($err) - retrying every $($script:QuestPlaybackRetrySec) s."
        $script:QuestPlaybackLastError = $err
    }
}

# The phone's LAN login for -ForUrl (default -Url): webdavUser + per-phone
# phoneLanHosts[].webdavPassword, else webdavPassword. Re-reads loop-segments-windows.json on every
# call. Never logged.
function Get-QuestLanLogin {
    param([string] $ForUrl = $Url)
    $u = [Uri]$ForUrl
    $cred = Get-LoopSegmentsWebDAVCredentials
    $pass = [string]$cred.Password
    foreach ($raw in @((Get-LoopSegmentsWindowsSettings).phoneLanHosts)) {
        if ($null -eq $raw) { continue }
        $e = ConvertTo-LoopSegmentsPhoneHostEntry -Raw $raw
        if ($e -and $e.Host -eq $u.Host -and -not [string]::IsNullOrWhiteSpace([string]$e.Password)) { $pass = [string]$e.Password }
    }
    return [pscustomobject]@{ User = [string]$cred.User; Password = $pass }
}

# LAN URL with the login (Get-QuestLanLogin) as percent-encoded userinfo. Returns -Url unchanged
# when sending the login is off or none is set.
function Get-QuestTypedUrl {
    if (-not $script:SendLanLogin) { return ($Url -replace "'", '') }
    try {
        $u = [Uri]$Url
        $login = Get-QuestLanLogin
        $user = $login.User
        $pass = $login.Password
        if ([string]::IsNullOrEmpty($pass)) {
            Write-QuestLog 'No LAN password in loop-segments-windows.json - opening without the login.'
            return ($Url -replace "'", '')
        }
        $userInfo = [Uri]::EscapeDataString($user) + ':' + [Uri]::EscapeDataString($pass)
        return ('{0}://{1}@{2}' -f $u.Scheme, $userInfo, $u.Authority) + $u.PathAndQuery
    } catch {
        Write-QuestLog 'Could not read the LAN login - opening without it.'
        return ($Url -replace "'", '')
    }
}


# Every phone LAN origin the flag should list: -Url plus phoneLanHost / phoneLanHosts from config.
function Get-QuestLanOrigins {
    $list = [System.Collections.Generic.List[string]]::new()
    try { $u = [Uri]$Url; $list.Add(('{0}://{1}' -f $u.Scheme, $u.Authority)) } catch {}
    if ($script:Cfg) {
        $port = 8765
        try { if ([int]$script:Cfg.lanPort -gt 0) { $port = [int]$script:Cfg.lanPort } } catch {}
        $hostsRaw = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$script:Cfg.phoneLanHost)) { $hostsRaw += [string]$script:Cfg.phoneLanHost }
        foreach ($raw in @($script:Cfg.phoneLanHosts)) { if ($null -ne $raw) { $hostsRaw += $raw } }
        foreach ($raw in $hostsRaw) {
            try {
                $e = ConvertTo-LoopSegmentsPhoneHostEntry -Raw $raw -DefaultPort $port
                if ($e -and $e.Host) { $list.Add(('http://{0}:{1}' -f $e.Host, $e.Port)) }
            } catch {}
        }
    }
    # The PC-served helper page (Get-QuestHelperUrl, phone not answering): deleted with the others.
    if ($script:HelperFallbackOrigin) { $list.Add($script:HelperFallbackOrigin) }
    return @($list | Select-Object -Unique)
}

# The helper page for the Recently closed sweep (quest_tools lib\QuestHelperPage.ps1): the phone's
# /xr-assets/lsclean (a small 404 page, no login: it has to land in Quest Browser history; the old
# /xr-assets/aframe.min.js, a 1.4 MB script, stopped being recorded). Phone not answering (Loop
# Segments app closed, phone off the LAN; seen 2026-11-19 at an End session without the companion,
# which left two ".../xr-assets/lsclean" items): the same page is served from this PC on
# questControlPort + 1 and its origin joins Get-QuestLanOrigins. Decided once per process.
$script:HelperFallbackOrigin = $null

# The phone's helper page URL (no fallback decided yet).
function Get-QuestPhoneHelperUrl {
    try { $u = [Uri]$Url; return ('{0}://{1}/xr-assets/lsclean' -f $u.Scheme, $u.Authority) } catch { return $Url }
}

function Get-QuestHelperUrl {
    if (-not $script:QtHelperPage) {
        $ip = $null
        try { $ip = Get-QuestControlPcAddress -DeviceSerial (Get-OnlineQuestSerial) } catch {}
        [void](Resolve-QuestHelperUrl -PreferredUrl (Get-QuestPhoneHelperUrl) -FallbackPort ((Get-QuestControlPort) + 1) -PcAddress $ip)
    }
    $script:HelperFallbackOrigin = $script:QtHelperPage.FallbackOrigin
    return $script:QtHelperPage.Url
}

function Invoke-QuestFlagSync {
    param([string] $DeviceSerial, [switch] $SkipConfirm)
    if (-not (Open-QuestDevTools -DeviceSerial $DeviceSerial)) { return 'failed' }
    try {
        return (Sync-QuestInsecureOriginFlag -DeviceSerial $DeviceSerial -Origins (Get-QuestLanOrigins) -HelperUrl (Get-QuestHelperUrl) -SkipConfirm:$SkipConfirm)
    } catch {
        Write-QuestLog "Flags: $($_.Exception.Message)"
        return 'failed'
    } finally { Close-QuestDevTools }
}

# ---- Quest control page (quest_tools QuestControlHost.ps1 on this PC; this repo's tiles:
# LoopSegmentsControlTiles.ps1). Get-QuestControlPort / Get-QuestControlToken / Get-QuestControlHost
# are quest_tools' (lib\QuestControl.ps1). ----

# This PC's IPv4 address on the route to the headset (quest_tools Get-QuestPcAddress): the address the
# Quest reaches the control page on. A USB serial has no address, so the route to questAdbHost, else
# to the phone (-Url), stands in.
function Get-QuestControlPcAddress {
    param([string] $DeviceSerial)
    $target = ''
    if ($DeviceSerial -notmatch '^\d{1,3}(\.\d{1,3}){3}:\d+$') {
        if ($QuestHost -match '^\d{1,3}(\.\d{1,3}){3}$') { $target = $QuestHost }
        else { try { $target = ([Uri]$Url).Host } catch {} }
    }
    return (Get-QuestPcAddress -DeviceSerial $DeviceSerial -Target $target)
}

function Get-QuestControlOrigin {
    param([string] $DeviceSerial)
    $ip = Get-QuestControlPcAddress -DeviceSerial $DeviceSerial
    if (-not $ip) { return $null }
    return ('http://{0}:{1}' -f $ip, (Get-QuestControlPort))
}

# Control page origins actually opened on the headset (%TEMP%\loopsegments-quest-control-origins.json,
# last 8). The current one is worked out from this PC's route to the headset, which changes when
# the headset moves to another network (e.g. after the phone LAN AP was restarted): the history
# delete and the tab closing use these too, so an entry from the address the page was opened on is
# still found.
$script:ControlOriginsPath = Join-Path $env:TEMP 'loopsegments-quest-control-origins.json'

function Get-QuestSavedControlOrigins {
    try { return @((Get-Content -LiteralPath $script:ControlOriginsPath -Raw -ErrorAction Stop | ConvertFrom-Json).origins | Where-Object { $_ }) } catch { return @() }
}

function Add-QuestSavedControlOrigin {
    param([string] $Origin)
    if (-not $Origin) { return }
    $list = @(@($Origin) + @(Get-QuestSavedControlOrigins | Where-Object { $_ -ne $Origin }) | Select-Object -First 8)
    try { @{ origins = $list } | ConvertTo-Json | Set-Content -LiteralPath $script:ControlOriginsPath -Encoding utf8 } catch {}
}

# The current control page origin (when the route to the headset is known) plus the saved ones.
function Get-QuestControlOrigins {
    param([string] $DeviceSerial)
    return @(@(Get-QuestControlOrigin -DeviceSerial $DeviceSerial) + @(Get-QuestSavedControlOrigins) | Where-Object { $_ } | Select-Object -Unique)
}

# Is the control page host running on this PC?
function Test-QuestControlPageRunning { return [bool](Get-QuestControlHost) }

# Open on Quest: also open the control page in its own normal tab, signed in with the page's token
# link (/s?t=, swapped for a cookie; reused if already open). Needs an open DevTools session. Never
# fails the LAN page.
$script:ControlTabOpened = $false
function Open-QuestControlTab {
    # -Force: open even with questControlPageOnQuest=false. Sets $script:ControlTabOpened.
    param([string] $DeviceSerial, [switch] $Force)
    $script:ControlTabOpened = $false
    if (-not $Force -and $script:Cfg -and $script:Cfg.Contains('questControlPageOnQuest') -and $script:Cfg.questControlPageOnQuest -eq $false) { return }
    if (-not (Test-QuestControlPageRunning)) { Write-QuestLog 'Control page: not running on this PC - not opened.'; return }
    $origin = Get-QuestControlOrigin -DeviceSerial $DeviceSerial
    if (-not $origin) { Write-QuestLog 'Control page: no PC address on the route to the headset - not opened.'; return }
    $plain = "$origin/"
    $loginUrl = '{0}/s?t={1}' -f $origin, (Get-QuestControlToken)
    try {
        # Keep-awake may have the notifications list open (proximity OFF toast); bring the browser
        # forward so the VIEW intent is not dropped behind that UI.
        Show-QuestBrowserTab -DeviceSerial $DeviceSerial
        if (Open-QuestSignedInTab -DeviceSerial $DeviceSerial -PlainUrl $plain -LoginUrl $loginUrl -Origins @($origin)) {
            $which = if ($script:QuestReusedTab) { 'reused open tab' } else { 'new tab' }
            Write-QuestLog "Control page: opened $plain in Quest browser ($which)."
            $script:ControlTabOpened = $true
            Add-QuestSavedControlOrigin -Origin $origin
            Register-QuestBrowserOrigin -Origin $origin -Owner 'quest-control'
        } else {
            # VIEW can fail to open a tab, or the tab can open on chrome-error (firewall / server down).
            $haveTab = @(Get-QuestLanTabs -Origins @($origin)).Count -gt 0
            if ($haveTab) {
                Write-QuestLog "Control page: $plain did not load on the Quest (Windows Firewall blocking port $(Get-QuestControlPort)? see quest\README.md)."
            } else {
                Write-QuestLog "Control page: Quest Browser did not open a tab for $plain (VIEW intent dropped; try Open on Quest again)."
            }
        }
    } catch {
        Write-QuestLog "Control page: $($_.Exception.Message)"
    }
}

# ---- Close Quest Browser at quit when this session started it ----
# %TEMP%\loopsegments-quest-browser-ours.json: {ours: true} once an Open on Quest found Quest Browser
# not running (so it was started for Loop Segments), {ours: false} when the first one found it
# running. The companion removes it at startup; the quit reads it.
$script:BrowserOursPath = Join-Path $env:TEMP 'loopsegments-quest-browser-ours.json'


function Test-QuestBrowserOurs {
    try { return [bool]((Get-Content -LiteralPath $script:BrowserOursPath -Raw | ConvertFrom-Json).ours) } catch { return $false }
}

# Before Open on Quest's first intent. A later click that finds the browser closed again also
# makes it ours (whatever was open before is gone by then).

# Ours = Quest Browser was not running, or was running with no tab of yours (only empty new-tab
# pages or our own LAN / control tabs, e.g. left by an earlier session, a restart or the history
# helper). A tab of yours makes it yours for the rest of the session.
function Save-QuestBrowserOurs {
    param([string] $DeviceSerial)
    $running = Test-QuestBrowserRunning -DeviceSerial $DeviceSerial
    $user = 0
    if ($running -and (Open-QuestDevTools -DeviceSerial $DeviceSerial)) {
        try {
            $origins = @(@(Get-QuestLanOrigins) + @(Get-QuestControlOrigins -DeviceSerial $DeviceSerial) + @(Get-QuestRegisteredOrigins) | Where-Object { $_ })
            $user = @(Get-QuestUserTabs -Origins $origins).Count
        } finally { Close-QuestDevTools }
    }
    $ours = ($user -eq 0)
    $had = $null
    if (Test-Path -LiteralPath $script:BrowserOursPath) { $had = Test-QuestBrowserOurs }
    # Once yours, it stays yours this session (a later click with your tabs closed does not flip it).
    if ($had -eq $false) { return }
    try { @{ ours = $ours; at = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $script:BrowserOursPath -Encoding utf8 } catch {}
    if ($had -eq $ours) { return }
    $why = if (-not $running) { 'was not running' } elseif ($ours) { 'was running with no tab of yours' } else { "had $user tab(s) of yours open" }
    Write-QuestLog ("Browser: Quest Browser {0} before Open on Quest - {1}" -f $why, $(if ($ours) { 'closed again at quit if no other tabs are left.' } else { 'left running at quit.' }))
}


# Open -Url (the phone LAN page, or any page a caller passes with -NoLanLogin) through quest_tools'
# Open-QuestPage: signed in with the phone LAN login, the control page in its own tab first (so this
# page ends up in front), an open tab on a phone LAN origin reused, and the insecure-origin flag fixed
# for every phone LAN origin when the page is not a secure context.
function Open-QuestLanTab {
    param([string] $DeviceSerial)
    Save-QuestBrowserOurs -DeviceSerial $DeviceSerial
    $lan = @(Get-QuestLanOrigins)
    return (Open-QuestPage -DeviceSerial $DeviceSerial -Url $Url -LoginUrl (Get-QuestTypedUrl) -Owner $Owner `
            -ReuseOrigins $lan -FlagOrigins $lan -HelperUrl { Get-QuestHelperUrl } -NoFlags:$NoFlags `
            -BeforeOpen { param($d) Open-QuestControlTab -DeviceSerial $d })
}

# http://<phoneLanHost>:<lanPort>/ from the companion's lan_config.json (re-read on every call, so a
# phone address change during the session is picked up), or $null.
function Get-QuestSkyboxLanUrlFromConfig {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $c = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $h = ([string]$c.phoneLanHost).Trim()
        if ([string]::IsNullOrWhiteSpace($h)) { return $null }
        $port = 8765
        if ($null -ne $c.lanPort -and [int]$c.lanPort -gt 0) { $port = [int]$c.lanPort }
        return "http://${h}:${port}/"
    } catch {
        return $null
    }
}

# The phone LAN URL to use now: from -LanConfig (the companion's lan_config.json, re-read each call)
# when given, else -Url.
function Get-QuestSkyboxCurrentLanUrl {
    $fromCfg = Get-QuestSkyboxLanUrlFromConfig -Path $LanConfig
    if ($fromCfg) { return $fromCfg }
    if (-not [string]::IsNullOrWhiteSpace($Url)) { return $Url }
    return $null
}

# Quest control page Push / Update (one run each): put server 'Loop Segments' in SKYBOX at the phone's
# current address (-LanConfig lan_config.json, else -Url) with the current LAN login, and delete the
# servers this PC added at older addresses. -OnlyIfPresent (Update): only if one is there already.
# Returns 'added' / 'updated' / 'unchanged' / 'absent' / 'not installed' / 'unreachable' / 'failed'.
function Invoke-QuestSkyboxWebDavPush {
    param([switch] $OnlyIfPresent)
    $lan = Get-QuestSkyboxCurrentLanUrl
    if (-not $lan) { Write-QuestLog 'SKYBOX: no phone LAN address (lan_config.json / -Url) - nothing pushed.'; return 'failed' }
    $login = Get-QuestLanLogin -ForUrl $lan
    if ([string]::IsNullOrEmpty($login.Password)) { Write-QuestLog 'SKYBOX: no LAN password in loop-segments-windows.json - nothing pushed.'; return 'failed' }
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) { Write-QuestLog 'SKYBOX: headset not reachable over adb - nothing pushed.'; return 'unreachable' }
    $dav = Get-QuestSkyboxWebDavUrl -LanUrl $lan
    $old = @(Get-QuestSkyboxAddedUrls)
    # Record the URL before the edit, so a kill mid-way still leaves it for the clear.
    Set-QuestSkyboxAddedUrls -Urls (@($old) + $dav)
    $res = Invoke-QuestSkyboxWebDav -DeviceSerial $dev -DavUrl $dav -User $login.User -Password $login.Password -RemoveUrls $old -OnlyIfPresent:$OnlyIfPresent
    if ($res -in @('added', 'updated', 'unchanged')) { Set-QuestSkyboxAddedUrls -Urls @($dav) }
    else { Set-QuestSkyboxAddedUrls -Urls $old }
    return $res
}

# Clear button and companion close: remove every SKYBOX Network entry of this app, in one edit:
#   - WebDAV servers this PC added (state file), and any WebDAV server at a phone address the
#     companion knows (current lan_config.json, phoneLanHost, phoneLanHosts[]; also ones added by hand)
#   - any WebDAV server named 'Loop Segments'
#   - the companion's rclone DLNA server (name rcloneDlnaName, announced by rclone)
function Invoke-QuestSkyboxWebDavClear {
    param([string] $DeviceSerial)
    $urls = [System.Collections.Generic.List[string]]::new()
    foreach ($u in @(Get-QuestSkyboxAddedUrls)) { $urls.Add($u) }
    $lan = Get-QuestSkyboxCurrentLanUrl
    if ($lan) { $urls.Add((Get-QuestSkyboxWebDavUrl -LanUrl $lan)) }
    $port = 8765
    $dlnaName = 'Loop Segments'
    if ($script:Cfg) {
        try { if ([int]$script:Cfg.lanPort -gt 0) { $port = [int]$script:Cfg.lanPort } } catch {}
        if (-not [string]::IsNullOrWhiteSpace([string]$script:Cfg.rcloneDlnaName)) { $dlnaName = ([string]$script:Cfg.rcloneDlnaName).Trim() }
        $hostsRaw = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$script:Cfg.phoneLanHost)) { $hostsRaw += [string]$script:Cfg.phoneLanHost }
        foreach ($raw in @($script:Cfg.phoneLanHosts)) { if ($null -ne $raw) { $hostsRaw += $raw } }
        foreach ($raw in $hostsRaw) {
            try {
                $e = ConvertTo-LoopSegmentsPhoneHostEntry -Raw $raw -DefaultPort $port
                if ($e -and $e.Host) { $urls.Add(('webdav://{0}:{1}/' -f $e.Host, $e.Port)) }
            } catch {}
        }
    }
    $list = @($urls | Where-Object { $_ } | Select-Object -Unique)
    $res = Invoke-QuestSkyboxWebDav -DeviceSerial $DeviceSerial -RemoveUrls $list -RemoveNamedWebDav -RemoveDlnaName $dlnaName
    if ($res -in @('removed', 'absent', 'not installed')) { Set-QuestSkyboxAddedUrls -Urls @() }
    return $res
}

# -StatusFile: progress / result word for the caller (companion sink, Quest control page).
function Set-QuestOpenStatus {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($StatusFile)) { return }
    try { Set-Content -LiteralPath $StatusFile -Value $Value -Encoding ascii } catch {}
}

# ---- After-quit history helper: quest_tools lib\QuestHistoryRetry.ps1 (Invoke-QuestHistoryRetry.ps1) ----

# Hand a failed (or unreachable) history delete to quest_tools' after-quit helper, with Loop Segments'
# settings: questHistoryRetryMinutes (120; 0 = no helper), questClearHistoryFallback (once per helper
# run), questWifiOffOnExit (Wi-Fi off after its delete), the phone helper page with its PC fallback.
# It stops (dropping the delete) when the companion starts again: that session's quit deletes the
# same origins. Its after-script runs the quit's held phone LAN AP bounce
# (Invoke-LoopSegmentsHeldWifiBounce.ps1; QuestCompanionHooks.ps1 Request-QuestDeferredWifiBounce).
# -Proximity: the quit could not reach the headset, so the sensor override may still be on.
# Returns $true when handed over.
function Start-LoopSegmentsHistoryRetry {
    param([string[]] $Origins, [switch] $CloseTabs, [switch] $Proximity, [switch] $CloseBrowser)
    $mins = 120
    if ($script:Cfg -and $script:Cfg.Contains('questHistoryRetryMinutes')) { $mins = [int]$script:Cfg.questHistoryRetryMinutes }
    return (Start-QuestHistoryRetry -Origins $Origins -Minutes $mins -CloseTabs:$CloseTabs -Proximity:$Proximity -CloseBrowser:$CloseBrowser `
            -HelperUrl (Get-QuestPhoneHelperUrl) -HelperFallbackPort ((Get-QuestControlPort) + 1) -FallbackRange (Get-QuestHistoryFallbackRange) `
            -WifiOff:(Test-QuestWifiOffWanted) -StopIfCommandLine 'Run-PCloudWebCompanion\.ps1|_run_chromium\.ps1' `
            -AfterScript (Join-Path $PSScriptRoot 'Invoke-LoopSegmentsHeldWifiBounce.ps1'))
}

# Tab closing, history delete, Recently closed sweep: quest_tools lib\QuestCleanup.ps1
# (Invoke-QuestBrowserCleanup, Clear-QuestHistoryAndClosed -HelperUrl (Get-QuestHelperUrl)).

# questWifiOffOnExit (default true): switch the headset's Wi-Fi off, so a sleeping headset does not
# drain its battery on Wi-Fi and does not hop to another network when the quit's AP bounce reboots
# the router. adb (over that Wi-Fi) drops right after. Wireless debugging comes back on its own (new
# port, found over mDNS) once Wi-Fi is switched on again in the headset's quick settings.
# Invoke-QuestWifiOff (quest_tools) does it; this decides whether.
function Test-QuestWifiOffWanted {
    $on = $true
    if ($script:Cfg -and $script:Cfg.Contains('questWifiOffOnExit')) { $on = [bool]$script:Cfg.questWifiOffOnExit }
    return $on
}


# questClearHistoryFallback: the Clear browsing data range (history only) cleared when the selective
# delete fails, at quit and in the after-quit helper. '' = no fallback.
function Get-QuestHistoryFallbackRange {
    $fbRange = 'day'
    if ($script:Cfg -and $script:Cfg.Contains('questClearHistoryFallback')) {
        $fbRaw = ([string]$script:Cfg.questClearHistoryFallback).Trim().ToLowerInvariant()
        if (@('', 'none', 'off', 'false') -contains $fbRaw) { $fbRange = '' }
        elseif (@('hour', 'day', 'week', 'fourweeks', 'all') -contains $fbRaw) { $fbRange = $fbRaw }
        else { Write-QuestLog "History: questClearHistoryFallback '$fbRaw' unknown - using 'day'." }
    }
    return $fbRange
}

# Every origin a -ClearHistory closes and deletes: the phone LAN page, the control page, and every
# origin any project registered in quest_tools' shared list (QuestOrigins.ps1), e.g. the
# 3d_playlist_local XR page and its extra history origins.
function Get-QuestCleanupOrigins {
    param([string] $DeviceSerial)
    return @(@(Get-QuestLanOrigins) + @(Get-QuestControlOrigins -DeviceSerial $DeviceSerial) +
        @(Get-QuestRegisteredOrigins) | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd('/') } | Select-Object -Unique)
}

$script:Adb = Find-QuestAdbExe
if (-not $script:Adb) {
    Write-QuestLog 'adb not found (winget install Google.PlatformTools, or set questAdbExe) - Quest LAN tab disabled.'
    exit 2
}
$script:LastConnectMsg = ''
$script:SendLanLogin = (-not $NoLanLogin) -and [bool](Get-Command Get-LoopSegmentsWebDAVCredentials -ErrorAction SilentlyContinue)
if ($EnableProximity) { exit (Invoke-QuestEnableProximity) }
if ($DisableProximity) { exit (Invoke-QuestDisableProximity) }
if ($ToggleProximity) { exit (Invoke-QuestToggleProximity) }
if ($WifiOff) {
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) { Write-QuestLog 'Wi-Fi: headset not reachable over adb - skipped.'; exit 1 }
    $w = Invoke-QuestWifiOff -DeviceSerial $dev
    if ($w -eq 'off') { exit 0 } else { exit 3 }
}
if ($KeepAwakeSession) {
    # The companion's keep-awake (no -RestoreProximity) also keeps the phone serving while the Quest plays.
    # It also closes the companion once the phone's Keep Alive has run out (Invoke-CompanionCloseOnKeepAliveExpiry).
    $tick = if ($RestoreProximity) { $null } else {
        {
            try { Invoke-PhoneKeepAliveOnQuestPlayback } catch { Write-QuestLog "Keep Alive: playback check failed: $($_.Exception.Message)" }
            Invoke-CompanionCloseOnKeepAliveExpiry
        }
    }
    exit (Invoke-QuestKeepAwakeSession -ParentPid $ParentPid -RestoreProximity:$RestoreProximity -OnTick $tick)
}
if ($SkyboxPush -or $SkyboxUpdate) {
    $res = Invoke-QuestSkyboxWebDavPush -OnlyIfPresent:$SkyboxUpdate
    Set-QuestOpenStatus $res
    if ($res -eq 'unreachable') { exit 1 }
    if ($res -eq 'failed') { exit 3 }
    exit 0
}
if ($ClearSkyboxWebDav -and -not $ClearHistory) {
    # Companion close without a LAN URL, or a manual run; -EnableProximityAfter still applies.
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) { Write-QuestLog 'SKYBOX: headset not reachable over adb - skipped.'; Set-QuestOpenStatus 'unreachable'; exit 1 }
    $sky = Invoke-QuestSkyboxWebDavClear -DeviceSerial $dev
    Set-QuestOpenStatus $sky
    $prox = if ($EnableProximityAfter) { if ((Invoke-QuestEnableProximity) -eq 0) { 'on' } else { 'failed' } } else { 'skipped' }
    if ($sky -eq 'failed' -or $prox -eq 'failed') { exit 3 }
    exit 0
}
if ([string]::IsNullOrWhiteSpace($Url)) {
    Write-QuestLog '-Url is required for this mode.'
    exit 2
}
if ($TestHelperVisit) {
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) { Write-Host 'headset not reachable over adb'; exit 1 }
    if (-not (Open-QuestDevTools -DeviceSerial $dev)) { exit 3 }
    $out = [ordered]@{}
    try {
        $helper = Get-QuestHelperUrl
        $origins = @(@(Get-QuestLanOrigins) + @(Get-QuestControlOrigins -DeviceSerial $dev) | Where-Object { $_ } | Select-Object -Unique)
        $seen = {
            $r = Clear-QuestBrowserHistory -DeviceSerial $dev -Origins $origins -BudgetSec 10 -FallbackRange '' -ListOnly
            if ($r -and $r.PSObject.Properties['items']) { return (@(@($r.items) | Where-Object { $_.ours }).Count) } else { return -1 }
        }
        $go = {
            param($tab, [string] $u, [scriptblock] $match)
            [void](Invoke-QuestCdp -Tab $tab -Method 'Page.navigate' -Params @{ url = $u } -TimeoutSec 8)
            $t = Wait-QuestTabUrl -Id $tab.id -TimeoutSec 8 -Match $match
            if ($t) { return $t } else { return $tab }
        }
        foreach ($mode in 'ntp-direct', 'via-blank') {
            $tab = Get-QuestTabs | Where-Object { ([string]$_.url) -like 'chrome://panel-app-nav/ntp*' -or ([string]$_.url) -eq 'about:blank' } | Select-Object -First 1
            if (-not $tab) { $out[$mode] = 'no new-tab / blank tab'; continue }
            $startUrl = [string]$tab.url
            if ($mode -eq 'via-blank') { $tab = & $go $tab 'about:blank' { param($x) $x -eq 'about:blank' } }
            $tab = & $go $tab $helper { param($x) $x -like 'http*' }
            $loaded = [string]$tab.url
            Start-Sleep -Seconds 3
            $n = & $seen
            $out[$mode] = "start $startUrl, loaded '$loaded', entries on our origins after 3 s: $n"
            # Delete what it made and go back to the new-tab page for the next mode.
            [void](Clear-QuestBrowserHistory -DeviceSerial $dev -Origins $origins -BudgetSec 10 -FallbackRange '')
            $tab = Get-QuestTabs | Where-Object { $_.id -eq $tab.id } | Select-Object -First 1
            if ($tab) { $tab = & $go $tab 'chrome://panel-app-nav/ntp' { param($x) $x -like 'chrome://*' }; try { [void](Invoke-QuestCdp -Tab $tab -Method 'Page.resetNavigationHistory' -TimeoutSec 5) } catch {} }
        }
    } finally { Close-QuestDevTools }
    $out | ConvertTo-Json
    exit 0
}
if ($ProbeRecentlyClosed) {
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) { Write-Host 'headset not reachable over adb'; exit 1 }
    if (-not (Open-QuestDevTools -DeviceSerial $dev)) { exit 3 }
    try {
        $tabs = @(Get-QuestTabs | ForEach-Object { [ordered]@{ id = $_.id; url = (ConvertTo-QuestBareUrl ([string]$_.url)) -replace '\?.*$', ''; title = [string]$_.title } })
        $ui = Get-QuestBrowserUi
        $probe = $null
        if ($ui) {
            $js = "(async () => {`n$($script:QuestClosedCommonJs)`n" + @'
  if (!store) return JSON.stringify({ ok: false, error: 'no store' });
  // Ask the browser for the list first (the menu does that when it opens), then read it.
  const before = (store.getState().history.recentlyClosedTabs || []).length;
  let asked = false; try { if (menu) { Object.getPrototypeOf(menu).requestRecentlyClosedTabsData.call(menu); asked = true; } } catch (e) {}
  await new Promise(r => setTimeout(r, 1500));
  const strip = u => { try { const x = new URL(u); return x.origin + x.pathname; } catch (e) { return String(u); } };
  const rc = (store.getState().history.recentlyClosedTabs || []).map(e => ({ type: e.type, sessionId: e.sessionId, keys: Object.keys(e), tabs: (e.tabs || []).map(t => ({ url: strip(String(t.url || '')), q: (() => { try { return new URL(String(t.url || '')).search.slice(0, 40); } catch (x) { return ''; } })(), title: String(t.title || '').slice(0, 50), keys: Object.keys(t) })) }));
  const protoNames = o => { const r = new Set(); let p = o ? Object.getPrototypeOf(o) : null; for (let i = 0; p && i < 4; i++, p = Object.getPrototypeOf(p)) Object.getOwnPropertyNames(p).forEach(n => r.add(n)); return [...r]; };
  const menuMethods = menu ? protoNames(menu).filter(n => /closed|recent|remove|delete|clear|restore/i.test(n)) : [];
  const menuSrc = {}; if (menu) { for (const n of ['requestRecentlyClosedTabsData', 'handleReopenClosedTab', 'handleReopenClosedWindow']) { try { menuSrc[n] = String(Object.getPrototypeOf(menu)[n]).slice(0, 700); } catch (e) {} } }
  let delSrc = ''; walk(f => { const sn = f.stateNode; try { if (sn && sn.props && typeof Object.getPrototypeOf(sn).handleDelete === 'function') { delSrc = String(Object.getPrototypeOf(sn).handleDelete).slice(0, 700); return false; } } catch (e) {} });
  const globals = Object.keys(window).filter(k => /webui|chrome|native|bridge|send|oculus|meta/i.test(k)).slice(0, 40);
  const tags = [...document.querySelectorAll('script,link')].map(e => e.outerHTML.slice(0, 200));
  const href = location.href;
  // Other components with closed-tab related methods.
  const comps = {}; walk(f => { const sn = f.stateNode; try { if (sn && sn.props) { const m = protoNames(sn).filter(n => /closed|recent/i.test(n)); if (m.length) comps[(sn.constructor && sn.constructor.name) || '?'] = m; } } catch (e) {} });
  // webui actions the page knows (strings), to see if a "remove recently closed" exists.
  let actions = [], srcs = [];
  try {
    srcs = [...new Set([...document.querySelectorAll('script[src],link[href]')].map(e => e.src || e.href).filter(u => /\.m?js(\?|$)/.test(u)).concat(performance.getEntriesByType('resource').map(e => e.name).filter(n => /\.m?js(\?|$)/.test(n))))];
    const texts = [[...document.scripts].map(s => s.textContent || '').join(' ')];
    return (async () => {
      for (const u of srcs) { try { texts.push(await (await fetch(u)).text()); } catch (e) {} }
      const all = texts.join(' ');
      actions = [...new Set((all.match(/webui_action_[a-zA-Z_]+/g) || []))];
      const near = [...new Set((all.match(/[A-Za-z_]*(?:[Rr]ecently[_]?[Cc]losed|[Tt]ab[Rr]estore|recently_closed|ClosedTab)[A-Za-z_]*/g) || []))].slice(0, 80);
      const sends = [...new Set((all.match(/chrome\.send\(\s*["'][A-Za-z_]+["']/g) || []))].slice(0, 120);
      actions = actions.concat(sends);
      return JSON.stringify({ ok: true, asked, before, historyKeys: Object.keys(store.getState().history || {}), recentlyClosed: rc, menuMethods, comps, actions, near, srcs, menuSrc, delSrc, globals, inlineLen: texts[0].length, tags, href, bundleHits: (() => { const out = []; const re = /webui_action_[a-zA-Z_]+/g; let m; while ((m = re.exec(all)) && out.length < 300) out.push(m[0]); return [...new Set(out)]; })(), totalLen: all.length });
    })();
  } catch (e) {}
  return JSON.stringify({ ok: true, asked, before, historyKeys: Object.keys(store.getState().history || {}), recentlyClosed: rc, menuMethods, comps, actions });
})()
'@
            try { $probe = Invoke-QuestEval -Tab $ui -Expression $js -TimeoutSec 10 | ConvertFrom-Json } catch { $probe = @{ ok = $false; error = $_.Exception.Message } }
        }
    } finally { Close-QuestDevTools }
    @{ tabs = $tabs; ui = [bool]$ui; probe = $probe } | ConvertTo-Json -Depth 8
    exit 0
}
if ($ListHistory) {
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) { Write-Host 'headset not reachable over adb'; exit 1 }
    if (-not (Open-QuestDevTools -DeviceSerial $dev)) { exit 3 }
    try {
        $origins = @(Get-QuestCleanupOrigins -DeviceSerial $dev)
        $r = Clear-QuestBrowserHistory -DeviceSerial $dev -Origins $origins -BudgetSec 30 -FallbackRange '' -ListOnly
    } finally { Close-QuestDevTools }
    @{ matchedOrigins = $origins; result = $r } | ConvertTo-Json -Depth 6
    exit 0
}
if ($ResetFlags) {
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) { Write-QuestLog 'Flags reset: headset not reachable over adb - skipped.'; exit 1 }
    $wasRunning = Test-QuestBrowserRunning -DeviceSerial $dev
    if (-not (Open-QuestDevTools -DeviceSerial $dev)) { exit 3 }
    try {
        $res = Reset-QuestBrowserFlags -DeviceSerial $dev -HelperUrl (Get-QuestHelperUrl)
        # Leave no trace: the helper tab's phone page in history, and its chrome://flags / new-tab /
        # blank items in Recently closed. Then close Quest Browser again if the reset started it.
        if ($res -eq 'reset') {
            Start-Sleep -Seconds 1
            [void](Clear-QuestHistoryAndClosed -DeviceSerial $dev -Origins @(Get-QuestLanOrigins) -BudgetSec 25 -FallbackRange '' -HelperUrl (Get-QuestHelperUrl))
            if (-not $wasRunning) { [void](Close-QuestBrowserIfEmpty -DeviceSerial $dev) }
        }
    } finally { Close-QuestDevTools }
    if ($res -eq 'reset') { exit 0 } else { exit 3 }
}
if ($EnsureFlags -or $ClearHistory) {
    # Headset only needs to be on adb (awake or not); never waits.
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) {
        Write-QuestLog ("{0}: headset not reachable over adb - skipped." -f $(if ($ClearHistory) { 'History' } else { 'Flags' }))
        if ($ClearHistory -and -not $SkipHistoryClear) {
            # Close the tabs, delete the entries and reset the sensor once the headset is back.
            $origins = @(Get-QuestCleanupOrigins -DeviceSerial '')
            # The helper closes Quest Browser after its delete when only empty tabs are left (as below).
            [void](Start-LoopSegmentsHistoryRetry -Origins $origins -CloseTabs:$CloseLanTabs -Proximity:$EnableProximityAfter -CloseBrowser:$CloseLanTabs)
        }
        Remove-Item -LiteralPath $script:BrowserOursPath -Force -ErrorAction SilentlyContinue
        exit 1
    }
    if ($ClearHistory) {
        # Companion close, in this order: LAN tabs, history (both within ~30 s of start), then the
        # proximity sensor. Each step logs its duration.
        $since = { ([DateTime]::UtcNow - $script:StartedAt).TotalSeconds }
        Write-QuestLog ("Cleanup: headset on adb after {0:0.0} s." -f (& $since))
        $res = 'skipped'
        # Close Quest Browser afterwards (with -CloseLanTabs) whenever no tab of yours is left: only
        # empty new-tab pages and the blank page kept for the History list. Close-QuestBrowserIfEmpty
        # checks that and leaves it running otherwise, so who started it does not matter (it used to:
        # a browser this session never opened stayed up on a blank tab, e.g. when the headset was off
        # adb at Open on Quest / a 3d_playlist_local workflow start).
        $closeBrowser = [bool]$CloseLanTabs
        $browserRes = 'kept'
        if ($CloseLanTabs -or -not $SkipHistoryClear) {
            # quest_tools Invoke-QuestBrowserCleanup, one DevTools session: tabs on our pages (phone LAN
            # page, control page on this PC, plus the shared origin list: every project's pages), the history delete within ~28 s of start, then the
            # browser closed when only empty pages are left. Usually nobody is wearing the headset at
            # quit, and then Quest Browser does not answer: the delete goes to the after-quit helper.
            $script:CleanupCloseBrowser = $closeBrowser
            $c = Invoke-QuestBrowserCleanup -DeviceSerial $dev -Origins @(Get-QuestCleanupOrigins -DeviceSerial $dev) `
                -HelperUrl $(if (-not $SkipHistoryClear) { Get-QuestHelperUrl } else { '' }) `
                -CloseTabs:$CloseLanTabs -SkipHistory:$SkipHistoryClear -BudgetUntil $script:StartedAt.AddSeconds(28) `
                -FallbackRange (Get-QuestHistoryFallbackRange) -CloseBrowser:$closeBrowser `
                -OnHistoryFailed { param($o) Start-LoopSegmentsHistoryRetry -Origins $o -CloseBrowser:$script:CleanupCloseBrowser }
            $res = if ($c.DevTools) { $c.History } else { 'failed' }
            $browserRes = $c.Browser
            if (($res -eq 'cleared' -or $res -eq 'fallback') -and (Test-Path -LiteralPath $script:QuestHistoryPendingPath)) {
                Remove-Item -LiteralPath $script:QuestHistoryPendingPath -Force -ErrorAction SilentlyContinue
                Write-QuestLog 'History: the postponed delete is done too (pending file removed).'
            }
            if ($c.DevTools) { Remove-Item -LiteralPath $script:BrowserOursPath -Force -ErrorAction SilentlyContinue }
        }
        $sky = 'skipped'
        if ($ClearSkyboxWebDav) {
            # After the history clear (it has a time budget), before the sensor goes back on.
            $t0 = [DateTime]::UtcNow
            $sky = Invoke-QuestSkyboxWebDavClear -DeviceSerial $dev
            Write-QuestLog ("SKYBOX step: {0} ({1:0.0} s)." -f $sky, ([DateTime]::UtcNow - $t0).TotalSeconds)
        }
        $prox = 'skipped'
        if ($EnableProximityAfter) {
            # Always after the history clear: once the sensor is on, an unworn headset may sleep.
            $t0 = [DateTime]::UtcNow
            $prox = if ((Invoke-QuestEnableProximity) -eq 0) { 'on' } else { 'failed' }
            Write-QuestLog ("Proximity step: {0} ({1:0.0} s)." -f $prox, ([DateTime]::UtcNow - $t0).TotalSeconds)
        }
        # Wi-Fi off last (questWifiOffOnExit). Not while the history delete is pending: the after-quit
        # helper needs the Wi-Fi, and switches it off itself after its delete.
        $wifi = 'kept'
        if (Test-QuestWifiOffWanted) {
            if ($res -eq 'postponed' -or $res -eq 'failed') {
                Write-QuestLog 'Wi-Fi: left on - the history delete is not done (the after-quit helper switches it off after its delete).'
            } else {
                $wifi = Invoke-QuestWifiOff -DeviceSerial $dev
            }
        }
        Write-QuestLog ("Cleanup: finished {0:0.0} s after start (history {1}, browser {2}, SKYBOX {3}, proximity {4}, Wi-Fi {5})." -f (& $since), $res, $browserRes, $sky, $prox, $wifi)
        $historyBad = ($res -eq 'failed') -or (($res -eq 'skipped') -and (-not $SkipHistoryClear))
        if ($historyBad -or ($prox -eq 'failed') -or ($sky -eq 'failed')) { exit 3 }
        if ($res -eq 'postponed') { exit 4 }
        exit 0
    }
    $res = Invoke-QuestFlagSync -DeviceSerial $dev
    if ($res -eq 'failed') { exit 3 } else { exit 0 }
}
# Default: open the page once (the Open on Quest button). An asleep / unreachable headset is
# polled for up to -WaitMinutes and the page opens when it wakes.
Write-QuestLog ("Open start: url={0} adb={1} host={2} port={3} serial={4}" -f $Url, $script:Adb, $QuestHost, $Port, $Serial)
$w = Wait-QuestHeadsetAwake -WaitMinutes $WaitMinutes -PollSeconds $PollSeconds -OnStatus { param($s) Set-QuestOpenStatus $s }
if (-not $w.Serial) { exit 1 }
Set-QuestOpenStatus 'opening'
if (Open-QuestLanTab -DeviceSerial $w.Serial) {
    Set-QuestOpenStatus 'opened'
    Invoke-PhoneKeepAliveExtendAfterQuestOpen
    exit 0
}
exit 3
