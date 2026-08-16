# pCloud web companion → Loop Segments

Chromium MV3 extension (`pcloud_web_companion`) that intercepts pCloud downloads, cancels them, copies the URL + filename, and queues an export on the Loop Segments iOS LAN API.

## What it does

On a **single-file** pCloud download click:

1. Cancels the Chromium download (or closes a CDN file tab) immediately, then removes it from the shelf
2. Resolves the open my.pcloud `folder=` id to a folder **path/name** via `listfolder` / parent walk — `folderPath` is the full pCloud path (root segment kept). API host is derived from the download CDN domain when possible (`pnyc1.pcloud.com` → `apinyc1.pcloud.com`), with `api.pcloud.com` / `eapi` as fallbacks
3. If `folderPath` is missing/garbled (e.g. search UI text like `"darina" in "/All Files/"`), runs **right-click → Open Location** on the file, then re-resolves; falls back to pCloud `search` API if needed
4. Copies clipboard lines: download URL, filename, folder path, folder name (when known)
5. If the phone LAN page is up: `POST /export_from_folder.json` with `{ folderPath, displayName, seekMs, id }` only — CDN download URLs are **not** posted to the phone. If `:8765` is down (companion still doing USB/LAN recover): **queue locally**, desktop notification **waiting for LAN**, retry ~every minute; after **~5 minutes** **deny** with a notification. When LAN returns, pending items are POSTed automatically.
6. Opens `http://<phoneLanHost>:8765/` (LAN monitor root) in a **background** tab only after a successful POST (not while waiting for LAN)

On **multi-select Download** (pCloud builds a **zip archive**):

1. Cancels the archive download (not used by the phone)
2. Reads recently captured selection `fileid`s from `getthumbslinks` / `getziplink` (`webRequest` + MAIN-world fetch/XHR hook)
3. Resolves each video via pCloud `getpath` / `stat` + **parent folder path** → `{ folderPath, displayName }` (name-only fallback forces a slow bookmark WebDAV walk and often misses deep files)
4. `POST /export_queue.json` with `{ mode: "prepend", startFirst: true, items: […] }` — phone FIFO; first item soft-pauses any running export → that clip goes to **Paused** (parked) and is **not** auto-resumed when later queue items finish
5. Remaining items show under the app **Paused** tab → **Queued** until idle (finish/Stop drains; user Pause holds). Resume interrupted titles manually from **Paused** / LAN

**Tip — select only videos in my.pcloud.com:** the web UI can filter the current folder by type. Click the **`v`** (view / type filter) control, then pick one of the **five** type filters (including **Video**). With **Video** active, multi-select + Download queues video files for Loop Segments without grabbing photos/docs from the same folder.

**Not supported — folder right-click → Download:** that also builds a zip, but pCloud does not expose per-file `fileid`s the way multi-select does. The companion still **cancels** the zip, then shows a desktop notification (**no selection ids**) and does **not** expand the folder into FIFO items. To queue a whole folder: open it → filter **Video** → select the files (or Select all) → **Download**.

## Run

Integrated under **`windows\pcloud_web_companion`** (preferred):

```powershell
cd <repo>\windows
.\setup\Setup-LoopSegmentsWindows.ps1    # once per PC (pwsh)
.\pcloud_web_companion\Run-PCloudWebCompanion.ps1
# same as:
.\pcloud_web_companion\run_chromium.ps1
```
| Flag | Effect |
|------|--------|
| `-RecreateVenv` | Recreate machine-local venv under `%LOCALAPPDATA%\pcloud_web_companion\venv` |
| `-ForceDeps` | Reinstall pip deps + Chromium |
| `-NoLaunch` | Setup + USB launch only (no Chromium) |
| `-SkipUsbLaunch` | Do not run `usb\Launch-LoopSegmentsViaUsb.ps1` |
| `-UsbLaunchMount` | Remount Developer Disk Image (default skips mount) |
| `-SkipRcloneMount` | Do not open `rclone\Mount-LoopSegmentsRclone.ps1` (default attempts mount when LAN is up) |
| `-SkipGatewayReboot` | Do not check/reboot LAN gateway (wrong-subnet, low-throughput, or off-subnet recovery when LAN page unreachable) |
| `-SkipLanThroughput` | Do not time a media copy off `L:` after mount (default: up to 64 MB → Mbps) |
| `-SkipLowThroughputGatewayReboot` | Do not reboot other routers / re-check when LAN throughput is below `minLanThroughputMbps` |
| `-SkipProfileSync` | Do not sync Chromium profile to/from repo |
| `-DetachChromium` | Do not wait for browser exit (upload + local clear on next run) |
| `-KeepLocalProfile` | Do not wipe local AppData profile after upload |
| `-SkipGoHome` | Do not press iPhone Home on companion finish |
| `-NoDarkMode` | Do not force Chromium UI dark mode (default: `--force-dark-mode` only) |
| `-SkipSkybox` | Do not check/start SKYBOX VR desktop (default: start if idle, hide to tray) |
| `-SkipVirtualDesktop` | Do not check/start Virtual Desktop Streamer (default: start if idle, hide to tray) |
| `-SkipClashMdnsRoute` | Do not try to drop Clash/mihomo TUN multicast when Clash is running |
| `-StartUrl "..."` | Override start page (default `https://my.pcloud.com`) |

Each launch:

- Ensures a **machine-local** venv at `%LOCALAPPDATA%\pcloud_web_companion\venv` (Python 3.12 preferred; removes any legacy repo `.venv` on P:)
- Syncs LAN host/auth from `windows\loop-segments-windows.json` → `lan_config.json`
- Copies the extension to `%LOCALAPPDATA%\pcloud_web_companion\extension` (Chromium will not load unpacked extensions from the pCloud `P:` drive)
- Starts a local REST log sink
- **Gateway Wi‑Fi reboot (when needed):** compares the PC’s IPv4 default gateway to `phoneLanHost` (app LAN page). If they are **not** on the same subnet, informs you, **reboots Wi‑Fi on the current gateway**, **polls until this PC gets a new LAN IP/gateway**, then **re-checks** — up to **3** rounds, then fails and **waits for Enter** (no Enter between rounds; `-SkipGatewayReboot` to skip). This still runs **before** Chromium so pCloud is not dropped mid-browse.
- **Starts Chromium early** (after gateway check + profile sync) so you can use my.pcloud.com while USB/LAN recover/rclone continue in the companion console. If the app LAN page (`:8765`) is down, the extension **queues** intercepted downloads locally (desktop notification) and retries about once a minute; after **~5 minutes** it **denies** them with another notification. When LAN comes up, queued exports are POSTed automatically. **Click a toast** to bring the companion PowerShell window to the front.
- **SKYBOX VR desktop:** after Chromium is up, if the Windows SKYBOX player is installed, starts it when idle and **hides the main window to the tray** (Electron notify icon — not a taskbar minimize), including when it was already running. Retries ~30s as the window appears. Missing install only warns. `-SkipSkybox` to skip. If this session started Skybox, companion **quits it** on Chromium close / Ctrl+C / console X / fatal cleanup (a Skybox that was already running is left alone after hide).
- **Virtual Desktop:** after Skybox, **starts Virtual Desktop Streamer if it is idle** (starts **Virtual Desktop Service** if that service is stopped; does not bounce a running service or quit a running Streamer) and **hides the Streamer window to the tray**. Retries ~30s as the window appears. Missing install only warns. `-SkipVirtualDesktop` to skip. Companion finish does **not** quit Streamer.
- **Clash / mihomo:** optional UAC for `env_setup\Clash\Remove-MihomoMulticastRoute.ps1` so TUN does not steal `.local` mDNS. Phone-IP (`pcapd`) and `:8765` (numeric `phoneLanHost` + local sink) do not need it. `-SkipClashMdnsRoute` to skip. Details: [`../../env_setup/Clash/README.md`](../../env_setup/Clash/README.md).
- **USB-launches Loop Segments** via `..\usb\Launch-LoopSegmentsViaUsb.ps1` **after Chromium starts**. **Skips relaunch** when pymobiledevice3 already sees the app in the **foreground** over USB. **Locked (exit 3)** no longer aborts Chromium (warns instead). If USB is missing / launch fails, Chromium stays open and the plugin queues until `:8765` is up. Use `-SkipUsbLaunch` for Chromium only. Always prints AltServer status and **starts AltServer when installed but not running** (`..\env_setup\altserver_refresh_scripts\Get-AltServer.ps1` via `..\lib\Get-LoopSegmentsAltServer.ps1`). If the app becomes unavailable after ~7 days: **AltServer → USB → AltStore Refresh All → Settings → General → VPN & Device Management → Developer App → Trust → open once**. USB detect failure also retries after ensuring AltServer.
- **Attempts rclone mount** via `..\rclone\Mount-LoopSegmentsRclone.ps1 -Quick` in a **separate** console after Chromium is up (drive letter from `loop-segments-windows.json`, default `L:`). **`..\lan\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1`** runs **in-process** (no nested `pwsh` from `P:`) and uses USB/`pcapd` to check the phone vs PC/AltServer subnet (`env_setup\altserver_refresh_scripts`), then waits for the LAN page; if USB is missing and `:8765` stays down, it **reboots off-subnet routers** (ROUTER_IPs outside `phoneLanHost`’s subnet) and waits again. Failures only warn. Mount polls phone LAN and auto-kills rclone after prolonged outage. Log: `windows\rclone\loopsegments-rclone-mount.log`. Use `-SkipRcloneMount` to leave mounting to `Mount-PhoneL.cmd`. Mount window is independent of Chromium — **Ctrl+C** there to unmount. Use `-SkipGatewayReboot` to skip off-subnet recovery too.
- **LAN throughput probe:** after mount attempt, runs `..\lan\Measure-LoopSegmentsLanThroughput.ps1` (random media under `pcld_ios_media\archive\` ≥ min size, default **64 MB** transfer cap via phone HTTP), prints Mbps, recommends a **max media bitrate** for minute segments (80% of LAN), and writes sidecars for `run_batch_vr_hybrid.ps1`. If Mbps is below `minLanThroughputMbps` (default **40**), reboots Wi‑Fi on **other** known routers (not this PC’s app-LAN gateway), waits to settle, and re-measures — up to **2** retries. Chromium stays open. Low Mbps on the right subnet is **suspected Wi‑Fi channel congestion from neighboring routers**. The app LAN gateway is **tethered to a primary router**; those two APs must use the **same Wi‑Fi channel** (see [`../README.md`](../README.md#app-lan-vs-primary-router)). **Do not run the probe during an active Virtual Desktop headset session** — VD streaming uses ~**50 Mbps** of LAN and will understate phone capacity. Use `-SkipLanThroughput` or `-SkipLowThroughputGatewayReboot` to skip.
- **Profile sync:** download full profile from `windows\pcloud_web_companion\chromium-profile` → local AppData; after Chromium exits, upload full folder to P:, then **clear local** (canonical copy stays on P:). Empty local never uploads over P:. Use `-KeepLocalProfile` to skip the wipe. Folder is gitignored.
- Closes any prior profile Chromium, clears tabs/session + download history (**cookies kept**)
- Launches Chromium (from `%LOCALAPPDATA%\ms-playwright`, or `LOOP_SEGMENTS_PLAYWRIGHT_BROWSERS`) with the extension loaded and **Chromium UI dark mode** (`--force-dark-mode`; `-NoDarkMode` to disable). Page auto-darkening (`WebContentsForceDark`) is not used — it can hide media seekbars; waits for exit unless `-DetachChromium`
- **Graceful quit:** close the browser, **Ctrl+C**, or console **X** — kills this profile’s Chromium, quits SKYBOX if this session started it, uploads full profile to P:, clears local AppData (`_profile_exit_watchdog.ps1` covers console X), then backgrounds Loop Segments over USB (DVT `--userspace`; HID Home is skipped on iOS 26). Use `-SkipGoHome` to leave it foreground
- **Fatal errors:** any failure that stops the companion ends with a **single** “Press Enter to close…” (child scripts skip their own Enter so you are not prompted twice). USB Home-on-quit failure also pauses for Enter (it does not fail the companion session, so the fatal prompt would not run)

## Playwright

**Not required by the extension.** Playwright is only used by `run_chromium.ps1` to download a Chromium build and resolve `chrome.exe`. Runtime is plain Chromium + the MV3 extension (no Playwright API calls). You can replace that with any Chromium/Chrome-for-Testing binary if you prefer.

## Config

`lan_config.json` (written by the launcher):

```json
{
  "phoneLanHost": "10.0.100.10",
  "lanPort": 8765,
  "webdavUser": "admin",
  "webdavPassword": "iosadmin"
}
```

Phone must be on Wi‑Fi with Loop Segments open (foreground, exporting, or Keep Alive) so the export trigger is picked up.

## Logs

| Where | What |
|-------|------|
| `windows\pcloud_web_companion\rest.log` (P:) | JSON lines: `sw_boot`, `capture`, `request`, `response`, `browse`, … (cleared each `run_chromium.ps1` start; gitignored) |
| Extension toolbar icon | Same events in a popup |
| Desktop notification | Archive/queue POST: queued OK, no fileids, empty resolve, or REST failed — **not** phone mid-FIFO resolve skips (those are silent; see phone `export_trigger.ack.json`) |

## Extension files

| File | Role |
|------|------|
| `manifest.json` | MV3 permissions |
| `background.js` | Download intercept, REST POST, LAN root `/` tab |
| `offscreen.html` / `offscreen.js` | Clipboard write |
| `logs.html` / `logs.js` | In-browser REST log UI |
| `lan_config.json` | Phone LAN target (synced on launch) |
| `Run-PCloudWebCompanion.ps1` | Thin wrapper → `run_chromium.ps1` (preferred entry) |
| `run_chromium.ps1` | Venv, Playwright Chromium, gateway reboot check, USB launch, rclone mount, LAN throughput probe, profile sync, extension copy, browser launch |
| `_profile_exit_watchdog.ps1` | If console X kills the launcher, still close Chromium, quit Skybox if we started it, + sync/clear profile |
| `requirements.txt` | `playwright` (launcher Chromium fetch only) |
| `_rest_log_sink.ps1` | Appends extension log POSTs to `rest.log` |
| `chromium-profile/` | Synced browser profile (gitignored; local working copy under `%LOCALAPPDATA%`) |

## Requirements

- Windows + **PowerShell 7** (`pwsh`; install from https://aka.ms/powershell). Run from a **pwsh** prompt — do not start `.ps1` files from a Windows PowerShell 5.1 (blue) shell. A 5.1 start **re-runs the same script under `pwsh`**; prefer opening 7 first.
- Windows + Python (`py`) — for the launcher’s Chromium install via Playwright
- Loop Segments app LAN server on port 8765 (USB launch opens the app first when possible)
- `windows\loop-segments-windows.json` with `phoneLanHost`
- USB: iPhone plugged in, trusted, **unlocked**; prefer `..\setup\Setup-LoopSegmentsWindows.ps1` (or `py -3.12 -m pip install -U pymobiledevice3`)

## Clash / system proxy

The extension must reach `http://<phoneLanHost>:8765/`. **Clash TUN** often black-holes Chromium service-worker `fetch` to private IPs (LAN tab may still work), so export POSTs hang and a pCloud CDN tab/download eventually wins. That is a unicast/TUN issue, not mDNS — the multicast UAC script does not fix it.

**Fix in 1.7.4+:** phone LAN API calls go through `http://127.0.0.1:18765/phone-lan` (companion PowerShell sink) which talks to the phone with an **empty WinHTTP proxy** (DIRECT). Loopback is normally excluded from TUN. CDN tabs are closed earlier (`webNavigation`) and in-progress pCloud downloads are re-cancelled while the pipeline runs.

`run_chromium.ps1` also sets `--proxy-bypass-list` for system-proxy Clash. Keep the companion console open so the local sink stays up.

**Still need Clash DIRECT for private ranges** if even the LAN monitor tab fails under TUN.