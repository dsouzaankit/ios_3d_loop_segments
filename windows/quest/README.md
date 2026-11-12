# Quest: Open on Quest, flags, history

The PC companion drives **Quest Browser** over **adb over Wi-Fi** and the browser's DevTools socket (the one `chrome://inspect` uses). Everything goes through [`Watch-LoopSegmentsQuestLanTab.ps1`](Watch-LoopSegmentsQuestLanTab.ps1) (helpers in [`QuestDevTools.ps1`](QuestDevTools.ps1), companion hooks in [`QuestCompanionHooks.ps1`](QuestCompanionHooks.ps1)). Log: `%TEMP%\loopsegments-quest-lantab.log`.

| When | What | Setting |
|------|------|---------|
| **Open on Quest** click (PC LAN page) | Check the flag (below), then open the LAN page in a **normal tab, signed in** | `questSendLanLogin`, `questIncognito` |
| Companion **startup** | Hidden, in the background: make sure the insecure-origin flag lists the phone LAN origin(s) | `questEnsureInsecureOriginFlag` |
| Companion **startup**, until close | Keep the headset **awake**: proximity sensor held off once the headset is on adb | `questKeepAwakeDuringSession` |
| Companion **close** (normal finish and the console-X watchdog) | Close Quest Browser **tabs on the phone LAN page**, clear **history** (History only, All time), then turn the **proximity sensor back on** | `questCloseLanTabsOnExit`, `questClearHistoryOnExit`, `questKeepAwakeDuringSession` |

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
| `questKeepAwakeDuringSession` | `true` | Hold the proximity sensor off while the companion runs (headset stays awake for the close-time history clear); turned back on at cleanup |
