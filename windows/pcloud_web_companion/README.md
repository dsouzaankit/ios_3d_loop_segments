# Loop Segments PC companion (`pcloud_web_companion`)

Windows **PC companion** for Loop Segments: Chromium + MV3 extension (folder still `pcloud_web_companion`) that intercepts pCloud downloads, cancels the **downloads shelf**, copies the URL + filename, and queues an export on the Loop Segments iOS LAN API, plus Quest control, rclone, and related session hooks. **CDN view tabs stay open** (Open Original / inline play). “Web companion” in older notes means this same module — not a browser on Quest or iOS.

## What it does

**CDN view tabs** (Open Original, inline play, or a Download that opened a tab): the companion **does not close** them. **Downloads** on the shelf are still cancelled immediately. Either path still posts the same Loop Segments export (folder + name). Duplicate tab+download is deduped. **Refreshing a tab with the same full href** does not post again (this Chromium session) — no export reset and **`parked/` is not touched**. A **new signed URL** still posts; if that clip is already running, the phone parks root media then restores it and **continues from the checkpoint** (other titles in `parked/` stay).

On a **single-file** pCloud download click:

1. Cancels the Chromium **download** immediately (shelf), then removes it from the shelf. Any new CDN tab stays open.
2. Resolves the open my.pcloud `folder=` id to a folder **path/name** via `listfolder` / parent walk — `folderPath` is the full pCloud path (root segment kept). API host is derived from the download CDN domain when possible (`pnyc1.pcloud.com` → `apinyc1.pcloud.com`), with `api.pcloud.com` / `eapi` as fallbacks
3. If `folderPath` is missing/garbled (e.g. search UI text like `"darina" in "/All Files/"`), runs **right-click → Open Location** on the file, then re-resolves; falls back to pCloud `search` API if needed
4. Copies clipboard lines: download URL, filename, folder path, folder name (when known)
5. If the phone LAN page is up: `POST /export_from_folder.json` with `{ folderPath, displayName, seekMs, id }` only — CDN download URLs are **not** posted to the phone. If `:8765` is down (companion still doing USB/LAN recover): **queue locally**, desktop notification **waiting for LAN**, retry ~every minute; after **~5 minutes** **deny** with a notification. When LAN returns, pending items are POSTed automatically.
6. After a successful POST, reuses (or opens) `http://<phoneLanHost>:8765/` in a **background** tab without stealing focus from pCloud. **At companion launch**, that LAN URL is already opened as Chromium’s **2nd CLI tab** (pCloud stays focused) — not by the extension.

On **multi-select Download** (pCloud builds a **zip archive**):

1. Cancels the archive download (not used by the phone)
2. Reads recently captured selection `fileid`s from `getthumbslinks` / `getziplink` (`webRequest` + MAIN-world fetch/XHR hook)
3. Resolves each video via pCloud `getpath` / `stat` + **parent folder path** → `{ folderPath, displayName }` (name-only fallback forces a slow bookmark WebDAV walk and often misses deep files)
4. `POST /export_queue.json` with `{ mode: "prepend", startFirst: true, items: […] }` — phone FIFO; first item soft-pauses any running export → that clip goes to **Paused** (parked) and is **not** auto-resumed when later queue items finish
5. Remaining items show under the app **Queued** tab until idle (finish/Stop drains; user Pause holds). The first item’s folder resolve must finish before the rest can start (otherwise a slow resolve can park #2 on **Paused**). Resume interrupted titles manually from **Paused** / LAN. If a file is missing from its saved folder, the phone skips it onto **Paused** as **Unavailable** (first rejected ack: desktop toast **Loop Segments: skipped `<name>`**).

**Tip — select only videos in my.pcloud.com:** the web UI can filter the current folder by type. Click the **`v`** (view / type filter) control, then pick one of the **five** type filters (including **Video**). With **Video** active, multi-select + Download queues video files for Loop Segments without grabbing photos/docs from the same folder.

**Not supported — folder right-click → Download:** that also builds a zip, but pCloud does not expose per-file `fileid`s the way multi-select does. The companion still **cancels** the zip, then shows a desktop notification (**no selection ids**) and does **not** expand the folder into FIFO items. To queue a whole folder: open it → filter **Video** → select the files (or Select all) → **Download**.

**Open this folder in pCloud Drive** (extension **1.7.15+**, companion sink must be running on `127.0.0.1:18765`). Resolves the my.pcloud.com folder (tree node `folder=` URL, current tab, or right-clicked node) to a pCloud path, maps **All Files** → the pCloud Drive root, and opens it in Explorer **in the foreground**. Drive letter comes from **`HKCU\SOFTWARE\pCloud` `SyncDrive`**, then a volume labeled **pCloud Drive** (pCloud picks the next letter if `P:` is taken). Each launch **pins the extension to the Chromium toolbar** and binds **Ctrl+E** (that replaces Chromium’s default Ctrl+E search; change it in `chrome://extensions/shortcuts` if needed). my.pcloud.com **blocks the browser context menu** (its own file menu uses `preventDefault` and often starts on right-button `pointerdown`); **Shift+right-click** stops those page handlers so Chrome’s menu can show → **Open this folder in pCloud Drive**. Same action: toolbar popup → **Open pCloud Drive folder**, or **Ctrl+E**. Restart the companion after an extension update so the MAIN-world hook reloads. Online-only folders still open if the Drive shows them; if the path is not on the Drive yet, Explorer opens the nearest existing parent. **1.7.14:** force Explorer above Chromium (TOPMOST flip; no success toast that stole focus). **1.7.13:** ShellExecute open + reuse existing window.

**Write hybrid `media_files.txt` for 3d_playlist_local** (**1.7.21**, companion sink on `127.0.0.1:18765`):

1. On my.pcloud.com, multi-select **video** tiles (`div.selected` with nested `div.playButton`; `data-id="f…"` per file).
2. Trigger any of:
   - **Ctrl+Shift+H** (H = hybrid; pinned on launch — see shortcut note below)
   - Toolbar popup → **Write hybrid media_files.txt**
   - **Shift+right-click** on the page → **Write hybrid media_files.txt** (same bypass as Explorer jump)
3. Extension collects fileids, resolves each via pCloud `getpath`/`stat`, maps to full **pCloud Drive** paths (`.mp4`/`.mkv`/`.wmv`/`.ts` only), and **overwrites** `{SyncDrive}\p_cld_media\web_compann_plst\media_files.txt` (override: env `WEB_COMPANION_MEDIA_LIST` or `lan_config.json` → `webCompanionMediaListFile`).
4. Sink opens `web_compann_plst` in Explorer after a successful write (foregrounds if already open; selects `media_files.txt`). Desktop notification reports written count and paths missing on Drive.
5. Run any batch launcher beside that hub (`run_batch_vr_hybrid.ps1`, `run_batch_fisheye_v360.ps1`, `run_batch_convert_streamTo3D.ps1` + `3d_playlist_local\`). Batch reads absolute paths; clips need not live in the hub folder.

**Hub layout** (deploy via `3d_playlist_local\setup_script_files.py` → `P:\p_cld_media\web_compann_plst`):

```
{SyncDrive}\p_cld_media\web_compann_plst\
  media_files.txt              ← companion overwrite (absolute Drive paths, one per line)
  run_batch_vr_hybrid.ps1
  run_batch_fisheye_v360.ps1
  run_batch_convert_streamTo3D.ps1
  3d_playlist_local\
```

Do not store source videos inside `web_compann_plst\` (only the list + scripts). Online-only pCloud files are written to the list even when not yet hydrated locally; batch `Test-Path` skips missing clips until SyncDrive catches up.

**Shortcut note:** Chrome disallows `Ctrl+Alt+*` in extension manifests (`Invalid value for 'commands…'`). Avoid `Ctrl+Shift+D` (pCloud download), `Ctrl+D` (bookmark), `Ctrl+Shift+W` (close window), and `Ctrl+Shift+P` (DevTools command menu when DevTools is open).

**Dev reload** (Chromium can stay open):

```powershell
cd <repo>\windows\pcloud_web_companion
.\Sync-Reload-PCloudWebCompanionDev.ps1
```

Then `chrome://extensions` → Reload → refresh my.pcloud.com.

## Run

Integrated under **`windows\pcloud_web_companion`** (preferred):

```powershell
cd <repo>\windows
.\setup\Setup-LoopSegmentsWindows.ps1    # once per PC (pwsh)
.\pcloud_web_companion\Run-PCloudWebCompanion.ps1
```

Prefer **`Run-PCloudWebCompanion.ps1`** (wrapper: Enter-on-error, forwards flags). Files starting with `_` are internal helpers it runs or dot-sources (`_run_chromium.ps1`, `_rest_log_sink.ps1`, `_profile_exit_watchdog.ps1`, ...), so in Explorer the one to run is the only `Run-` file. To start it from Start or the taskbar, pin a shortcut to it (a `.ps1` cannot be pinned): target `"C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "<this folder>\Run-PCloudWebCompanion.ps1"`, then *Pin to Start* / *Pin to taskbar*; or right-click the file → *Add to Favorites* for Explorer's Home. `_run_chromium.ps1` is the implementation — fine from a **pwsh** prompt; avoid Explorer “Run with PowerShell” / double-click on it (Windows PowerShell 5.1). Entry scripts are UTF-8 with BOM so a 5.1 start can re-launch under `pwsh` instead of flash-closing.
| Flag | Effect |
|------|--------|
| `-RecreateVenv` | Recreate machine-local venv under `%LOCALAPPDATA%\pcloud_web_companion\venv` |
| `-ForceDeps` | Reinstall pip deps + Chromium |
| `-NoLaunch` | Setup + USB launch only (no Chromium) |
| `-SkipUsbLaunch` | Do not run `usb\Launch-LoopSegmentsViaUsb.ps1` |
| `-UsbLaunchMount` | Remount Developer Disk Image (default skips mount) |
| `-SkipRcloneMount` | Do not open `rclone\Mount-LoopSegmentsRclone.ps1` (default attempts mount when LAN is up) |
| `-EnableRcloneDlna` | Start `rclone\Serve-LoopSegmentsRcloneDlna.ps1` (phone WebDAV as DLNA for Skybox **Network**). **Off by default:** DLNA has no password, and it lists the phone's folders to anyone on the LAN (media files themselves need no login on the phone either). `-SkipRcloneDlna` is still accepted and does nothing extra |
| `-SkipGatewayReboot` | Do not check/reboot LAN gateway (wrong-subnet, low-throughput, or off-subnet recovery when LAN page unreachable) |
| `-SkipLanThroughput` | Do not time a media copy off `L:` after mount (default: up to 64 MB → Mbps) |
| `-SkipWanThroughput` | Do not POST `/wan_throughput.json` after phone LAN is up (default: ~30 s random pCloud Range ≥375 MB → Mbps) |
| `-SkipLowThroughputGatewayReboot` | Do not reboot other routers / re-check when LAN throughput is below `minLanThroughputMbps` |
| `-SkipProfileSync` | Do not sync Chromium profile to/from repo |
| `-DetachChromium` | Do not wait for browser exit (upload + local clear on next run) |
| `-KeepLocalProfile` | Do not wipe local AppData profile after upload |
| `-SkipGoHome` | Never press iPhone Home on companion finish (default still skips when the app is already backgrounded or the phone is locked) |
| `-SkipWifiWwwProbeOnQuit` | Do not POST `/wifi_www_probe.json` before Home (default: on-device Wi‑Fi-only www check; on fail bounce the phone LAN AP via `-BouncePhoneLanAp`, unless an export is running or the pending queue is non-empty; while the Quest after-quit history helper is waiting, the bounce is held and that helper runs it after the delete or its 2 h give-up) |
| `-NoDarkMode` | Do not force Chromium UI dark mode (default: `--force-dark-mode` only) |
| `-SkipSkybox` | Do not check/start SKYBOX VR desktop (default: start if idle, hide to tray) |
| `-SkipVirtualDesktop` | Do not check/start Virtual Desktop Streamer (default: start if idle, hide to tray) |
| `-SkipClashMdnsRoute` | Do not try to drop Clash/mihomo TUN multicast when Clash is running |
| `-EnsureAltServer` | Opt-in: print/start **AltServer** for AltStore ~7-day refresh (default **skips** — SideStore + LocalDevVPN) |
| `-SkipOpenLanTabOnStart` | Do not open `http://<phoneLanHost>:8765/` as a 2nd background tab at Chromium launch (default opens it; focus stays on pCloud) |
| `-NoTranscript` | Do not `Start-Transcript` to `logs\companion-console-*.log` (default on) |
| `-StartUrl "..."` | Override start page (default `https://my.pcloud.com`) |

Each launch:

- Ensures a **machine-local** venv at `%LOCALAPPDATA%\pcloud_web_companion\venv` (Python 3.12 preferred; removes any legacy repo `.venv` on P:)
- Syncs LAN host/auth from `windows\loop-segments-windows.json` → `lan_config.json`. **`phoneLanHostSource`** super-config (`usb` \| `config`, default `config`; mirrored by `preferUsbPhoneLanHost`): set **before** companion with `..\setup\Set-LoopSegmentsPhoneLanHostSource.ps1` (bare run toggles; `-Usb` / `-Config` / `-Show`). `usb` = current Wi‑Fi read over USB (the phone's network monitor: its own address on `en0`; then its Wi‑Fi hardware address looked up in this PC's ARP table after one ping sweep of its own /24s (exact when they share a network); pcapd sniffing as the last fallback) for companion + gateway/recover **without** overwriting config `phoneLanHost`; `config` = force saved IP/subnet. No LAN TCP scan. Subnet align stays in gateway reboot / `Invoke-LoopSegmentsPhoneLanRecoverIfNeeded`
- Copies the extension to `%LOCALAPPDATA%\pcloud_web_companion\extension` (Chromium will not load unpacked extensions from the pCloud `P:` drive), then **pins it on the toolbar** and sets **Ctrl+E** + **Ctrl+Shift+H** in the profile `Preferences` (Python JSON, not PowerShell `ConvertTo-Json`)
- Starts the local REST sink on `127.0.0.1:18765` (`_rest_log_sink.ps1`, hidden): the extension's helper for what a browser extension cannot do itself (log file, proxy-free phone LAN calls, Open on Quest, Explorer, Drive paths, console focus). See [REST sink lifetime](#rest-sink-lifetime)
- **Gateway Wi‑Fi reboot (when needed):** compares the PC’s IPv4 default gateway to `phoneLanHost` (app LAN page). If they are **not** on the same subnet, it first switches the PC's Wi‑Fi to a saved network on the `phoneLanHost` /24 (`netsh`, about 5 s, no router reboot). Only if no saved network reaches it, it informs you, waits for **tcp/23**, **reboots Wi‑Fi on the current gateway**, then **polls up to ~20s** for a new PC LAN IP/gateway (or tcp/23 back after a drop — Windows can keep a stale lease while the AP is down; Clash TUN often changes the default route sooner). Then **re-checks** — up to **3** rounds. A failed telnet (host unreachable while the AP is still restarting) waits and retries once, then continues to the next round instead of aborting. Then fails and **waits for Enter** (`-SkipGatewayReboot` to skip). This still runs **before** Chromium so pCloud is not dropped mid-browse. Must run from `windows\lan\` (needs `windows\lib\`).
- **Starts Chromium early** (after gateway check + profile sync) so you can use my.pcloud.com while USB/LAN recover/rclone continue in the companion console. Passes **pCloud then** `http://<phoneLanHost>:8765/` as Chromium start URLs so the LAN monitor is a **2nd tab** with **focus on pCloud** (`-SkipOpenLanTabOnStart` to skip). Extension does **not** open a startup LAN tab (that raced and duplicated tabs). If `:8765` is down, the extension **queues** intercepted downloads locally (desktop notification) and retries about once a minute; after **~5 minutes** it **denies** them with another notification. When LAN comes up, queued exports are POSTed automatically. **Click a toast** to bring the companion PowerShell window to the front.
- **Open on Quest (LAN page button):** on the phone LAN page in this Chromium, the extension (`lan_quest_button.js`) adds an **Open on Quest** button next to **Night mode**. A click first opens the companion's Quest control page (SKYBOX buttons, LAN bandwidth test) in a tab here at `http://127.0.0.1:18766/` (LAN stays in front; signed in by the extension; port and login from `lan_config.json`), then goes extension -> local sink `POST 127.0.0.1:18765/quest-open-lan-tab` (needs the `X-LoopSegments-Companion: 1` header, so ordinary web pages cannot trigger it) -> hidden `..\quest\Watch-LoopSegmentsQuestLanTab.ps1 -Once`, which opens that LAN page in **Quest Browser** over adb in a **normal tab, signed in** (normal because Quest disables immersive WebXR in private tabs). It reuses an already open LAN tab instead of opening a new one per click. When the open **succeeds**, it **POSTs `/keep_alive.json`** (`action=extend`, build **440+**) to **add 60 min** to the phone Keep Alive session. The button says what it opened. If the headset is asleep or off adb, the click is **queued** for 7 minutes and the page opens when the headset wakes. **Quest hooks:** each Open on Quest reads `isSecureContext` in the opened LAN tab and fixes Quest's insecure-origin `chrome://flags` entry only when it is false (adds the phone origin, restarts Quest Browser, reopens the page), while the companion runs it holds the Quest **proximity sensor off** (once the headset is awake; it leaves one in standby asleep) so the headset stays awake on adb and serves the **Quest control page** on this PC's LAN address (port 18766, signed in with the phone LAN login; Open on Quest opens it on the headset next to the LAN page) with **SKYBOX Push / Update / Clear** buttons for the phone as WebDAV server **Loop Segments**, and on close (also the console-X watchdog) it closes the Quest Browser tabs on the LAN page, deletes the Quest Browser **history entries on the LAN page and the control page** (other history is kept; if that fails, all history from the last 24 hours is cleared instead, and if that also fails because nobody is wearing the headset, a background helper deletes the entries once you put it on, within 2 h), stops the control page, removes the Loop Segments entries from SKYBOX (phone WebDAV servers and the rclone DLNA entry), then turns the sensor back on (`questControlPage` / `questSkyboxWebDav` turn those parts off; SKYBOX restarts, if open, only when the server changes). Details, setup (developer mode, adb, [adb-auto-enable](https://github.com/project-SIMPLE/adb-auto-enable), pairing) and settings: [`../quest/README.md`](../quest/README.md).
- **SKYBOX VR desktop:** after Chromium is up, companion dotsources repo-root **`Skybox_vr_pc`** (`Start-SkyboxVrPcProcess` / `Map-SkyboxVrPcShare` / `Unmap-SkyboxVrPcShare`) — starts SKYBOX if idle, hides to tray, and maps AirScreen shares from that submodule’s `skybox_vr_pc.config.json` (default **`P:\p_cld_media`** as `p_cld_media`; also `3d_fullsbs_trans` when listed). **Does not** map the rclone `L:` / `pcld_ios_media` mount into AirScreen. Phone media for Quest is **`rclone serve dlna`** (see below). Hide-to-tray is a short first-show pass (Skybox recreates its window a few times); it **does not keep hiding** after the window has stayed in the tray, so a manual restore from the notify icon sticks. Missing install only warns. `-SkipSkybox` to skip. Companion quit/abort **unmaps AirScreen shares while Skybox is still up** (and clears any stale phone-rclone Add-folders), then **quits SKYBOX if this companion (or a prior companion that left a start marker) started it**. A new companion run **keeps** that marker while SKYBOX is still running so a crash/relaunch does not orphan the client.
- **Virtual Desktop:** after Skybox, **starts Virtual Desktop Streamer if it is idle** (starts **Virtual Desktop Service** if that service is stopped; does not bounce a running service or quit a running Streamer) and **hides the Streamer window to the tray**. Retries ~30s as the window appears. Missing install only warns. `-SkipVirtualDesktop` to skip. Companion finish does **not** quit Streamer.
- **Clash / mihomo:** optional UAC for `env_setup\altserver_refresh\VpnMulticast\Remove-VpnMulticastRoute.ps1` so TUN does not steal `.local` mDNS. Phone-IP (read over USB) and `:8765` (numeric `phoneLanHost` + local sink) do not need it. `-SkipClashMdnsRoute` to skip. Details: [`../../env_setup/Clash/README.md`](../../env_setup/Clash/README.md) (profiles) and [`../../env_setup/altserver_refresh/README.md`](../../env_setup/altserver_refresh/README.md) (drop).
- **USB-launches Loop Segments** via `..\usb\Launch-LoopSegmentsViaUsb.ps1` **after Chromium starts**. **Skips USB launch entirely** when the phone LAN page is up **and** `pcloud_list.json` reports **signedIn** (pCloud credentials on the phone) — leaves a Keep Alive / lock-screen session alone. Otherwise: **foregrounds briefly** to bring `:8765` up (DVT **`--no-kill-existing`**; skips relaunch when already foreground), **waits until the LAN page is reachable** (up to ~60 s (skipped when the phone's Wi-Fi address, read over USB, is off the phone LAN's /24: it cannot answer there, so LAN recover runs right away and moves it back)), then **USB Home** backgrounds the app again so Keep Alive can hold LAN. **Locked (exit 3)** no longer aborts Chromium (warns instead). If USB is missing / launch fails, Chromium stays open and the plugin queues until `:8765` is up. Use `-SkipUsbLaunch` for Chromium only; `-SkipGoHome` also skips the post-launch background. **AltServer is skipped by default** (SideStore path). Pass **`-EnsureAltServer`** to print status and start AltServer when installed but idle (`..\env_setup\altserver_refresh` via `..\lib\Get-LoopSegmentsAltServer.ps1`). If the app becomes unavailable after ~7 days: **SideStore** (LocalDevVPN → Refresh) or **AltServer → USB → AltStore Refresh All** → **Settings → General → VPN & Device Management → Developer App → Trust → open once**.
- **Attempts rclone mount** via `..\rclone\Mount-LoopSegmentsRclone.ps1 -Quick` in a **separate** console after Chromium is up (preferred letter from `loop-segments-windows.json` `mountDriveLetter`, default `L:`). Explorer/scripts only — **not** mapped into Skybox AirScreen. If that letter is taken, a **random free D–Z** is chosen and saved. After the letter appears, that script notifies Explorer so **This PC** shows it without F5; it notifies again when the mount window exits or LAN-watch unmaps it. **`..\lan\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1`** runs **in-process** (no nested `pwsh` from `P:`) and uses USB/`pcapd` to check the phone vs PC subnet (`env_setup\lan`), then waits for the LAN page; if USB is missing and `:8765` stays down, it **reboots off-subnet routers** (ROUTER_IPs outside `phoneLanHost`’s subnet) and waits again. Failures only warn. Mount polls phone LAN and auto-kills rclone after ~60s outage. Log: `%TEMP%\loopsegments-rclone-mount.log` (copied to `..\rclone\loopsegments-rclone-mount.log` on quit). Use `-SkipRcloneMount` to leave mounting to `Mount-PhoneL.cmd`. Mount window is minimized and does not steal Chromium focus — **Ctrl+C** there (taskbar / Alt-Tab) to unmount. Use `-SkipGatewayReboot` to skip off-subnet recovery too.
- **rclone DLNA serve (opt-in, `-EnableRcloneDlna`):** off by default because `rclone serve dlna` has no password option and lists the phone's folders to anyone who can reach the PC on its port. With the switch, the companion runs `..\rclone\Serve-LoopSegmentsRcloneDlna.ps1 -Quick -Hidden` after the mount attempt (phone WebDAV → `rclone serve dlna`, default `:7879` / name `Loop Segments` from `rcloneDlnaAddr` / `rcloneDlnaName`). **No extra console** — status is `[rclone-dlna]` in this companion window. Quest Skybox **Network** should discover it on the same LAN. Why DLNA, and how it compares with WebDAV direct to the phone: [Getting phone media into Skybox on Quest](../rclone/RCLONE-PHONE-MOUNT.md#getting-phone-media-into-skybox-on-quest). Does not require WinFsp/`L:`. Log: `%TEMP%\loopsegments-rclone-dlna.log`. Use `-SkipRcloneDlna` to skip. Companion finish (or `Serve-LoopSegmentsRcloneDlna.ps1 -Remove` / double-click **`Serve-PhoneDlna.cmd -Remove`**) stops serve. For a visible titled console, run `Serve-PhoneDlna.cmd` yourself (omit `-Hidden`). **If DLNA playback stutters:** prefer **[3d_playlist_local](https://github.com/dsouzaankit/3d_playlist_local)** → **`3d_fullsbs_trans`** AirScreen (older AirScreen-of-`L:` never played in Skybox); details in [`../rclone/RCLONE-PHONE-MOUNT.md`](../rclone/RCLONE-PHONE-MOUNT.md).
- **WAN throughput probe:** after USB/rclone, POSTs `/wan_throughput.json` on the phone (random pCloud video ≥**375 MB**, ~**30 s** WebDAV Range → Mbps). Result shows on the LAN page (poll) and `%TEMP%\loopsegments-wan-throughput.json`. `-SkipWanThroughput` to skip.
- **LAN throughput probe:** after mount attempt, runs `..\lan\Measure-LoopSegmentsLanThroughput.ps1` (random media under `pcld_ios_media\archive\` ≥ min size, default **64 MB** transfer cap). Prefers HTTP + rclone copy when `${mountDriveLetter}:\` is up (`Test-Path`); if the letter is not ready it **warns and runs HTTP-only**. Prints Mbps, recommends a **max media bitrate** for minute segments (80% of LAN), and writes sidecars for `run_batch_vr_hybrid.ps1`. If Mbps is below `minLanThroughputMbps` (default **40**), reboots Wi‑Fi on **other** known routers (not this PC’s app-LAN gateway), waits to settle, and re-measures — up to **2** retries. Chromium stays open. Low Mbps on the right subnet is **suspected Wi‑Fi channel congestion from neighboring routers**. The app LAN gateway is **tethered to a primary router**; those two APs must use the **same Wi‑Fi channel** (see [`../README.md`](../README.md#app-lan-vs-primary-router)). **Do not run the probe during an active Virtual Desktop headset session** — VD streaming uses ~**50 Mbps** of LAN and will understate phone capacity. Use `-SkipLanThroughput` or `-SkipLowThroughputGatewayReboot` to skip.
- **Profile sync:** zip the local AppData profile (**Cache / Code Cache / GPU / Safe Browsing / Service Worker** left out) → copy one **`chromium-profile.zip`** onto P: (Windows Explorer–readable zip, not `tar.exe`’s `./` layout which looks empty). On start, copy that zip off P: and extract locally. If the zip is missing, a one-time copy of the old unpacked `chromium-profile\` folder still runs (same cache dirs skipped); after a successful zip upload that unpacked tree is **deleted in the background**. Empty local never uploads over P:. Use `-KeepLocalProfile` to skip the local wipe. Zip and folder are gitignored.
- Closes any prior profile Chromium, clears tabs/session + download history (**cookies kept**)
- Launches Chromium (from `%LOCALAPPDATA%\ms-playwright`, or `LOOP_SEGMENTS_PLAYWRIGHT_BROWSERS`) with the extension loaded and **Chromium UI dark mode** (`--force-dark-mode`; `-NoDarkMode` to disable). Page auto-darkening (`WebContentsForceDark`) is not used — it can hide media seekbars. `--disable-infobars` hides the *Chrome for Testing … is only for automated testing* bar that Playwright's Chromium (a Chrome for Testing build) shows on every window; `--test-type` does not hide it. `--disable-features=...,LaunchOnStartup` hides the *Begin browsing instantly: Chromium can now launch when Windows starts* infobar, which `--disable-infobars` does not cover (one `--disable-features` list: Chromium uses only the last such switch). Waits for exit unless `-DetachChromium`
- **Graceful quit:** close the browser, **Ctrl+C**, or console **X** — kills this profile’s Chromium, **unmaps Skybox Add-folders** (AirScreen **`p_cld_media`** / configured shares; clears any stale phone-rclone maps) while SKYBOX is still up, then **quits SKYBOX only if this session started it**, uploads the profile **zip** to P:, clears local AppData (`_profile_exit_watchdog.ps1` covers console X), **stops the phone rclone mount + DLNA serve in-process** (kill rclone + consoles; no `Remove-PSDrive` / `Test-Path` on a wedged WinFsp letter), then **POSTs `/keep_alive.json`** (`reason=companion_quit`) to **reset Keep Alive to 60 min** on the phone (build **440+**; skipped while an export owns Keep Alive), then **POSTs `/wifi_www_probe.json`** (on-device Wi‑Fi-only www; cellular blocked) **before** USB Home — on fail, **bounces the phone LAN AP in-process** (`-BouncePhoneLanAp -InProcessThrowExit`, same `/24` as active `phoneLanHost`; ~20s tcp/23 wait; session drop after WifiRestart that recovers is success, not a second reboot; success exits quietly via outer `try/catch` on `GATEWAY_EXIT:<code>` / `LoopSegmentsGatewayExitCode`, not a red `GATEWAY_EXIT:0` stack) **unless** `status.json` shows an export running or a non-empty pending queue; then USB-Homes Loop Segments **in-process** (`HOME_USB_EXIT:<code>`) **only if it is still foreground** (skipped when already backgrounded or lock screen; DVT `--userspace`; HID Home is skipped on iOS 26). Finish avoids nesting a new `pwsh` so a dead `L:` cannot hang on `InitializeDefaultDrives`. Console transcript: `logs\companion-console-*.log`. Use `-SkipWifiWwwProbeOnQuit` / `-SkipGoHome` / `-NoTranscript` to skip those steps.
- **Fatal errors:** any failure that stops the companion ends with a **single** “Press Enter to close…” (child scripts skip their own Enter so you are not prompted twice). USB Home-on-quit failure also pauses for Enter (it does not fail the companion session, so the fatal prompt would not run)

## Playwright

**Not required by the extension.** Playwright is only used by `_run_chromium.ps1` to download a Chromium build and resolve `chrome.exe`. Runtime is plain Chromium + the MV3 extension (no Playwright API calls). You can replace that with any Chromium/Chrome-for-Testing binary if you prefer.

## Config

`lan_config.json` (written by the launcher):

```json
{
  "phoneLanHost": "10.0.100.10",
  "lanPort": 8765,
  "webdavUser": "admin",
  "webdavPassword": "<the WebDAV password shown on the app's Export screen>",
  "phoneLanHostSource": "config",
  "preferUsbPhoneLanHost": false,
  "webCompanionMediaListFile": "P:\\p_cld_media\\web_compann_plst\\media_files.txt"
}
```

The phone's LAN pages (`/`, `/browse`) ask for the WebDAV login. The extension answers that prompt itself with `webdavUser` / `webdavPassword` above, only for the configured phone and port 8765, so the LAN tab opens without a dialog. If the password is wrong, the normal browser prompt appears instead. At startup the LAN tab is opened from Chromium's command line, and its first request can reach the phone before the extension's background worker is listening; Chromium then shows its own sign-in popup (and what is typed there only lasts that run). Chromium shows the 401 page under that popup, so the tab looks loaded. Since Chromium has no cached login at browser start, a phone tab whose login the extension has not answered is one behind the popup: at 0, 3 and 8 s after the worker starts (once per browser start) it re-opens such a tab, which drops the popup and lets the extension answer. `rest.log` gets a `lan_login_check` line per pass (`557902428:complete:not-answered`, then `signed-in`) and `lan_login_retry` for each re-open. The launcher copies the password from `windows/loop-segments-windows.json`; there is no built-in default.

`webCompanionMediaListFile` is optional — default is `{SyncDrive}\p_cld_media\web_compann_plst\media_files.txt` from registry. Env `WEB_COMPANION_MEDIA_LIST` overrides both.

Phone must be on Wi‑Fi with Loop Segments open (foreground, exporting, or Keep Alive) so the export trigger is picked up.

## Logs

| Where | What |
|-------|------|
| `windows\pcloud_web_companion\logs\companion-console-*.log` | Full companion **console transcript** (`Start-Transcript` from `_run_chromium.ps1`; includes `[lan]` / `[gateway]` / `[wifi-www]` / finish). Gitignored. |
| `windows\pcloud_web_companion\rest.log` | Live extension/sink JSON lines (`sw_boot`, `capture`, `request`, …). Truncated each companion start (previous file archived). |
| `windows\pcloud_web_companion\logs\rest-*.log` | Archived `rest.log` from prior runs |
| Extension toolbar icon | REST logs popup (current session) |
| Desktop notification | Archive/queue POST: queued OK, no fileids, empty resolve, or REST failed. First phone ack `rejected` (file missing from saved folder) → **Loop Segments: skipped `<name>`**. Later FIFO drain skips land on Paused **Unavailable** only. |

**Retention** (`_companion_logging.ps1`, applied at each start):

| Kind | Keep |
|------|------|
| `companion-console-*.log` | **Last 5** runs |
| `rest-*.log` archives | **Last 5** runs |
| Whole `logs\` (those patterns) | Soft cap **100 MB** (oldest deleted first) |

`-NoTranscript` skips the console transcript only; rest.log rotate/retention still runs.

## Extension files

| File | Role |
|------|------|
| `manifest.json` | MV3 permissions; **Ctrl+E** → open folder in Explorer; **Ctrl+Shift+H** → write hybrid `media_files.txt` |
| `background.js` | Download intercept, REST POST, reuse LAN `/` tab after export (no startup open), Explorer jump, hybrid media list write |
| `pcloud_fileid_hook_main.js` | MAIN-world fetch/XHR `fileid`s; Shift+right-click bypass of pCloud’s overlay (`pointerdown` / `contextmenu`) |
| `pcloud_folder_tracker.js` | Isolated-world `folder=` / tree node for Explorer jump; `collectSelectedVideoFileIds()` + **Ctrl+Shift+H** page hook |
| `offscreen.html` / `offscreen.js` | Clipboard write |
| `logs.html` / `logs.js` | In-browser REST log UI + **Open pCloud Drive folder** + **Write hybrid media_files.txt** |
| `lan_config.json` | Phone LAN target (synced on launch) |
| `Sync-Reload-PCloudWebCompanionDev.ps1` | Dev: sync extension to LOCALAPPDATA + restart sink (poll health up to ~25s; no Chromium exit); then `chrome://extensions` Reload |
| `_run_chromium.ps1` | Venv, Playwright Chromium, gateway reboot check, USB launch, rclone mount, WAN + LAN throughput probes, profile sync, extension copy, toolbar pin + **Ctrl+E** / **Ctrl+Shift+H** prefs, browser launch, console transcript |
| `_companion_logging.ps1` | `Start-Transcript` + `rest.log` archive + retention under `logs\` |
| `_chromium_profile_sync.ps1` | Zip/unzip Chromium profile (cache off pCloud); used by launcher + exit watchdog |
| `_profile_exit_watchdog.ps1` | If console X kills the launcher, still close Chromium, unmap Skybox AirScreen shares, quit Skybox if we started it, + sync/clear profile |
| `requirements.txt` | `playwright` (launcher Chromium fetch only) |
| `_rest_log_sink.ps1` | Local REST sink on `127.0.0.1:18765` (loopback / private clients only): **POST /log** (extension log lines → `rest.log`); **POST /phone-lan** (phone LAN API relay, empty WinHTTP proxy = DIRECT); **POST /quest-open-lan-tab** (Open on Quest → `quest\Watch-LoopSegmentsQuestLanTab.ps1`); **POST /open-explorer**; **POST /write-hybrid-media-list** (maps `items`/`paths` → Drive paths, overwrite UTF-8 list, open hub in Explorer); **/focus-console** (toast click brings the companion console to the front; the only use of its `-CompanionPid`); **GET /health** |
| `chromium-profile.zip` | Canonical browser profile on P: (gitignored; extracted under `%LOCALAPPDATA%`). Each upload is read back from P: (hash + zip check) and keeps the replaced good copy as `chromium-profile.prev.zip` and a copy on this PC (`%LOCALAPPDATA%pcloud_web_companionprofile-backup`). The start checks a zip before clearing the local profile for it and falls back main → prev → local backup: pCloud Drive has served this file with another file's bytes in it, which used to start Chromium empty and then upload that empty profile over the good one. A run that started with no usable zip never replaces a copy that reads fine, nor the backups |

## Requirements

- Windows + **PowerShell 7** (`pwsh`; install from https://aka.ms/powershell). Prefer a **pwsh** prompt. A Windows PowerShell 5.1 (blue) start of `Run-PCloudWebCompanion.ps1` / `_run_chromium.ps1` **re-runs under `pwsh`** when the file parses (UTF-8 BOM); still prefer opening 7 first.
- Windows + Python (`py`) — for the launcher’s Chromium install via Playwright
- Loop Segments app LAN server on port 8765 (USB launch opens the app first when possible)
- `windows\loop-segments-windows.json` with `phoneLanHost`
- USB: iPhone plugged in, trusted, **unlocked**; prefer `..\setup\Setup-LoopSegmentsWindows.ps1` (or `py -3.12 -m pip install -U pymobiledevice3`)

## Clash / system proxy

The extension must reach `http://<phoneLanHost>:8765/`. **Clash TUN** often black-holes Chromium service-worker `fetch` to private IPs (LAN tab may still work), so export POSTs hang and a pCloud CDN tab/download eventually wins. That is a unicast/TUN issue, not mDNS — the multicast UAC script does not fix it.

**Fix in 1.7.4+:** phone LAN API calls go through `http://127.0.0.1:18765/phone-lan` (companion PowerShell sink) which talks to the phone with an **empty WinHTTP proxy** (DIRECT). Loopback is normally excluded from TUN. In-progress pCloud **downloads** are re-cancelled while the pipeline runs. **CDN view tabs are not closed** (1.7.8+).

`_run_chromium.ps1` also sets `--proxy-bypass-list` for system-proxy Clash. Keep the companion running so the local sink is watched and restarted when it goes down (the sink itself does not need the console: see below).

### REST sink lifetime

- **Start:** `_run_chromium.ps1` starts it hidden and detached from the companion console (`Start-HiddenPowerShell -BreakAwayFromConsoleJob`), so closing the console window does not stop it.
- **Health:** while the companion runs, `Ensure-RestLogSink` checks `GET /health` and starts a new one when it is down (warning `[rest-log] Sink on :18765 is down - restarting`). `Sync-Reload-PCloudWebCompanionDev.ps1` restarts it during development.
- **Stop:** only the companion's normal finish stops it (`Stop-CompanionRestLogSink`, every `_rest_log_sink.ps1` process). The sink does **not** exit when the companion process is gone (`-CompanionPid` is used for console focus only), so a companion that dies without finishing (killed, crashed, PC session ended mid-run) leaves it running on `:18765`. Harmless: the next companion start reuses it when `/health` answers, or replaces it. To clear it by hand, end the `pwsh` process running `_rest_log_sink.ps1`.

**If even the LAN monitor tab fails under TUN,** Clash Verge isn't keeping private ranges out of the tunnel. Its own TUN settings override the profile's `route-exclude-address` (the running config had `[]`). Run [`env_setup\Clash\Set-ClashLanExceptions.ps1`](../../env_setup/Clash/README.md#lan-and-router-dns-exceptions): it excludes `10.0.100.0/24` / `192.168.2.0/24` / multicast from the TUN, and resolves `routerlogin.net` names through the router instead of fake-IP.