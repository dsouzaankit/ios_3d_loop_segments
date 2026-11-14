# Quest: Open on Quest, control page, flags, history, SKYBOX

The PC companion drives **Quest Browser** over **adb over Wi-Fi** and the browser's DevTools socket (the one `chrome://inspect` uses). Everything goes through [`Watch-LoopSegmentsQuestLanTab.ps1`](Watch-LoopSegmentsQuestLanTab.ps1) (helpers in [`QuestDevTools.ps1`](QuestDevTools.ps1), companion hooks in [`QuestCompanionHooks.ps1`](QuestCompanionHooks.ps1)). Log: `%TEMP%\loopsegments-quest-lantab.log`.

| When | What | Setting |
|------|------|---------|
| **Open on Quest** click (PC LAN page) | Open the **Quest control page** in its own tab, then the LAN page in a **normal tab, signed in** (in front), then check the flag in that tab (below) | `questSendLanLogin`, `questIncognito`, `questControlPageOnQuest` |
| Companion **startup**, until close | Keep the headset **awake**: proximity sensor held off once the headset is on adb | `questKeepAwakeDuringSession` |
| Companion **startup**, until close | Serve the **Quest control page** on this PC's LAN address, signed in: **SKYBOX Push / Update / Clear** buttons and **Measure LAN** (PC ↔ phone bandwidth) | `questControlPage`, `questControlPort`, `questSkyboxWebDav` |
| Companion **close** (normal finish and the console-X watchdog) | Stop the control page, close Quest Browser **tabs on the phone LAN page and the control page**, delete the **history entries on those two** and sweep their *Recently closed* items, close Quest Browser itself if Open on Quest started it and no other tabs are left (other history is kept; if nobody is wearing the headset, a background helper does it once you put it on, within 2 h: [After-quit history helper](#after-quit-history-helper)), **remove the Loop Segments entries from SKYBOX** (phone WebDAV servers and the rclone DLNA entry), then turn the **proximity sensor back on**, open **Settings > Wi-Fi** and switch the headset's **Wi-Fi off** ([Wi-Fi off at close](#wi-fi-off-at-close)) | `questCloseLanTabsOnExit`, `questClearHistoryOnExit`, `questSkyboxWebDav`, `questKeepAwakeDuringSession`, `questWifiOffOnExit` |

Startup and close steps are skipped (and logged) when the headset is not on adb. **Open on Quest** waits instead (below).

**Headset asleep or off adb when you click:** the click is queued. The button says *Queued: opens on Quest when the headset wakes (until HH:MM)*, and the companion keeps polling for **7 minutes**; when the headset wakes and adb is back it opens the page once. It checks about every **5 s** (`-PollSeconds`, at least 2 s); while the headset is unreachable each check first tries to reconnect (`questAdbHost`, then mDNS + `adb connect`), so the real gap is a bit longer. The page usually opens 5-10 s after the headset wakes. Clicking again while one is queued just shows it. The wait ends when the page opens, after 7 minutes (*Quest did not wake ... - nothing opened*), or when the companion quits.

## Open on Quest: normal tab, signed in

1. **One tab:** if a tab on the phone LAN page is already open (LAN page or `/xr`), the browser is brought to the front and that tab is reused; extra LAN tabs are closed. A reused tab must answer DevTools within 5 s: tabs Quest Browser restored after it was stopped (force-stop, or closed from the headset) can sit unloaded, or on a login prompt (the stop also drops the cached LAN login), and are closed and opened fresh instead (`closed 1 open tab(s) ... that did not answer`). After opening, empty new-tab pages are closed (`Closed N empty new-tab page(s) ...`): a cold start can bring back extra Quest Browser windows, each on an empty new tab, because Android keeps their records across a force-stop (seen: two windows after a quit's force-stop); a window left with no tab closes with it. Your own tabs are not touched. Otherwise a VIEW intent for `http://<phone>:8765/` (retried: the browser sometimes drops the first one) opens a new normal tab at the login prompt. Reusing an `/xr` tab replaces the XR player with the LAN page.
2. Over DevTools, that tab is sent to `http://admin:<password>@<phone>:8765/` (the browser caches the LAN login), then back to the plain URL, and its back/forward list is reset so **Back** never leads to the URL with the password.
3. The page is signed in, its URL has no password, `fetch()` works (`status_lists.json`), and **WebXR immersive VR/AR is available**. If the tab ends on Chromium's error page (phone app closed or phone off Wi-Fi), the button reports a failure instead of "Opened".

Why not a private tab: **Quest Browser disables immersive WebXR in private tabs** (`isSessionSupported("immersive-vr")` is false there and true in a normal tab), so the XR player cannot enter VR from one. `"questIncognito": true` (or `-PrivateTab`) still opens a private tab instead (Chromium `IncognitoTabLauncher` + typed URL; falls back to a normal tab). Why the reload: a page whose URL contains `user:pass@` cannot `fetch()` (Chromium refuses URLs with credentials).

The password comes from `webdavPassword` in `windows\loop-segments-windows.json`, or from the matching `phoneLanHosts[].webdavPassword`. It is percent-encoded, read by the script itself (never on a command line), and never logged. Chromium does not keep the `user:pass@` form in browsing history. `"questSendLanLogin": false` (or `-NoLanLogin`) opens the plain URL and you sign in as `admin` / the app password on the headset.

## chrome://flags: insecure origin as secure

Quest WebXR over LAN `http://` needs `chrome://flags/#unsafely-treat-insecure-origin-as-secure` **Enabled** with the phone's origin listed. A page on a listed origin has `window.isSecureContext` true (and `navigator.xr`); on any other `http://` origin it is false. So after Open on Quest opens the LAN tab, the script reads `isSecureContext` in that tab over DevTools: **true = done**, with no `chrome://flags` visit (nothing extra in history or *Recently closed*, about 5 s per click instead of ~40 s). Only when it is **false** does it open `chrome://flags` on a helper tab (a no-login phone page, `/xr-assets/aframe.min.js`, closed afterwards) and fix the flag; then it opens the LAN page again. The companion no longer checks the flag at startup (there is no LAN tab to read then); the first Open on Quest does it. If a phone LAN origin is missing (`phoneLanHost` / `phoneLanHosts` with `lanPort`, plus the companion's current phone address) it **adds** it, keeping the origins already there. It then enables the flag, **restarts Quest Browser** (flags apply only after a restart), and, for Open on Quest, confirms it by reading `isSecureContext` again in the reopened LAN tab (`isSecureContext=True`; tested: the whole click took 12 s with the restart); `-EnsureFlags`, which has no LAN tab, reopens `chrome://flags` after the restart to confirm instead. Nothing changes and nothing restarts when the flag already covers every origin. **The restart closes open Quest Browser tabs** (Quest does not restore them), which is why the LAN page is opened again afterwards. Manual run through `chrome://flags`: `-EnsureFlags`.

**Reset all flags:** run [`Reset-QuestBrowserFlags.ps1`](Reset-QuestBrowserFlags.ps1) (`windows\quest\`; or `Watch-LoopSegmentsQuestLanTab.ps1 -Url ... -ResetFlags`). It does `chrome://flags` *Reset all* on the headset (the page's own `resetAllFlags`), restarts Quest Browser (which closes its open tabs) and checks that the insecure-origin flag is back to *Default* (not enabled) afterwards; its origin list text survives *Reset all*, which does nothing while the flag is off. Then it cleans up after itself like the quit: deletes its helper page from history, sweeps its *Experiments* / new-tab / blank items out of *Recently closed*, and closes Quest Browser again if it was not running before the reset. Tested: about 20 s once the headset was on adb, flag `enabled=True` → `enabled=False`; from a closed browser: 4 *Recently closed* items swept and the browser closed again. That flag is reset too, so WebXR on the LAN page is off until the next Open on Quest, which finds `isSecureContext` false and sets it again (one more browser restart). Needs the phone LAN page up (its helper tab starts on a phone page) and the headset worn; if the headset is not on adb yet it keeps trying every 5 s for up to 2 minutes (`-WaitSec`). Exit codes 0 reset, 1 headset not on adb, 2 no adb, 3 failed.

## Keep the headset awake during the session

Deleting the Loop Segments history at quit needs the headset on adb with Quest Browser answering. An asleep Quest stays on Wi-Fi and adb only for a while (how long is up to the Quest's power management) and then drops off; even before that, Quest Browser does not answer while it sleeps. So while the companion runs, a hidden job holds the **proximity sensor off** (`am broadcast -a com.oculus.vrpowermanager.prox_close`: the headset acts as if worn and does not sleep when you take it off). It checks about every 20 s and applies the override as soon as the headset is on adb **and awake**, and again after a headset reboot (a reboot clears it).

**A sleeping headset is left alone.** For a while after it goes to standby the headset stays on Wi-Fi and wireless adb, and `prox_close` there means "just put on": it wakes it (`transition from STANDBY to HEADSET_MOUNTED` in `dumpsys vrpowermanager`). So a companion started soon after a quit used to light up a headset lying on the desk. Now the job reads `mWakefulness` first and, unless it is `Awake`, only logs `Keep-awake: headset asleep (Asleep) - not waking it`; the override goes on within ~20 s of you putting the headset on (which wakes it).

**Awake is not the same as in use.** With the override on, a headset lying still stays awake but goes **idle** after about a minute (`Device idle state` in `dumpsys vrpowermanager`), and while it is idle Quest Browser's own UI **often** does not answer: no history list, no clear dialog, no new tabs from intents. Not always, and idle time alone does not decide it: the quit's history delete failed 35 min into idle (`history query never answered`) but worked 20 min into idle on another quit (`cleared` in 1.2 s, nobody wearing the headset), and new tabs from intents also opened on an idle headset. What differs is not known yet; the browser had been started fresh 15 min before the working quit, and had run all afternoon before the failing one. Pages in tabs that are already open answer: DevTools can navigate them, run script in them and close them. So Open on Quest works on an idle headset when the LAN and control tabs are already open (`reused open tab`: seen opening signed in, `isSecureContext` read, 4 min into idle), while a click that needs new tabs may stall. SKYBOX edits and the sensor also still work. (A `Page.navigate timeout` in the log usually means the phone's LAN page is down, not that the headset is idle: navigating to a page that does not answer times out by itself.) That is why the history delete at quit often fails when nobody is wearing the headset; see [After-quit history helper](#after-quit-history-helper).

**Reading the headset state.** Three `dumpsys` fields, each used for something different:

| Field | Values | Meaning | Read by |
|---|---|---|---|
| `mWakefulness` (`dumpsys power`) | `Awake` / `Asleep` / `Dozing` | Display on or off | Open on Quest (open now or queue), keep-awake (never `prox_close` a headset that is not `Awake`) |
| `Virtual proximity state` (`dumpsys vrpowermanager`) | `CLOSE` / `DISABLED` | The override: `CLOSE` = `prox_close` sent (pretend a face is there), `DISABLED` = real sensor (`automation_disable`, `-EnableProximity`) | Keep-awake (re-apply after a reboot), `-EnableProximity` (confirm) |
| `State` + `Device idle state` (`dumpsys vrpowermanager`) | `HEADSET_MOUNTED` / standby; `Idle` / `Not idle` | The power manager's result, driven by the real or virtual sensor; idle = no motion for about a minute | After-quit helper: worn = `HEADSET_MOUNTED` **and** `Not idle` |

With the override `CLOSE`, `State` is always `HEADSET_MOUNTED`, even on the desk, so during a session only `Not idle` tells worn from lying still. Headset on but not worn during a session: `Awake`, `CLOSE`, `HEADSET_MOUNTED`, `Idle`.

**Why it keeps checking:** one `prox_close` at startup would not last the session. The headset is often asleep or off adb when the companion starts, a reboot (also an OS update) clears the override, and anything else can turn the sensor back on (`Set-QuestProximitySensor.ps1 -State On`); adb has no event for "headset connected" or "sensor changed", so the job asks. A check is cheap: with the headset on adb it is `adb devices -l` plus one `dumpsys vrpowermanager`, and nothing is sent while the state is already `CLOSE`; with the headset away it also tries mDNS and `adb connect`, with short timeouts. The 20 s is how long the sensor can stay live after the headset shows up or reboots: taken off in that window, it can fall asleep before the job catches it. The flip side: a manual **On** while the companion runs is undone within ~20 s.

Cleanup, on a normal quit and on console X (the watchdog), stops that job and starts **one background process** that closes the LAN tabs, **deletes the Loop Segments history entries** (the headset is still awake), then **turns the sensor back on**. The companion closes Chromium and syncs the profile meanwhile, and waits for that process (at most 40 s from its start) before the Wi-Fi probe / router restart, which would drop the Quest's adb. Each step logs its duration (`Tabs: ... (0.4 s)`, `History step: ...`, `Proximity step: ...`, `Cleanup: finished ... s after start`). The sensor is turned back on even if the history clear failed (`am broadcast -a com.oculus.vrpowermanager.automation_disable`, checked against `dumpsys vrpowermanager`: `Virtual proximity state: DISABLED`).

Things this does not cover: pressing the power button or a flat battery still sleeps the headset. If the PC crashes or both companion processes are killed, nothing turns the sensor back on: run `-EnableProximity` (or `Set-QuestProximitySensor.ps1`, below), or reboot the headset. While the override is on, the display stays lit when the headset is off your head (battery, and keep the lenses out of direct sunlight). `"questKeepAwakeDuringSession": false` turns both halves off.

**Toggle by hand:** run [`Set-QuestProximitySensor.ps1`](Set-QuestProximitySensor.ps1) (`windows\quest\`; for example right-click → *Run with PowerShell*). With no arguments it flips the sensor (off = the headset stays awake and on adb when you take it off; on = it sleeps again). It first makes sure this PC is on the phone's network, as the companion's startup does (`lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1 -PhoneLanHost <phoneLanHost>`: no change when the PC's gateway is already on the phone's subnet, otherwise it restarts that router's Wi-Fi so the PC moves back; `-SkipNetworkCheck` skips it), since adb reaches the headset only from the same network. If the headset is not on adb yet (asleep, or its Wi-Fi just switched on after a quit switched it off), it keeps trying every 5 s for up to **2 minutes** (`-WaitSec`, `0` = once), so you can put the headset on or switch its Wi-Fi on meanwhile. After about 30 s of misses it restarts the PC's adb server once: when the headset's Wi-Fi comes back on, wireless debugging gets a new port, and a running adb server can go on missing it over mDNS for minutes (seen: still nothing 40 s after a 2-minute run gave up; listed 4 s after a restart). `Reset-QuestBrowserFlags.ps1` does the same. It then prints what it did and the final state (`Sensor is OFF ...` / `Sensor is ON ...`) or the error (headset not on adb, no adb, change not taken), and waits for Enter. `-State On` / `-State Off` force one; `-NoWait` skips the wait. While the companion runs, its keep-awake job switches the sensor off again within ~20 s of turning it on.

## Close LAN tabs on companion close

Before the history clear, every Quest Browser tab whose address is a phone LAN origin (the LAN page, `/xr`, ...) or the Quest control page on this PC is closed over DevTools; other tabs stay. **One tab is always kept open:** Quest Browser's History list only answers while the browser has at least one tab (tested: the delete worked with one tab open and got `history query never answered` right after its last tab was closed; this is what made a quit and an after-quit helper fail even with the headset worn). So when our tabs are the only ones, the last of them is turned into a blank page (`about:blank`, never in history, back/forward list reset) instead of closed: `Tabs: kept one tab as a blank page`. A browser Loop Segments started is then force-stopped (below), which removes it without a *Recently closed* item; otherwise the blank tab stays. `"questCloseLanTabsOnExit": false` keeps them open.

**Quest Browser closed again if Loop Segments opened it.** Before its first intent, Open on Quest notes whether Quest Browser is **yours**: running with at least one tab of yours open, meaning a tab that is not an empty new-tab page and not on the phone LAN / control page (`%TEMP%\loopsegments-quest-browser-ours.json`; reset at each companion start). Not running, or running with only empty or Loop Segments tabs (for example left by an earlier session, a browser restart or the after-quit history helper, which brings the browser up), counts as started for Loop Segments. Once a click finds a tab of yours, the browser stays yours for the rest of the session. At close, in this order: close the LAN and control tabs, delete their history, sweep *Recently closed* (below), wait 5 s, then **force-stop** the browser (`am force-stop com.oculus.browser`: Android's "close this app now", the only way to close an app over adb) when this session started it, or when it was not running at close (the history step starts it), and only if no other tabs are left (empty new-tab pages do not count): `Browser: closed Quest Browser ...`, step summary `browser closed`. Any tab of your own keeps it running (`browser left`). When the history delete is postponed, the [after-quit history helper](#after-quit-history-helper) closes it after its delete instead (`browser helper`). Needs `questCloseLanTabsOnExit`. Tested: cold start from a stopped browser, then close → `history cleared, browser closed` in 2.9 s. Quest Browser restores its open tabs after a force-stop, which is why the LAN and control tabs are closed first.

## Delete Loop Segments history on companion close

Deletes **only this app's entries** from Quest Browser history: every entry whose origin is a phone LAN origin (`-Url`, `phoneLanHost`, `phoneLanHosts` with `lanPort`: the LAN page, `/xr`, its assets) or the Quest control page on this PC (`http://<PC address>:18766`). **The rest of your history is kept**, and so are cookies, cache, saved passwords, form data and site settings.

How: Quest Browser's own **History** list (the panel behind *History* in the browser menu) is opened over DevTools. Its own code asks the browser for the whole history, and each matching entry is removed the way that entry's remove button does it. Matching is by origin (scheme, host and port), so every entry on those origins goes, whatever its path.

Then the history is read again. A delete is a message to the browser with no reply, so this re-read is the only proof that none are left. If some are left, it deletes those and checks again. That covers:
- a delete the browser dropped;
- a very large history, where older matches appear only once newer ones are gone;
- a page still loading that adds a visit.

Normally one pass and one check is all it takes (1-2 s in tests). It stops after 20 rounds or when the time limit is nearly used up. If any matching entry is still left then, the selective delete has failed. The log says what happened, for example `History: deleted 2 entries on http://10.0.100.10:8765, http://10.0.100.244:18766; kept the other 2.`

**Fallback: last 24 hours.** If the selective delete fails (at quit, or in the [after-quit history helper](#after-quit-history-helper)) (History list not found, query not answered, entries left), the step clears **all** Quest Browser history from the **last 24 hours** instead, through the browser's own *Clear browsing data* dialog: **History only** is ticked, the range is picked, *Clear data* is pressed, then the dialog's previous ticks and range are put back. Cookies, cache, passwords, form data and site settings are never ticked. This does delete unrelated browsing from those 24 hours, and misses Loop Segments entries older than that. The log then says `History: selective delete failed - ...` followed by `History: fallback cleared ALL Quest Browser history from the last 24 hours (history only).`, and the step result is `fallback`. Like the selective delete, the dialog only answers while Quest Browser has a tab open (without one: `dialog time options never arrived`). Tested with one blank tab open: the last 24 hours cleared in 2 s, and *Recently closed* was emptied along with it. 10 s of the step's time limit is kept for it. `"questClearHistoryFallback"` picks the range: `hour`, `day` (default), `week`, `fourweeks`, `all`, or `none` for no fallback (the step is then just `failed`).

The dialog is only the fallback because it only offers those fixed ranges. Any of them deletes unrelated browsing in that window, and a short range misses entries from a longer session.

Only the current origins are matched. The PC address is worked out again at quit (see [Quest control page](#quest-control-page)). Entries from a phone address no longer in the config, or from an earlier PC address (for example after DHCP gave the PC a new IP), stay. Only the fallback catches those, and only from the last 24 hours, if it runs.

Quest Browser's 2D window is brought to the front first (the list only fills in then), and the browser is started if it was closed. This also takes the headset out of an immersive `/xr` session: immersive WebXR runs in a separate task, and while it is in front the 2D window is hidden. The whole step is limited to **30 s**. With the browser already running it takes 1-3 s, but a cold start of Quest Browser usually takes longer, so if the browser was closed the step may run out of time; that is logged. Manual run: `-ClearHistory`. Set `"questClearHistoryOnExit": false` to keep these entries.

**Recently closed.** The History panel also lists *Recently closed* tabs, and every tab closed over DevTools lands there: the LAN and control tabs closed at quit, and the flag fix's helper tab (now only when `isSecureContext` is false), which used to show up as *Experiments* (`chrome://flags`). These items also show as **tiles on the new-tab page**, and they are not in *See full history* or *Recently visited*. `chrome://` pages are never in history, and deleting a page from history does not reliably drop its item: an item for a test page whose history entry had been deleted, plus *Experiments* and empty *New tab* items that had been cleaned before, were all back days later (possibly from a force-stop right after a change: Chromium writes this list a few seconds after it changes, and a restart can bring back the older copy).

So after the history delete, the quit (and the [after-quit history helper](#after-quit-history-helper)) **sweeps Recently closed**: every item whose tabs are all on the phone LAN / control page origins, new-tab pages, blank pages or `chrome://flags` is reopened, sent to the phone page (`/xr-assets/aframe.min.js`) with its back/forward list reset, and closed; one more history delete then removes those phone-page entries. Logged `Recently closed: cleaned N of M ... item(s)`. Items with any other page in them are left alone. The flag fix closes its helper tab the same way. Before force-stopping Quest Browser (above), the quit waits 5 s so the browser has saved the cleaned list. Cleaned by hand once with this method (6 items: 4 *New tab*, a test page on `10.0.100.244:18767`, *Experiments*): the list stayed empty after a browser restart 20 s later.

This relies on Quest Browser's internal UI (its History list component and the `webui_action_query_history` / `webui_action_delete_history` messages). A Quest Browser update can change those; the selective delete then fails (for example `History list not found`) and the 24-hour fallback runs.

### Wi-Fi off at close

By default (`"questWifiOffOnExit": true`; `false` turns it off), the companion close switches the headset's **Wi-Fi off** as its very last Quest step (`cmd wifi set-wifi-enabled disabled` over adb; after the tabs, history, browser, SKYBOX and the sensor, and before the companion's Wi-Fi→www AP bounce). A sleeping headset on Wi-Fi drains its battery faster, and with Wi-Fi off it also cannot hop to the other network when the bounce reboots the phone network's router. Just before, it opens **Settings > Wi-Fi** (`am start -a android.settings.WIFI_SETTINGS`, which Quest relays to its Settings app on the Wi-Fi page with the toggle; log `Wi-Fi settings: opened`), so switching Wi-Fi back on is one tap when you next put the headset on. Only on an awake headset, since an activity start may wake a sleeping one, and after all browser steps, since Quest Browser goes behind the panel. adb drops right after (it runs over that Wi-Fi): log `Wi-Fi: switched the headset's Wi-Fi off`, step summary `Wi-Fi off`. Not done while the history delete is postponed (`Wi-Fi: left on - ...`): the [after-quit history helper](#after-quit-history-helper) needs it, and switches Wi-Fi off itself right after its delete, before running the held AP bounce. That happens while you are wearing the headset (the helper only deletes once it is worn), so Wi-Fi goes off under you: switch it back on if you keep using the headset. When the helper gives up at 2 h, it still switches Wi-Fi off first if the headset is on adb. Wi-Fi is not switched off before the bounce only when the headset cannot be reached then, the Wi-Fi command fails, or the quit's Quest cleanup is cut off by its time limit before its last step.

Before the next session, switch Wi-Fi on in the headset's quick settings. Wireless debugging then comes back by itself on a new port, which the PC finds over mDNS (tested: listed 2 s after Wi-Fi came back on). Until then Open on Quest queues and keep-awake waits.

### After-quit history helper

When the history step at quit still fails (usually `history query never answered` and `dialog time options never arrived`: nobody is wearing the headset, so Quest Browser is idle, see above), or the quit cannot reach the headset at all, the delete is **postponed** instead of dropped:

- the origins to delete go to `%TEMP%\loopsegments-quest-history-pending.json` (with "close the LAN tabs" and "reset the sensor" when the quit could not reach the headset);
- a hidden helper starts, detached from the companion so it keeps running after it: `Watch-LoopSegmentsQuestLanTab.ps1 -RetryHistory`. The log says `History: postponed - deleted when the headset is next worn (helper PID 6172, until 02:22)` and the step result is `postponed` (exit code 4; the companion prints *cleanup done ..., except the history delete*);
- every **5 s** it looks for the headset on adb (as often as the Open on Quest queue; each check is `adb devices`, and `dumpsys vrpowermanager` once the headset is there). If the quit could not reach it, it turns the sensor back on as soon as it gets through. Once the headset is **worn** (mounted and not idle), it brings Quest Browser to the front (so the browser pops up shortly after you put the headset on), closes the LAN tabs if the quit could not, deletes the entries and sweeps *Recently closed* (see [Recently closed](#delete-loop-segments-history-on-companion-close)), closes Quest Browser if the quit left it for the helper,: `History retry: headset worn - deleting.` ... `History retry: done.` If the selective delete fails there too, it uses the same range fallback as the quit (`questClearHistoryFallback`, default last 24 hours), **once per helper run**: retried, its Clear browsing data dialog kept popping up (seen stuck on *last 24 hours* while the browser did not answer): that also clears what you browsed since the quit. `none` turns it off for both;
- it gives up after **2 hours** (`questHistoryRetryMinutes`, `0` = no helper): `History retry: the headset was not worn in time - gave up`;
- it also stops when the companion starts again: the new session's quit deletes the same origins, old entries included. The companion stops it first thing at startup (before keep-awake can switch the sensor off under it).
- **it holds the quit's Wi-Fi AP bounce.** When the quit's Wi-Fi→www check fails while this helper is waiting, the companion does not restart the phone network's router then: that restart moves the headset to the other Wi-Fi (see [Headset on another Wi-Fi network](#5-how-the-pc-finds-the-headset)), where the helper on this PC cannot reach it. The check itself still runs at quit, while Loop Segments is in front (before Home); only its result is kept, in `%TEMP%\loopsegments-wifi-bounce-pending.json` (console: `[wifi-www] Quest history delete still pending: AP bounce held until ...`). The helper runs the bounce right after the delete, or when it gives up at 2 h (`Wi-Fi bounce: history deleted - bouncing the phone LAN AP now`; the bounce's own output goes to `%TEMP%\loopsegments-wifi-bounce.log`). If the companion starts again first, the held bounce is dropped: that session's quit checks again. SideStore's daily refresh can wait those hours. None of this holds up the quit: the companion waits only for the Quest cleanup step (at most 40 s), never for the helper, and with the bounce held it goes straight on to Home and finishes; the helper runs on by itself in the background.

Tested (with a 30 s check then): quit with the headset lying idle for 2 min → postponed; headset put on 4 min later → 3 entries deleted 6 s after the helper saw it worn. With the 5 s check the delete starts within ~5 s of putting the headset on, plus ~3 s for the browser to settle. While it waits, the helper restarts the PC's adb server at most every 20 min (not 5) when it cannot find the headset.

## Quest control page

A small page the companion serves on **this PC's LAN address**, made for Quest Browser: [`Serve-QuestControlPage.ps1`](Serve-QuestControlPage.ps1), started hidden at companion startup and stopped at close (it also exits by itself once the companion is gone). Default port **18766** (`questControlPort`), for example `http://10.0.100.244:18766/`. The address is not a setting. Each time it is needed (Open on Quest, closing tabs and deleting history at quit), it is the PC's IPv4 address on the route to the headset: a UDP socket is "connected", without sending anything, to the headset's IP from its wireless adb serial (or `questAdbHost`; for a USB serial, the phone address from `-Url`), and the local address Windows picks is used. A new PC address is picked up on the next run. **Open on Quest** opens it in its own normal tab, signed in the same way as the LAN page (login URL, then reloaded plain, back/forward list reset), then opens the LAN page so that one is in front; an already open control tab is reused. `"questControlPageOnQuest": false` leaves it out.

**On the PC:** the phone LAN page in the companion's Chromium has a **Quest control** button next to **Open on Quest**. It opens the page at `http://127.0.0.1:18766/` in a new tab next to the LAN tab (or switches to it if it is already open), and the companion extension answers the login, as it does for the phone LAN page. It first checks the page is up; otherwise the button says *not running* (companion not started, or `questControlPage` false) or *refused the login*. The companion writes the port and the login into the extension's `lan_config.json` at startup (`questControlPort`, `questControlPassword`: the same phone LAN login the page checks). Any other browser on the PC or the LAN also opens it at its address, with the login typed in.

It holds the SKYBOX buttons (the target address and login user, the servers this PC added, the last action's result, the recent `SKYBOX:` log lines) and the **LAN bandwidth** test (both below). It refreshes every 10 s, every 1.5 s while an action or a measurement runs. More Quest actions can be added to it later.

Unlike the companion's own `127.0.0.1:18765` endpoint, this one is **reachable from the LAN**, so every request must pass all of:

- **client address** loopback or private (`10/8`, `172.16/12`, `192.168/16`, `169.254/16`); others are dropped;
- **`Host` header** an IP address or `localhost` (no DNS names: blocks DNS rebinding);
- **login**: HTTP Basic with the phone LAN login (`webdavUser` and that phone's `phoneLanHosts[].webdavPassword`, else `webdavPassword`), compared in constant time; a wrong login waits 1 s;
- **actions**: `POST` with header `X-Quest-Control: 1`. A form or link on another website cannot send that header, and the cross-origin preflight a script would need is refused (no CORS), so another site open in the same browser cannot press the buttons with the cached login.

The server handles one request at a time and only once a connection has sent one: Quest Browser opens spare connections that send nothing, and those are closed after 10 s instead of holding up the page. The page sends `Content-Security-Policy`, `X-Frame-Options: DENY` and `Cache-Control: no-store`. The login travels unencrypted over the LAN, like the phone LAN page's. **Windows Firewall** must allow inbound TCP on the port on the Private network: on this PC the existing *PowerShell 7* allow rule for `pwsh.exe` already does. If the Quest cannot open the page (the log says `Control page: ... did not load on the Quest`), allow it yourself, or set `"questControlPage": false`. Server log: `%TEMP%\loopsegments-quest-control.log`; action log: `%TEMP%\loopsegments-quest-lantab.log`.

## LAN bandwidth (PC ↔ phone), from the control page

The **LAN bandwidth: PC ↔ phone** section shows the last measurement and a **Measure LAN** button. The button runs the same probe the companion runs at startup, [`..\lan\Measure-LoopSegmentsLanThroughput.ps1`](../lan/Measure-LoopSegmentsLanThroughput.ps1), in the background on the PC: it downloads up to **64 MB** of a random phone video over **HTTP**, and when the rclone mount (`mountDriveLetter`, default `L:`) is up also copies it **from the mount**, then uses the **lower** number. While it runs the page shows its last output lines; it usually takes 10-60 s. One measurement at a time (a second press gets *already running*); it runs alongside a SKYBOX action.

| Row | Meaning |
|---|---|
| **Result** | Mbps of the lower path (`http` or `mount`), green; red with **LOW** when under `minLanThroughputMbps` (default 40), or *failed: ...* with the error |
| **HTTP / mount** | Each path's Mbps (*not measured* when the mount was not up) |
| **Max segment bitrate** | The recommended max media bitrate for minute segments (80% of the result, 5-100 Mbps), the same number the probe prints and writes to the phone sidecars when the mount is up |
| **Measured** | When, in the viewer's local time; notes when Virtual Desktop's streamer was running (it uses ~50 Mbps of the LAN, so the number reads low) |

Unlike the startup probe, a press **never reboots routers** when the result is low (`-SkipLowThroughputGatewayReboot`): only the companion's startup probe does that. The result is kept on the PC in `%TEMP%\loopsegments-lan-throughput.json` (`-ResultFile`; the startup probe writes it too, so the page shows that one until you press the button); the output of the last press is in `%TEMP%\loopsegments-quest-control-lanbw.log`. The phone LAN page's own **LAN speed test** measures the browser ↔ phone path instead (on the Quest: headset ↔ phone).

## SKYBOX: phone as a WebDAV server, from the control page

SKYBOX VR Player (`xyz.skybox.player.ovr`) keeps its **Network** servers in an SQLite file on the headset's shared storage, `/sdcard/Android/data/xyz.skybox.player.ovr/files/SkyboxDataBase` (table `DeviceDataTable`). A WebDAV server is one row: `Url` `webdav://<phone>:8765/`, `FileName` (the name shown), `Username`, and `Password` **in plain text** (SKYBOX stores it that way itself).

The control page has three buttons; each runs once in the background ([`QuestSkybox.ps1`](QuestSkybox.ps1) through `Watch-LoopSegmentsQuestLanTab.ps1`), one at a time:

| Button | What it does |
|---|---|
| **Push** | Put server **Loop Segments** in SKYBOX at the phone's **current** address with the **current** login, and delete the servers this PC added at older addresses |
| **Update** | The same, but only if such a server is already there (else *not there*, nothing touched) |
| **Clear** | Remove every Loop Segments entry from SKYBOX's Network list (below; asks first) |

Current means read when you press the button: the phone address and port from the companion's `lan_config.json` (`phoneLanHost`, `lanPort`; written from `phoneLanHostSource`: the saved `phoneLanHost`, or the USB-detected address), and the login from `windows\loop-segments-windows.json` (`webdavUser`, `phoneLanHosts[].webdavPassword` for that phone, else `webdavPassword`). Nothing runs on a timer: after the phone's address or the password changes, press **Update** (or **Push**). Opening the server in SKYBOX → Network needs no login. A press while the headset is off adb reports *headset not on adb* and changes nothing.

Every server URL this PC added is listed (URLs only, no password) in `%TEMP%\loopsegments-skybox-webdav.json`. **At companion close** (and on **Clear**) the cleanup removes, in one edit after the history clear, every **Loop Segments entry** in SKYBOX's Network list, so no phone password stays on the headset after a session:

- WebDAV servers this PC added (the list above);
- any WebDAV server at a phone address the companion knows: the current one in `lan_config.json`, `phoneLanHost`, and every `phoneLanHosts[]` entry with `lanPort`, including servers you added by hand under another name;
- any WebDAV server named **Loop Segments**, wherever it points;
- the companion's **rclone DLNA** server: a `dlna://` entry named `rcloneDlnaName` (default *Loop Segments*) that rclone announced (`Manufacturer` *rclone (rclone.org)*). SKYBOX finds it again by itself the next time `-EnableRcloneDlna` serves it.

Everything else stays: other WebDAV, SMB and AirScreen servers, other DLNA servers (also one named *Loop Segments* that rclone did not announce), SKYBOX's folder cache and playback positions. The log lists what was removed (`SKYBOX: removed 2 Loop Segments entries: webdav://10.0.100.10:8765/, rclone DLNA 'Loop Segments'`), and the list file is deleted afterwards.

At close the cleanup first stops the control page and any button action still running (whole process trees, adb included), so nothing adds the server back. An action stopped in the middle of an edit leaves its `%TEMP%\loopsegments-skybox-*` folder (a full copy of SKYBOX's database, saved logins included) and maybe a half-pushed `SkyboxDataBase.loopsegments-new` on the headset; every SKYBOX run, the close-time removal included, deletes those first and logs it (`removed leftovers of an interrupted run`). The swap itself is a single `mv`, so SKYBOX's file is always either the old or the new copy.

How a change is made: the file is copied to a new folder in `%TEMP%` (the headset has no `sqlite3`) and checked with `sqlite3.exe` (shipped with adb in platform-tools; the SQL goes in on stdin, so the password is never on a command line or in the log) while SKYBOX keeps running. If the row is already right (or already gone), nothing else happens and SKYBOX is not touched. Otherwise SKYBOX is **stopped** (`am force-stop`; it holds the file open and would keep writing the old copy), the edit is refused if a `SkyboxDataBase-wal` or `SkyboxDataBase-journal` file sits next to it (see WAL mode below), the file is copied again only if its size or modified time moved, then edited, checked (`PRAGMA integrity_check`), pushed to a temp name and moved over the original. That move runs in **one headset shell command together with a last check**: it happens only if SKYBOX is still stopped, no `-wal` / `-journal` has appeared, and the database still has the size and modified time of the copy that was edited. Copying, editing and pushing take 5-15 s, and you may open SKYBOX in that time; if any check fails the pushed copy is deleted, SKYBOX's own file is left as it is, the log says why (`not replacing the database: SKYBOX was opened / a journal file appeared / SKYBOX saved to it ...`), and the button reports *failed*: press it again. The `%TEMP%` folder is always deleted. The adb shell cannot write SKYBOX's file in place but can replace it; SKYBOX keeps using the replaced file. Each copy moves the whole file (about 60 MB, 5-10 s over Wi-Fi), so with this on the companion waits up to **60 s** for the close-time cleanup instead of 40 s.

So SKYBOX is only touched when the server has to change: if it is open, **Push** / **Update** **restart** it (closed, edited, opened again on its home screen; anything playing stops; if nobody is wearing the headset the reopen may not happen, see below) and **Clear** or the close-time removal **closes** it. If it is closed, it stays closed. While the server is in SKYBOX, its password is on the headset in plain text, readable over adb. If the companion is killed outright, the server stays: press **Clear** next session, run `-ClearSkyboxWebDav` (below), or delete it in SKYBOX. `"questSkyboxWebDav": false` turns off the buttons and the close-time removal.

**Reopening SKYBOX needs the headset in use.** An adb launch only asks Horizon OS to start SKYBOX; the OS first has to place its window in your space. With the headset lying still (head tracking idle, even when the proximity override keeps it awake) that placement never answers, and after 10 s the launch is dropped without an error to adb: the headset log shows `Timeout while requesting window placement`, and no SKYBOX process starts. Worn or moving, the same launch starts SKYBOX at once. So after a Push / Update with nobody in the headset, SKYBOX may stay closed; open it yourself. The database change does not depend on this: it never needs SKYBOX running.

### If SKYBOX changes how it stores servers

This relies on details of SKYBOX 2.0.2 (version code 3868, checked 2026-11-12) that SKYBOX does not document and can change in any update. The plain-text password is the one that makes the full sign-in possible, and the one most likely to change. The log (`%TEMP%\loopsegments-quest-lantab.log`, lines starting `SKYBOX:`) shows which case you are in:

| If SKYBOX... | What you see | What the companion does | Workaround |
|---|---|---|---|
| **encrypts saved passwords** | **Loop Segments** shows in Network but asks for the login, or fails to sign in. The log still says `added` | Writes the plain password anyway; SKYBOX cannot use it. No harm to other servers | Use a blank password: the server still appears and SKYBOX asks for the username and password when you open it (tested with 2.0.2). Type them once per session; the close-time removal deletes what SKYBOX saved. Today that needs a one-line change (`-Password ''` in `Invoke-QuestSkyboxWebDavPush`); there is no setting for it yet |
| **renames the table or columns** | `SKYBOX: database read failed: ...` | Reads fail before any edit, so nothing is pushed; the button reports *failed* | Pull a copy (`adb pull <path>`), look at the schema (`sqlite3 SkyboxDataBase .schema`), add one WebDAV server by hand and compare, then update [`QuestSkybox.ps1`](QuestSkybox.ps1) |
| **moves the database or changes its package name** | `SKYBOX: not installed on the headset` or `no database yet` | Skips | Find the new path (`adb shell pm list packages` and look for skybox, then `adb shell ls -R /sdcard/Android/data/<package>`) and update `$script:SkyboxPackage` / `$script:SkyboxDbPath` |
| **switches SQLite to WAL mode** (or was killed mid-save) | `SKYBOX: database has a journal file next to it` | Refuses to edit (the main file alone would not hold SKYBOX's latest data); SKYBOX is started again if it was open | Open and close SKYBOX once (it folds the journal back in). If it keeps happening, SKYBOX moved to WAL: the edit would have to pull and push the `-wal` file too |
| **moves its data to private storage**, or Horizon OS blocks adb from `Android/data` | `SKYBOX: could not copy the database from the headset` | Skips | No adb workaround on a stock headset (`run-as` is refused: SKYBOX is not debuggable). Add the server by hand: Network → Add → Add WebDAV server, `http://<phone>:8765/`, `admin` / the app password |

**WAL mode, and why the journal check:** SQLite saves changes one of two ways. SKYBOX 2.0.2 uses the default **rollback journal** (`PRAGMA journal_mode` reports `delete`): changes go straight into `SkyboxDataBase`, and a `SkyboxDataBase-journal` holding the old contents exists only during a save, so a crash can be undone. With SKYBOX stopped, the main file is the whole, current database, which is what makes copy, edit and push back safe. In **WAL (write-ahead log)** mode, which an app turns on with one setting (`PRAGMA journal_mode=WAL`), new changes go to `SkyboxDataBase-wal` first and reach the main file only from time to time, so the real database is the main file plus `-wal`. Editing only the main file would drop what is still in `-wal` (recent servers, playback positions, folder listings), and a leftover `-wal` that no longer matches can corrupt the database. So after stopping SKYBOX the edit checks for either file and refuses if one is there. A `-journal` usually means SKYBOX was killed mid-save; opening and closing SKYBOX once clears it. A `-wal` that keeps coming back means SKYBOX switched to WAL: the edit would then have to pull and push the `-wal` file with the database (or fold it in first with `PRAGMA wal_checkpoint(TRUNCATE)` on the copy).

None of these stops the rest of the companion: each case is logged and skipped. To turn the feature off while you sort it out, set `"questSkyboxWebDav": false`.

## One-time setup

### 1. PC: adb

```powershell
winget install Google.PlatformTools
```

Open a new terminal afterwards so `adb` is on PATH. (The script also finds the winget, Android SDK, and Meta Quest Developer Hub copies on its own; `questAdbExe` overrides.)

### 2. Quest: developer mode

In the **Meta Horizon** phone app: Devices → your headset → Headset settings → **Developer mode** on. Reboot the headset.

### 3. USB once: trust the PC

Plug the Quest into the PC, put it on, and accept **Allow USB debugging** (tick *Always allow from this computer*). Check:

```powershell
adb devices -l
```

### 4. Keep wireless adb on across reboots: [adb-auto-enable](https://github.com/project-SIMPLE/adb-auto-enable)

Quest switches wireless adb off on every reboot. adb-auto-enable turns it back on after boot (and auto-accepts the USB-debugging prompt). Download the APK from that repo's **Releases**, then with the Quest still on USB:

```powershell
adb install <path-to-downloaded>.apk
adb shell pm grant eu.project_simple.adbautoenable android.permission.WRITE_SECURE_SETTINGS
```

Open **ADB Auto-Enable** on the headset once (Library → Unknown sources). With the permission granted it enables its own accessibility service. If it does not, run:

```powershell
adb shell "settings put secure enabled_accessibility_services eu.project_simple.adbautoenable/eu.project_simple.adbautoenable.AdbPopupAccessibilityService && settings put secure accessibility_enabled 1"
```

Verify (expect `granted=true`, the service name, `1`, `1`):

```powershell
adb shell dumpsys package eu.project_simple.adbautoenable | findstr WRITE_SECURE_SETTINGS
adb shell settings get secure enabled_accessibility_services
adb shell settings get secure accessibility_enabled
adb shell settings get global adb_wifi_enabled
```

**After a reboot you do not need to open the app.** Android starts its accessibility service by itself at boot (on Quest 3: 13 s after boot), the service switches wireless adb back on, and the PC reconnects through mDNS before anyone opens the app. This depends on the accessibility service staying enabled: if a Horizon OS update or a settings reset turns it off, open **ADB Auto-Enable** once or rerun the `settings put secure enabled_accessibility_services ...` command above.

Wireless adb gives full shell access to the headset: keep it on your home LAN only, and never port-forward it.

### 5. How the PC finds the headset

The script tries, in order:

1. a Quest already listed by `adb devices -l` (or `questAdbSerial`);
2. `adb connect <questAdbHost>:<questAdbPort>` (default `5555`) when `questAdbHost` is set;
3. `adb connect` to the **last address the headset was on adb at** (`%TEMP%\loopsegments-quest-last-adb.txt`, saved whenever it is found; shared by Open on Quest, keep-awake and the history helper; 3 s timeout). Wireless debugging keeps its port until it is switched off or the headset reboots, so this gets the headset back at once, without mDNS: logged `Connected to the last known address 10.0.100.238:39923`. Measured after an adb server restart: mDNS listed the headset after 17 s once and not within 240 s another time, while the direct connect took 134 ms (and Open on Quest found it immediately). After a reboot or on another network it simply fails and the next steps run. It keeps `ip:port` as one value: the IP alone would not help, since the port is random. The IP usually stays the same per network (the router's DHCP hands the same address back to the headset's per-network MAC; seen all day: always `10.0.100.238` on ATT-WIFI-5pmY, `192.168.2.54` on ATT-WIFI-3pKe), so the port is what goes stale: a reboot, a wireless-debugging toggle, **or a Wi-Fi network switch** gives a new one (seen: `36483` → `39923` after the headset was moved back from `192.168.2.x`). The next mDNS find saves the new port;
4. `adb mdns services` → the wireless-debugging TLS port (random, e.g. `10.0.100.238:37275`);
5. if none of that has found the headset for **60 s** (`questAdbRediscoverSec`) and no adb device at all is connected: restart the PC's adb server (`adb kill-server`, `adb start-server`) and look over mDNS again. The adb server can stop hearing the headset's announcements after the headset sleeps and comes back on a new port; a restart makes it listen afresh. At most once every 5 min across all companion processes (`%TEMP%\loopsegments-adb-rediscover.txt`), logged as `adb: headset not seen over mDNS for 60 s - restarting the adb server`. `0` turns it off.

**Headset on another Wi-Fi network.** mDNS does not cross routers, so the PC finds the headset only while both are on the same network (subnet). Off it, the headset still answers ping at its new address, but `adb mdns services` stops listing it, `adb devices` shows the old serial as *offline*, and each switch gives wireless debugging a new port. Restarting the adb server does not help.

The usual cause is the companion's own **quit**, and it is intended: when its Wi-Fi→www check fails, the finish restarts the Wi-Fi of the phone network's router (held until the [after-quit history helper](#after-quit-history-helper) is done, when one is waiting: the helper needs the headset on the PC's network) (`[gateway] Rebooting phone-LAN AP 10.0.100.2 (mr5100)` in the console log; see [../README.md](../README.md)). That restart is what gives the phone internet over Wi-Fi again, which SideStore needs for its daily app refresh, so it stays. While that router is down, Windows and the headset both join their other saved network (seen: from `ATT-WIFI-5pmY_5GHz`, `10.0.100.x`, the phone's network, to `ATT-WIFI-3pKe`, `192.168.2.x`), seconds after every quit, and stay there. The next companion start moves the PC back to the phone's network; the headset may stay behind, and adb loses it until it moves back too (or you move it). Windows' Wi-Fi log shows this: Event Viewer → *Applications and Services Logs → Microsoft → Windows → WLAN-AutoConfig → Operational*, event 8001.

So do **not** simply forget the other network on the headset: after a quit the PC sits on it, and the [after-quit history helper](#after-quit-history-helper) then only finds a headset that followed it there (tested: both on `192.168.2.x`, found over mDNS 22 s after the quit). While the companion runs, both need the phone's network; if the headset is the one that stayed behind, switch it in its Wi-Fi settings, and the companion finds it within about 20 s.

**Use wireless debugging (mDNS); leave `questAdbHost` empty.** It needs no config and keeps working across reboots. It works once this PC is paired: if `adb mdns services` lists the headset but `adb connect` fails with an auth error, pair once: on the headset, Settings → System → Developer → **Wireless debugging** → *Pair device with pairing code*, then `adb pair <ip>:<pairing-port>` and type the code.

**Optional fallback, fixed port 5555.** Only needed if mDNS discovery does not reach this PC (for example a VPN or Clash/mihomo TUN swallowing the multicast announcement, or the PC and Quest on different subnets), or if another tool insists on `IP:5555`. With the Quest on USB run `adb tcpip 5555`, then set `"questAdbHost": "<headset Wi‑Fi IP>"` in `windows\loop-segments-windows.json` (a DHCP reservation on the router keeps the IP stable). Limits: **a reboot closes 5555 again** (ADB Auto-Enable restores only the wireless-debugging port, and keeping 5555 needs root: `setprop persist.adb.tcp.port 5555` is refused on a stock Quest), and 5555 traffic is not encrypted (wireless debugging is). The script still falls back to mDNS when `IP:5555` does not answer.

### 6. Test

With the headset awake, from `windows\`:

```powershell
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://<phoneLanHost>:8765/ -Once           # open, signed in
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://<phoneLanHost>:8765/ -Once -WaitMinutes 7   # wait for wake, like the button
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://<phoneLanHost>:8765/ -EnsureFlags    # chrome://flags fix only
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://<phoneLanHost>:8765/ -ClearHistory   # only the LAN page / control page entries
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -EnableProximity                                 # proximity sensor back on
pwsh -File quest\Reset-QuestBrowserFlags.ps1                                                  # chrome://flags Reset all + browser restart
pwsh -File quest\Set-QuestProximitySensor.ps1 -State Off                                       # sensor off (stays awake); no -State = toggle; waits for Enter
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://<phoneLanHost>:8765/ -SkyboxPush         # Push button: put the phone in SKYBOX
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://<phoneLanHost>:8765/ -SkyboxUpdate       # Update button
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -ClearSkyboxWebDav                                # remove every server this PC added
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -ProbeIncognito                                  # read-only
```

Log: `%TEMP%\loopsegments-quest-lantab.log`.

## Settings (`windows\loop-segments-windows.json`)

| Key | Default | Meaning |
|-----|---------|---------|
| `questAdbHost` | `""` | Headset Wi‑Fi IP for `adb connect` (empty = already-connected / mDNS only) |
| `questAdbPort` | `5555` | Port for `questAdbHost` |
| `questAdbSerial` | `""` | Pick this adb serial when several Android devices are connected |
| `questAdbExe` | `""` | Full path to `adb.exe` (empty = auto) |
| `questAdbRediscoverSec` | `60` | Headset not found for this long and no adb device connected: restart the PC's adb server once to rediscover it over mDNS (at most every 5 min). `0` = off |
| `questIncognito` | `false` | `true` = private tab (no immersive WebXR there) instead of the normal tab |
| `questSendLanLogin` | `true` | Sign the tab in with the LAN login (`false` = sign in on the headset) |
| `questEnsureInsecureOriginFlag` | `true` | Each Open on Quest: check `isSecureContext` in the LAN tab and, only if false, fix the insecure-origin flag (restarts Quest Browser and reopens the page) |
| `questClearHistoryOnExit` | `true` | Companion close: delete the Quest Browser history entries on the phone LAN page and the control page (other history is kept) |
| `questWifiOffOnExit` | `true` | Companion close: open Settings > Wi-Fi, then switch the headset's Wi-Fi off as the last step (see [Wi-Fi off at close](#wi-fi-off-at-close)) |
| `questHistoryRetryMinutes` | `120` | The quit could not delete the history (headset not worn / not on adb): a background helper deletes it once the headset is worn, for up to this many minutes. `0` = off |
| `questClearHistoryFallback` | `"day"` | If that selective delete fails (at quit or in the after-quit helper): clear **all** history from this range instead (`hour`, `day`, `week`, `fourweeks`, `all`; `none` = no fallback) |
| `questCloseLanTabsOnExit` | `true` | Companion close: close Quest Browser tabs on the phone LAN page (before the history clear), then Quest Browser itself if Open on Quest started it and no other tabs are left |
| `questControlPage` | `true` | Companion session: serve the Quest control page on this PC's LAN address (signed in with the phone LAN login) |
| `questControlPort` | `18766` | Its TCP port (Windows Firewall must allow it inbound on the Private network) |
| `questControlPageOnQuest` | `true` | **Open on Quest** also opens the control page in its own tab (the PC LAN page's **Quest control** button works either way) |
| `questSkyboxWebDav` | `true` | Control page SKYBOX **Push / Update / Clear** buttons, and removal of the Loop Segments entries (phone WebDAV servers, rclone DLNA entry) at companion close |
| `questKeepAwakeDuringSession` | `true` | Hold the proximity sensor off while the companion runs (headset stays awake for the close-time history clear); turned back on at cleanup |
