# pCloud web companion → Loop Segments

Chromium MV3 extension (`pcloud_web_companion`) that intercepts pCloud downloads, cancels them, copies the URL + filename, and queues an export on the Loop Segments iOS LAN API.

## What it does

On a **single-file** pCloud download click:

1. Cancels the Chromium download (or closes a CDN file tab) immediately, then removes it from the shelf
2. Resolves the open my.pcloud `folder=` id to a folder **path/name** via `listfolder` / parent walk — `folderPath` is the full pCloud path (root segment kept). API host is derived from the download CDN domain when possible (`pnyc1.pcloud.com` → `apinyc1.pcloud.com`), with `api.pcloud.com` / `eapi` as fallbacks
3. If `folderPath` is missing/garbled (e.g. search UI text like `"darina" in "/All Files/"`), runs **right-click → Open Location** on the file, then re-resolves; falls back to pCloud `search` API if needed
4. Copies clipboard lines: download URL, filename, folder path, folder name (when known)
5. `POST /export_from_folder.json` with `{ folderPath, displayName, seekMs, id }` only — CDN download URLs are **not** posted to the phone
6. Opens `http://<phoneLanHost>:8765/` (LAN monitor root) in a new tab (or focuses/navigates an existing phone LAN tab)

On **multi-select Download** (pCloud builds a **zip archive**):

1. Cancels the archive download (not used by the phone)
2. Reads recently captured selection `fileid`s from `getthumbslinks` / `getziplink` (`webRequest` + MAIN-world fetch/XHR hook)
3. Resolves each video via pCloud `getpath` / `stat` + **parent folder path** → `{ folderPath, displayName }` (name-only fallback forces a slow bookmark WebDAV walk and often misses deep files)
4. `POST /export_queue.json` with `{ mode: "prepend", startFirst: true, items: […] }` — phone FIFO; first item soft-pauses any running export → that clip goes to **Paused** (parked) and is **not** auto-resumed when later queue items finish
5. Remaining items show under the app **Paused** tab → **Queued** until idle (finish/Stop drains; user Pause holds). Resume interrupted titles manually from **Paused** / LAN

**Tip — select only videos in my.pcloud.com:** the web UI can filter the current folder by type. Click the **`v`** (view / type filter) control, then pick one of the **five** type filters (including **Video**). With **Video** active, multi-select + Download queues video files for Loop Segments without grabbing photos/docs from the same folder.

## Run

Integrated under **`windows\pcloud_web_companion`** (preferred):

```powershell
cd <repo>\windows
.\setup\Setup-LoopSegmentsWindows.ps1    # once per PC
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
| `-SkipProfileSync` | Do not sync Chromium profile to/from repo |
| `-DetachChromium` | Do not wait for browser exit (upload + local clear on next run) |
| `-KeepLocalProfile` | Do not wipe local AppData profile after upload |
| `-SkipGoHome` | Do not press iPhone Home on companion finish |
| `-StartUrl "..."` | Override start page (default `https://my.pcloud.com`) |

Each launch:

- Ensures a **machine-local** venv at `%LOCALAPPDATA%\pcloud_web_companion\venv` (Python 3.12 preferred; removes any legacy repo `.venv` on P:)
- Syncs LAN host/auth from `windows\loop-segments-windows.json` → `lan_config.json`
- Copies the extension to `%LOCALAPPDATA%\pcloud_web_companion\extension` (Chromium will not load unpacked extensions from the pCloud `P:` drive)
- Starts a local REST log sink
- **USB-launches Loop Segments** via `..\usb\Launch-LoopSegmentsViaUsb.ps1` on every start (prints LAN UP/DOWN first). **Locked (exit 3) still aborts Chromium.** If USB is missing / launch fails but phone LAN is already reachable, prints a warning and continues to Chromium. Use `-SkipUsbLaunch` for Chromium only. Always prints AltServer status and the fix if the app becomes unavailable after ~7 days (**AltServer → USB → AltStore Refresh All → Settings → General → VPN & Device Management → Developer App → Trust → open once**). USB detect failure tries to start AltServer then retries.
- **Attempts rclone mount** via `..\rclone\Mount-LoopSegmentsRclone.ps1 -Quick` in a **separate** console when phone LAN is up (drive letter from `loop-segments-windows.json`, default `L:`). Waits for LAN after USB launch; reuses an existing mount; failures only warn. Mount polls phone LAN and auto-kills rclone after prolonged outage. Log: `windows\rclone\loopsegments-rclone-mount.log`. Use `-SkipRcloneMount` to leave mounting to `Mount-PhoneL.cmd`. Mount window is independent of Chromium — **Ctrl+C** there to unmount.
- **Profile sync:** download full profile from `windows\pcloud_web_companion\chromium-profile` → local AppData; after Chromium exits, upload full folder to P:, then **clear local** (canonical copy stays on P:). Empty local never uploads over P:. Use `-KeepLocalProfile` to skip the wipe. Folder is gitignored.
- Closes any prior profile Chromium, clears tabs/session + download history (**cookies kept**)
- Launches Chromium (from `%LOCALAPPDATA%\ms-playwright`, or `LOOP_SEGMENTS_PLAYWRIGHT_BROWSERS`) with the extension loaded; waits for exit unless `-DetachChromium`
- **Graceful quit:** close the browser, **Ctrl+C**, or console **X** — kills this profile’s Chromium, uploads full profile to P:, clears local AppData (`_profile_exit_watchdog.ps1` covers console X), then presses **iPhone Home** over USB to background Loop Segments (use `-SkipGoHome` to leave it foreground)

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
| `run_chromium.ps1` | Venv, Playwright Chromium, USB launch, profile sync, extension copy, browser launch |
| `_profile_exit_watchdog.ps1` | If console X kills the launcher, still close Chromium + sync/clear profile |
| `requirements.txt` | `playwright` (launcher Chromium fetch only) |
| `_rest_log_sink.ps1` | Appends extension log POSTs to `rest.log` |
| `chromium-profile/` | Synced browser profile (gitignored; local working copy under `%LOCALAPPDATA%`) |

## Requirements

- Windows + **Windows PowerShell 5.1** (built-in; scripts use `powershell.exe`, not `pwsh`)
- Windows + Python (`py`) — for the launcher’s Chromium install via Playwright
- Loop Segments app LAN server on port 8765 (USB launch opens the app first when possible)
- `windows\loop-segments-windows.json` with `phoneLanHost`
- USB: iPhone plugged in, trusted, **unlocked**; prefer `..\setup\Setup-LoopSegmentsWindows.ps1` (or `py -3.12 -m pip install -U pymobiledevice3`)

## Clash / system proxy

The extension must reach `http://<phoneLanHost>:8765/`. **Clash TUN** often black-holes Chromium service-worker `fetch` to private IPs (LAN tab may still work), so export POSTs hang and a pCloud CDN tab/download eventually wins.

**Fix in 1.7.4+:** phone LAN API calls go through `http://127.0.0.1:18765/phone-lan` (companion PowerShell sink) which talks to the phone with an **empty WinHTTP proxy** (DIRECT). Loopback is normally excluded from TUN. CDN tabs are closed earlier (`webNavigation`) and in-progress pCloud downloads are re-cancelled while the pipeline runs.

`run_chromium.ps1` also sets `--proxy-bypass-list` for system-proxy Clash. Keep the companion console open so the local sink stays up.

**Still need Clash DIRECT for private ranges** if even the LAN monitor tab fails under TUN.