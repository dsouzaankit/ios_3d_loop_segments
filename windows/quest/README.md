# Quest: Open on Quest, flags, history, SKYBOX

The PC companion drives **Quest Browser** over **adb over Wi-Fi** and the browser's DevTools socket (the one `chrome://inspect` uses). Everything goes through [`Watch-LoopSegmentsQuestLanTab.ps1`](Watch-LoopSegmentsQuestLanTab.ps1) (helpers in [`QuestDevTools.ps1`](QuestDevTools.ps1), companion hooks in [`QuestCompanionHooks.ps1`](QuestCompanionHooks.ps1)). Log: `%TEMP%\loopsegments-quest-lantab.log`.

| When | What | Setting |
|------|------|---------|
| **Open on Quest** click (PC LAN page) | Check the flag (below), then open the LAN page in a **normal tab, signed in** | `questSendLanLogin`, `questIncognito` |
| Companion **startup** | Hidden, in the background: make sure the insecure-origin flag lists the phone LAN origin(s) | `questEnsureInsecureOriginFlag` |
| Companion **startup**, until close | Keep the headset **awake**: proximity sensor held off once the headset is on adb | `questKeepAwakeDuringSession` |
| Companion **startup**, until close | Keep the phone in **SKYBOX** as WebDAV server **Loop Segments**, signed in, on the phone's current address and LAN login | `questSkyboxWebDav` |
| Companion **close** (normal finish and the console-X watchdog) | Close Quest Browser **tabs on the phone LAN page**, clear **history** (History only, All time), **remove the SKYBOX server**, then turn the **proximity sensor back on** | `questCloseLanTabsOnExit`, `questClearHistoryOnExit`, `questSkyboxWebDav`, `questKeepAwakeDuringSession` |

Startup and close steps are skipped (and logged) when the headset is not on adb. **Open on Quest** waits instead (below).

**Headset asleep or off adb when you click:** the click is queued. The button says *Queued: opens on Quest when the headset wakes (until HH:MM)*, and the companion keeps polling for **7 minutes**; when the headset wakes and adb is back it opens the page once. Clicking again while one is queued just shows it. The wait ends when the page opens, after 7 minutes (*Quest did not wake ... - nothing opened*), or when the companion quits.

## Open on Quest: normal tab, signed in

1. **One tab:** if a tab on the phone LAN page is already open (LAN page or `/xr`), the browser is brought to the front and that tab is reused; extra LAN tabs are closed. Otherwise a VIEW intent for `http://<phone>:8765/` (retried: the browser sometimes drops the first one) opens a new normal tab at the login prompt. Reusing an `/xr` tab replaces the XR player with the LAN page.
2. Over DevTools, that tab is sent to `http://admin:<password>@<phone>:8765/` (the browser caches the LAN login), then back to the plain URL, and its back/forward list is reset so **Back** never leads to the URL with the password.
3. The page is signed in, its URL has no password, `fetch()` works (`status_lists.json`), and **WebXR immersive VR/AR is available**. If the tab ends on Chromium's error page (phone app closed or phone off Wi-Fi), the button reports a failure instead of "Opened".

Why not a private tab: **Quest Browser disables immersive WebXR in private tabs** (`isSessionSupported("immersive-vr")` is false there and true in a normal tab), so the XR player cannot enter VR from one. `"questIncognito": true` (or `-PrivateTab`) still opens a private tab instead (Chromium `IncognitoTabLauncher` + typed URL; falls back to a normal tab). Why the reload: a page whose URL contains `user:pass@` cannot `fetch()` (Chromium refuses URLs with credentials).

The password comes from `webdavPassword` in `windows\loop-segments-windows.json`, or from the matching `phoneLanHosts[].webdavPassword`. It is percent-encoded, read by the script itself (never on a command line), and never logged. Chromium does not keep the `user:pass@` form in browsing history. `"questSendLanLogin": false` (or `-NoLanLogin`) opens the plain URL and you sign in as `admin` / the app password on the headset.

## chrome://flags: insecure origin as secure

Quest WebXR over LAN `http://` needs `chrome://flags/#unsafely-treat-insecure-origin-as-secure` **Enabled** with the phone's origin listed. The script reads the flag on a helper tab (a no-login phone page, `/xr-assets/aframe.min.js`, closed afterwards). If a phone LAN origin is missing (`phoneLanHost` / `phoneLanHosts` with `lanPort`, plus the companion's current phone address) it **adds** it, keeping the origins already there. It then enables the flag, **restarts Quest Browser** (flags apply only after a restart), and confirms the value after the restart. Nothing changes and nothing restarts when the flag already covers every origin. **The restart closes open Quest Browser tabs** (Quest does not restore them). Manual run: `-EnsureFlags`.

## Keep the headset awake during the session

A history clear at quit only works if the headset is on adb, and an asleep Quest usually is not. So while the companion runs, a hidden job holds the **proximity sensor off** (`am broadcast -a com.oculus.vrpowermanager.prox_close`: the headset acts as if worn and does not sleep when you take it off). It checks about every 20 s and applies the override as soon as the headset shows up on adb, and again after a headset reboot (a reboot clears it).

Cleanup, on a normal quit and on console X (the watchdog), stops that job and starts **one background process** that closes the LAN tabs, **clears history** (the headset is still awake), then **turns the sensor back on**. The companion closes Chromium and syncs the profile meanwhile, and waits for that process (at most 40 s from its start) before the Wi-Fi probe / router restart, which would drop the Quest's adb. Each step logs its duration (`Tabs: ... (0.4 s)`, `History step: ...`, `Proximity step: ...`, `Cleanup: finished ... s after start`). The sensor is turned back on even if the history clear failed (`am broadcast -a com.oculus.vrpowermanager.automation_disable`, checked against `dumpsys vrpowermanager`: `Virtual proximity state: DISABLED`).

Things this does not cover: pressing the power button or a flat battery still sleeps the headset. If the PC crashes or both companion processes are killed, nothing turns the sensor back on: run `-EnableProximity`, or reboot the headset. While the override is on, the display stays lit when the headset is off your head (battery, and keep the lenses out of direct sunlight). `"questKeepAwakeDuringSession": false` turns both halves off.

## Close LAN tabs on companion close

Before the history clear, every Quest Browser tab whose address is a phone LAN origin (the LAN page, `/xr`, ...) is closed over DevTools; other tabs stay. `"questCloseLanTabsOnExit": false` keeps them open.

## Clear history on companion close

Uses the browser's own **Clear browsing data** dialog: ticks **History only**, picks **All time**, presses **Clear data**, then puts the dialog's previous ticks and time range back. **Cookies, cache, saved passwords, form data and site settings are kept.** This deletes your **whole** Quest Browser history, not only Loop Segments pages. Quest Browser's 2D window is brought to the front first (the dialog only answers then), and the browser is started if it was closed. This also takes the headset out of an immersive `/xr` session: immersive WebXR runs in a separate task, and while it is in front the 2D window is hidden and the dialog's time options never fill in. The whole clear is limited to **30 s**: with the browser already running it takes a few seconds, but a cold start of Quest Browser usually takes longer, so if the browser was closed the clear is skipped and logged. Manual run: `-ClearHistory`. Set `"questClearHistoryOnExit": false` to keep history.

## SKYBOX: phone as a WebDAV server for the session

SKYBOX VR Player (`xyz.skybox.player.ovr`) keeps its **Network** servers in an SQLite file on the headset's shared storage, `/sdcard/Android/data/xyz.skybox.player.ovr/files/SkyboxDataBase` (table `DeviceDataTable`). A WebDAV server is one row: `Url` `webdav://<phone>:8765/`, `FileName` (the name shown), `Username`, and `Password` **in plain text** (SKYBOX stores it that way itself).

From startup until close a hidden job ([`QuestSkybox.ps1`](QuestSkybox.ps1)) keeps the row **Loop Segments** on the phone's current address and login. About every 20 s it re-reads, from local files only:

- the phone address and port from the companion's `lan_config.json` (`phoneLanHost`, `lanPort`; the companion writes it from `phoneLanHostSource`: the saved `phoneLanHost`, or the USB-detected address), and
- the login from `windows\loop-segments-windows.json`: `webdavUser` and `phoneLanHosts[].webdavPassword` for that phone, else `webdavPassword`.

When either differs from what it last put in SKYBOX (and once at the start), and the headset is on adb, it adds or updates the row in one edit and deletes the rows it added at older addresses. Between changes it does not use adb at all. A change made while the headset is off adb goes in when the headset shows up. Opening the server in SKYBOX → Network needs no login.

Every server URL this PC added is listed (URLs only, no password) in `%TEMP%\loopsegments-skybox-webdav.json`. At close the cleanup deletes all of them plus the one at the current address, after the history clear, and then deletes the list. Only those rows are touched: other servers (including SKYBOX's own entry for the rclone DLNA server, also named Loop Segments), SKYBOX's folder cache and playback positions stay.

At close the cleanup force-stops the session job (with its adb children) before removing the server, so it cannot add it back. A job stopped in the middle of an edit leaves its `%TEMP%\loopsegments-skybox-*` folder (a full copy of SKYBOX's database, saved logins included) and maybe a half-pushed `SkyboxDataBase.loopsegments-new` on the headset; every SKYBOX run, the close-time removal included, deletes those first and logs it (`removed leftovers of an interrupted run`). The swap itself is a single `mv`, so SKYBOX's file is always either the old or the new copy.

How a change is made: the file is copied to a new folder in `%TEMP%` (the headset has no `sqlite3`) and checked with `sqlite3.exe` (shipped with adb in platform-tools; the SQL goes in on stdin, so the password is never on a command line or in the log) while SKYBOX keeps running. If the row is already right (or already gone), nothing else happens and SKYBOX is not touched. Otherwise SKYBOX is **stopped** (`am force-stop`; it holds the file open and would keep writing the old copy), the edit is refused if a `SkyboxDataBase-wal` or `SkyboxDataBase-journal` file sits next to it (see WAL mode below), the file is copied again only if its size or modified time moved, then edited, checked (`PRAGMA integrity_check`), pushed to a temp name and moved over the original. The `%TEMP%` folder is always deleted. The adb shell cannot write SKYBOX's file in place but can replace it; SKYBOX keeps using the replaced file. Each copy moves the whole file (about 60 MB, 5-10 s over Wi-Fi), so with this on the companion waits up to **60 s** for the close-time cleanup instead of 40 s.

So SKYBOX is only touched when the server has to change: if it is open, adding or updating the server (at startup, or when the address or login changes mid-session) **restarts** it (closed, edited, opened again on its home screen; anything playing stops) and removing it at quit **closes** it. If it is closed, it stays closed. While the companion runs, the server is on the headset with its password in plain text, readable over adb. If the companion is killed outright, the server stays (the next startup finds it already there and leaves SKYBOX alone, or moves it if the address changed): run `-ClearSkyboxWebDav` (below), or delete it in SKYBOX. `"questSkyboxWebDav": false` turns both halves off.

### If SKYBOX changes how it stores servers

This relies on details of SKYBOX 2.0.2 (version code 3868, checked 2026-11-12) that SKYBOX does not document and can change in any update. The plain-text password is the one that makes the full sign-in possible, and the one most likely to change. The log (`%TEMP%\loopsegments-quest-lantab.log`, lines starting `SKYBOX:`) shows which case you are in:

| If SKYBOX... | What you see | What the companion does | Workaround |
|---|---|---|---|
| **encrypts saved passwords** | **Loop Segments** shows in Network but asks for the login, or fails to sign in. The log still says `added` | Writes the plain password anyway; SKYBOX cannot use it. No harm to other servers | Use a blank password: the server still appears and SKYBOX asks for the username and password when you open it (tested with 2.0.2). Type them once per session; the close-time removal deletes what SKYBOX saved. Today that needs a one-line change (`-Password ''` in `Invoke-QuestSkyboxWebDavSession`); there is no setting for it yet |
| **renames the table or columns** | `SKYBOX: database read failed: ...` | Reads fail before any edit, so nothing is pushed; retried (and logged) every ~20 s while the companion runs | Pull a copy (`adb pull <path>`), look at the schema (`sqlite3 SkyboxDataBase .schema`), add one WebDAV server by hand and compare, then update [`QuestSkybox.ps1`](QuestSkybox.ps1) |
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
3. `adb mdns services` → the wireless-debugging TLS port (random, e.g. `10.0.100.238:37275`).

**Use wireless debugging (mDNS); leave `questAdbHost` empty.** It needs no config and keeps working across reboots. It works once this PC is paired: if `adb mdns services` lists the headset but `adb connect` fails with an auth error, pair once: on the headset, Settings → System → Developer → **Wireless debugging** → *Pair device with pairing code*, then `adb pair <ip>:<pairing-port>` and type the code.

**Optional fallback, fixed port 5555.** Only needed if mDNS discovery does not reach this PC (for example a VPN or Clash/mihomo TUN swallowing the multicast announcement, or the PC and Quest on different subnets), or if another tool insists on `IP:5555`. With the Quest on USB run `adb tcpip 5555`, then set `"questAdbHost": "<headset Wi‑Fi IP>"` in `windows\loop-segments-windows.json` (a DHCP reservation on the router keeps the IP stable). Limits: **a reboot closes 5555 again** (ADB Auto-Enable restores only the wireless-debugging port, and keeping 5555 needs root: `setprop persist.adb.tcp.port 5555` is refused on a stock Quest), and 5555 traffic is not encrypted (wireless debugging is). The script still falls back to mDNS when `IP:5555` does not answer.

### 6. Test

With the headset awake, from `windows\`:

```powershell
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://<phoneLanHost>:8765/ -Once           # open, signed in
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://<phoneLanHost>:8765/ -Once -WaitMinutes 7   # wait for wake, like the button
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://<phoneLanHost>:8765/ -EnsureFlags    # flag check only
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://<phoneLanHost>:8765/ -ClearHistory   # history only, all time
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -EnableProximity                                 # proximity sensor back on
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://<phoneLanHost>:8765/ -SkyboxWebDavSession -ParentPid $PID   # keep the SKYBOX server (Ctrl+C to stop)
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
| `questIncognito` | `false` | `true` = private tab (no immersive WebXR there) instead of the normal tab |
| `questSendLanLogin` | `true` | Sign the tab in with the LAN login (`false` = sign in on the headset) |
| `questEnsureInsecureOriginFlag` | `true` | Startup and each Open on Quest: keep the insecure-origin flag on the phone origin(s); may restart Quest Browser |
| `questClearHistoryOnExit` | `true` | Companion close: clear Quest Browser history (History only, All time) |
| `questCloseLanTabsOnExit` | `true` | Companion close: close Quest Browser tabs on the phone LAN page (before the history clear) |
| `questSkyboxWebDav` | `true` | Companion session: keep the phone in SKYBOX as WebDAV server **Loop Segments** (signed in), following the phone address and LAN login; removed at close. Restarts SKYBOX (if open) only when the server changes |
| `questKeepAwakeDuringSession` | `true` | Hold the proximity sensor off while the companion runs (headset stays awake for the close-time history clear); turned back on at cleanup |
