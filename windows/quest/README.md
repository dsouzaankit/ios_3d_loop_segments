# Quest: Open on Quest, flags, history

The PC companion drives **Quest Browser** over **adb over Wi-Fi** and the browser's DevTools socket (the one `chrome://inspect` uses). Everything goes through [`Watch-LoopSegmentsQuestLanTab.ps1`](Watch-LoopSegmentsQuestLanTab.ps1) (helpers in [`QuestDevTools.ps1`](QuestDevTools.ps1), companion hooks in [`QuestCompanionHooks.ps1`](QuestCompanionHooks.ps1)). Log: `%TEMP%\loopsegments-quest-lantab.log`.

| When | What | Setting |
|------|------|---------|
| **Open on Quest** click (PC LAN page) | Check the flag (below), then open the LAN page in a **normal tab, signed in** | `questSendLanLogin`, `questIncognito` |
| Companion **startup** | Hidden, in the background: make sure the insecure-origin flag lists the phone LAN origin(s) | `questEnsureInsecureOriginFlag` |
| Companion **close** (normal finish and the console-X watchdog) | Clear Quest Browser **history** (History only, All time) | `questClearHistoryOnExit` |
| Companion **close** (same) | Turn the Quest **proximity sensor** back on | `questEnableProximityOnExit` |

Each step is skipped (and logged) when the headset is not on adb.

## Open on Quest: normal tab, signed in

1. VIEW intent for `http://<phone>:8765/` (retried: the browser sometimes drops the first one) opens a new normal tab at the login prompt.
2. Over DevTools, that tab is sent to `http://admin:<password>@<phone>:8765/` (the browser caches the LAN login), then back to the plain URL, and its back/forward list is reset so **Back** never leads to the URL with the password.
3. The page is signed in, its URL has no password, `fetch()` works (`status_lists.json`), and **WebXR immersive VR/AR is available**.

Why not a private tab: **Quest Browser disables immersive WebXR in private tabs** (`isSessionSupported("immersive-vr")` is false there and true in a normal tab), so the XR player cannot enter VR from one. `"questIncognito": true` (or `-PrivateTab`) still opens a private tab instead (Chromium `IncognitoTabLauncher` + typed URL; falls back to a normal tab). Why the reload: a page whose URL contains `user:pass@` cannot `fetch()` (Chromium refuses URLs with credentials).

The password comes from `webdavPassword` in `windows\loop-segments-windows.json`, or from the matching `phoneLanHosts[].webdavPassword`. It is percent-encoded, read by the script itself (never on a command line), and never logged. Chromium does not keep the `user:pass@` form in browsing history. `"questSendLanLogin": false` (or `-NoLanLogin`) opens the plain URL and you sign in as `admin` / the app password on the headset.

## chrome://flags: insecure origin as secure

Quest WebXR over LAN `http://` needs `chrome://flags/#unsafely-treat-insecure-origin-as-secure` **Enabled** with the phone's origin listed. The script reads the flag on a helper tab (a no-login phone page, `/xr-assets/aframe.min.js`, closed afterwards). If a phone LAN origin is missing (`phoneLanHost` / `phoneLanHosts` with `lanPort`, plus the companion's current phone address) it **adds** it, keeping the origins already there. It then enables the flag, **restarts Quest Browser** (flags apply only after a restart), and confirms the value after the restart. Nothing changes and nothing restarts when the flag already covers every origin. **The restart closes open Quest Browser tabs** (Quest does not restore them). Manual run: `-EnsureFlags`.

## Proximity sensor on companion close

If the proximity sensor was switched off (`adb shell am broadcast -a com.oculus.vrpowermanager.prox_close`, which makes the headset act as if worn and never sleep), the companion turns it back on when it quits: `am broadcast -a com.oculus.vrpowermanager.automation_disable`, then checks that `dumpsys vrpowermanager` reports `Virtual proximity state: DISABLED` (no override, real sensor in charge). Harmless when the sensor is already on. Manual run: `-EnableProximity`. Set `"questEnableProximityOnExit": false` to leave it as it is.

## Clear history on companion close

Uses the browser's own **Clear browsing data** dialog: ticks **History only**, picks **All time**, presses **Clear data**, then puts the dialog's previous ticks and time range back. **Cookies, cache, saved passwords, form data and site settings are kept.** This deletes your **whole** Quest Browser history, not only Loop Segments pages. If Quest Browser is not running, a helper tab opens it first (that visit is cleared too). Manual run: `-ClearHistory`. Set `"questClearHistoryOnExit": false` to keep history.

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

Wireless adb gives full shell access to the headset: keep it on your home LAN only, and never port-forward it.

### 5. How the PC finds the headset

The script tries, in order:

1. a Quest already listed by `adb devices -l` (or `questAdbSerial`);
2. `adb connect <questAdbHost>:<questAdbPort>` (default `5555`) when `questAdbHost` is set;
3. `adb mdns services` → the wireless-debugging TLS port (random, e.g. `10.0.100.238:37275`).

Pick one:

- **Wireless debugging (mDNS, no config):** works once this PC is paired. If `adb mdns services` lists the headset but `adb connect` fails with an auth error, pair once: on the headset, Settings → System → Developer → **Wireless debugging** → *Pair device with pairing code*, then `adb pair <ip>:<pairing-port>` and type the code.
- **Fixed port 5555:** with the Quest on USB run `adb tcpip 5555`, then set `"questAdbHost": "<headset Wi‑Fi IP>"` in `windows\loop-segments-windows.json` (a DHCP reservation on the router keeps the IP stable). The ADB Auto-Enable status screen shows which ports are active after a reboot.

### 6. Test

With the headset awake, from `windows\`:

```powershell
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://<phoneLanHost>:8765/ -Once           # open, signed in
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://<phoneLanHost>:8765/ -EnsureFlags    # flag check only
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://<phoneLanHost>:8765/ -ClearHistory   # history only, all time
pwsh -File quest\Watch-LoopSegmentsQuestLanTab.ps1 -EnableProximity                                 # proximity sensor on
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
| `questEnableProximityOnExit` | `true` | Companion close: turn the proximity sensor back on (undo `prox_close`) |
