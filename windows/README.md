# Loop Segments — Windows (portable)

Scripts work on **any Windows PC** after you copy or clone this repo (`git clone --recurse-submodules` so **`env_setup`** and **`Skybox_vr_pc`** are present). Machine-specific paths live in **`loop-segments-windows.json`** (gitignored) in this folder. Shared helpers live in **`lib\`**; entry-point scripts are grouped by role under subfolders.

**IPA → iCloud:** from the **repo root** (parent of this folder), run **`..\deploy.ps1`** (build/fetch, then calls **`copy-to-icloud.ps1`**) or **`..\copy-to-icloud.ps1`** alone (stamped `LoopSegments-b{build}-{time}.ipa`, like web_auto_parking). See [../ios/BUILD-WITHOUT-MAC.md](../ios/BUILD-WITHOUT-MAC.md).

**PowerShell:** use **PowerShell 7** (`pwsh`) — install: https://aka.ms/powershell. Open a **pwsh** prompt (not the blue Windows PowerShell 5.1 console) before running `.ps1` files. If you do start one under 5.1, a helper **re-runs that same script under `pwsh`** and exits 5.1 with the child’s code. Prefer a 7 prompt; the bounce is a fallback (path spaces like `iOS apps` used to break it). `.cmd` launchers already call `pwsh`.

Companion: `pcloud_web_companion\Run-PCloudWebCompanion.ps1`. Mount: `rclone\Mount-LoopSegmentsRclone.ps1` (or existing `Mount-PhoneL.cmd`).

## Layout

| Folder | Role |
|--------|------|
| *(this folder)* | `README.md`, `loop-segments-windows.json` (+ example), legacy `loop-segments-lan-host.txt` |
| `lib/` | Shared helpers: `LoopSegments-Windows.ps1`, Python picker, AltServer wrappers (`env_setup` submodule), Skybox wrappers (`Skybox_vr_pc` submodule) |
| `setup/` | New-PC bootstrap + edit per-PC json / LAN IP |
| `usb/` | Force-open / Home over USB (`pymobiledevice3`) |
| `sideload/` | AltServer logon task; Sideloadly fallback |
| `lan/` | Multi-phone unified listing / PC index on `:8766`; gateway Wi‑Fi reboot (wrong-subnet / other-router / off-subnet); LAN throughput |
| `rclone/` | Optional WinFsp drive-letter mount |
| `pcloud_web_companion/` | Chromium MV3 companion + `Run-PCloudWebCompanion.ps1` |
| `archive/` | Legacy `net use` / sync scripts |

## Typical `.ps1` run sequence (`windows\`)

```powershell
cd <repo>\windows

# 1) Once per PC (Python 3.12, pymobiledevice3, companion venv/Chromium, portable json)
.\setup\Setup-LoopSegmentsWindows.ps1 -PhoneHost 10.0.100.10

# 2) Once (optional, AltStore only): AltServer at logon — ~7-day sideload refresh
.\sideload\Register-AltServerAtLogon.ps1
# SideStore: do not register. If it (or UsbWatch) was already registered, unregister:
#   .\sideload\Register-AltServerAtLogon.ps1 -Unregister
#   pwsh -File ..\env_setup\altserver_refresh\usb\Register-IphoneUsbAltServer.ps1 -Unregister
# Why: SideStore refreshes on Wi‑Fi with LocalDevVPN; no AltServer / USB watch.

# 3) Day-to-day: pCloud companion (gateway check → LAN status; USB-foregrounds app unless -SkipUsbLaunch)
.\pcloud_web_companion\Run-PCloudWebCompanion.ps1
#    Quit: close Chromium, Ctrl+C, or console X - kills Chromium, unmaps Skybox
#    AirScreen + phone rclone folders, quits SKYBOX if this session started it, syncs profile,
#    then USB Home only if the app is still foreground (Keep Alive default on — see ../ios/README.md; -SkipGoHome to never press)

# Optional helpers
.\setup\Set-LoopSegmentsWindows.ps1 -Show          # show/edit per-PC json
.\setup\Set-LoopSegmentsLANHost.ps1 <phone-ip>     # IP changed on Wi-Fi
.\usb\Launch-LoopSegmentsViaUsb.ps1 -SkipMount    # open app over USB only
.\rclone\Mount-LoopSegmentsRclone.ps1 -TestOnly   # probe phone LAN / WebDAV
.\rclone\Mount-LoopSegmentsRclone.ps1             # mount L: (optional; WinFsp)
```

If Loop Segments won’t open after ~7 days: **SideStore** (LocalDevVPN → Refresh) or start **AltServer** → USB + unlock → AltStore **Refresh All** (works even when phone and PC are on different gateways) → **Settings → General → VPN & Device Management → DEVELOPER APP → iPhone Developer: \<email\> → Trust** (entry may appear only after a failed open) → open app once → retry.

**AltStore / SideStore “data isn’t in the correct format”:** often the IPA is still syncing in iCloud (partial file). Wait for iCloud to finish, then **retry My Apps → + several times**. **SideStore stable** hit the same error here; **SideStore nightly** worked. If it persists after a fully local file on AltStore, see [BUILD-WITHOUT-MAC.md](../ios/BUILD-WITHOUT-MAC.md) (iTunes authorize / anisette). SideStore: change anisette / re-pair with iloader.

**AltStore “could not determine this device's UDID” (error 1006):** AltStore was not installed (or was corrupted) by AltServer — UDID is embedded only when AltServer installs AltStore. Update AltServer → USB + unlock → tray **Install AltStore** (not Sideloadly / random IPA) → Trust developer if prompted → open AltStore → **Refresh All**. If Loop Segments then says **“not available”** (or is missing from My Apps): no new build required — **My Apps → +** → same `LoopSegments.ipa` (or delete the home-screen icon and install again). Details: [../ios/BUILD-WITHOUT-MAC.md](../ios/BUILD-WITHOUT-MAC.md).

## First time on a PC

```powershell
cd <repo>\windows   # e.g. where this README lives

# One shot: Python 3.12 + pymobiledevice3 + companion venv/Chromium + portable json
.\setup\Setup-LoopSegmentsWindows.ps1 -PhoneHost 10.0.100.10

.\setup\Set-LoopSegmentsWindows.ps1 -Show
.\rclone\Mount-LoopSegmentsRclone.ps1 -TestOnly
.\rclone\Mount-LoopSegmentsRclone.ps1          # rclone mount -> drive letter (WinFsp)
```

Or step by step: copy `loop-segments-windows.example.json` → `loop-segments-windows.json`, then `.\setup\Set-LoopSegmentsWindows.ps1`.

Phone LAN is **HTTP + WebDAV** on `:8765` (Basic auth **`admin` / `iosadmin`** — same as Skybox). Writable paths support **PUT** (≤ 2 MB), **MKCOL**, **DELETE**, and **MOVE** (build **282+**; Explorer rename stays on-phone). No server **COPY** yet. **rclone mount** is optional; it can feel sluggish vs browser/Skybox direct WebDAV — see **[rclone/RCLONE-PHONE-MOUNT.md](rclone/RCLONE-PHONE-MOUNT.md)**.

## App LAN vs primary router

The **app LAN gateway** (the AP whose subnet is `phoneLanHost` / AltServer — e.g. `10.0.100.0/24`) is **tethered to a primary router** (upstream WAN / another SSID, e.g. `192.168.2.x`). Phone and PC should associate to the **app LAN** AP, not the primary.

Because that gateway is tethered, its **Wi‑Fi channel must match the primary router’s Wi‑Fi channel**. After changing the primary’s channel, set the same channel on the app LAN gateway (or reboot its Wi‑Fi so it re-locks).

Low Mbps on the **right** subnet is **suspected to be Wi‑Fi channel congestion from neighboring routers** (other APs on or near that channel). Recovery (`Measure-LoopSegmentsLanThroughput.ps1` / companion) therefore **reboots other known routers** (including the primary) and **leaves the current app-LAN gateway up**, so Chromium/pCloud stay connected. It then waits ~20s and re-measures, up to **2** retries, until Mbps ≥ `minLanThroughputMbps` (default **40**).

## pCloud web helper (integrated)

Chromium + MV3 extension lives in **`windows\pcloud_web_companion\`**. Before Chromium starts it checks whether the PC default gateway shares a subnet with `phoneLanHost` (app LAN page); if not, it **reboots Wi‑Fi on the current gateway**, **waits for this PC to get a new LAN IP**, and **retries up to 3 rounds** until the gateway is on the app LAN subnet (via `P:\all_scripts\5g_router_reboot`), then **starts Chromium** so you can browse pCloud while SKYBOX / USB-launch / phone-LAN recover / rclone continue. If `:8765` is down, the extension **queues** downloads (desktop notification) and retries; after ~5 minutes it **denies** them. **Click a toast** to bring the companion PowerShell window to the front. After Chromium is up it **starts SKYBOX VR desktop** via the **`Skybox_vr_pc`** submodule (hide to tray; **does not keep re-hiding** after a tray restore), maps AirScreen **`p_cld_media`**, then **starts Virtual Desktop Streamer** if idle and **hides it to the tray** (`-SkipSkybox` / `-SkipVirtualDesktop` to skip). USB-launches Loop Segments to foreground the app (locked phone no longer blocks Chromium; DVT **`--no-kill-existing`** so a running Keep Alive export is not killed), **attempts an rclone mount** in a separate window (then maps phone **`pcld_ios_media`** in Skybox Add-folders), then **probes LAN Mbps** (HTTP + mount when the letter is up, **HTTP-only** if it is not). If that is below `minLanThroughputMbps` (default **40**), it **reboots other routers** (not this PC’s app-LAN gateway), waits, and re-checks — up to **2** retries. The app LAN gateway is tethered to a primary router; those two APs must use the **same Wi‑Fi channel**.

**Multi-select tip:** in my.pcloud.com, click the **`v`** control to filter the folder by one of **five** types (including **Video**), then multi-select → Download — the companion cancels the zip and queues videos on the phone FIFO. **Folder right-click → Download is not supported** (zip cancelled, no `fileid`s → “no selection ids”); open the folder, select the videos, then Download instead. **Open this folder in pCloud Drive** (Shift+right-click for the Chrome menu — my.pcloud.com blocks a normal right-click — toolbar popup, or **Ctrl+E**) resolves the tree/`folder=` URL and opens the matching path in Explorer in the foreground; the drive letter comes from pCloud `SyncDrive` / the **pCloud Drive** volume, not a hardcoded `P:`. The companion pins the extension on the Chromium toolbar each launch. **CDN view tabs stay open** (Open Original / inline play); the downloads shelf is still cancelled. **Same full href** is not posted again this Chromium session. Details: [`pcloud_web_companion\README.md`](pcloud_web_companion/README.md).

```powershell
.\pcloud_web_companion\Run-PCloudWebCompanion.ps1
# gateway vs phoneLanHost subnet check (reboot current gateway Wi-Fi when needed),
# then starts Chromium; SKYBOX / USB-launch / LAN recover / rclone continue in this window
# (plugin queues downloads if :8765 is down, then denies after ~5 min).
# SKYBOX VR desktop is started after Chromium if installed but idle, then hidden to the tray (-SkipSkybox to skip).
# Virtual Desktop Streamer is started if idle (service started if stopped) and hidden to the tray (-SkipVirtualDesktop to skip).
# Quit also closes Skybox when this companion session started it (already-running Skybox is left).
# locked phone no longer blocks Chromium. Low throughput reboots other APs (not this PC's gateway) and re-checks (up to 2 retries).
# .\pcloud_web_companion\Run-PCloudWebCompanion.ps1 -SkipGatewayReboot  # skip Wi-Fi reboot check
# .\pcloud_web_companion\Run-PCloudWebCompanion.ps1 -SkipUsbLaunch   # Chromium only (still tries rclone if LAN up)
# .\pcloud_web_companion\Run-PCloudWebCompanion.ps1 -EnsureAltServer # AltStore path: start AltServer if idle (default skips)
# .\pcloud_web_companion\Run-PCloudWebCompanion.ps1 -SkipRcloneMount # no drive-letter mount window
# .\pcloud_web_companion\Run-PCloudWebCompanion.ps1 -SkipLanThroughput # no media copy Mbps probe
# .\pcloud_web_companion\Run-PCloudWebCompanion.ps1 -SkipLowThroughputGatewayReboot # keep going even if below minLanThroughputMbps
# Profile: full sync to P:; local AppData cleared after companion finishes (gitignored)
# Quit: close Chromium, or Ctrl+C / console X — quits Skybox if we started it, syncs profile, then USB Home only if the app is still foreground
# On finish: USB Home backgrounds the app when it is still frontmost (needs Keep Alive for export — see ios README).
#   Already backgrounded / locked / no USB → Home skipped. -SkipGoHome never presses Home
```

**Machine-local** (not synced via pCloud): companion venv, Playwright Chromium, and the unpacked extension under `%LOCALAPPDATA%\pcloud_web_companion\`. The repo `.venv` is removed if present — do not recreate it on `P:`.

Details: [`pcloud_web_companion\README.md`](pcloud_web_companion/README.md).

## Open Loop Segments over USB (pymobiledevice3)

Force-launch the app from the PC when the iPhone is **USB-connected** and trusted (iTunes / Apple Mobile Device Support). Used standalone or by `Run-PCloudWebCompanion.ps1` after Chromium. Scripts: `usb\Launch-LoopSegmentsViaUsb.ps1`, `usb\Resolve-LoopSegmentsBundleId.py`, `usb\Probe-IphoneUnlock.py`, `usb\Probe-LoopSegmentsForeground.py`. Skips relaunch when USB DVT already reports the app **foreground** (`-ForceRelaunch` to always launch and allow a process restart). Otherwise DVT uses **`--no-kill-existing`** so a Keep Alive / lock-screen export is only brought forward (not killed). Launch order is **DVT `--userspace` first**; `core-device launch-application --userspace` often times out on the RSD handshake (iOS 26) and is only a fallback — a `TimeoutError` traceback there is not a failed launch if DVT then prints `Process launched with pid`.

```powershell
# Prefer Setup (installs 3.12 tooling). Manual:
py install 3.12
py -3.12 -m pip install -U pymobiledevice3
# Phone: Settings → Privacy & Security → Developer Mode → On
# Unlock phone, then:
.\usb\Launch-LoopSegmentsViaUsb.ps1
# If Developer Disk Image is already mounted:
.\usb\Launch-LoopSegmentsViaUsb.ps1 -SkipMount
```

| Topic | Notes |
|-------|--------|
| Bundle id | Usually `com.loopsegments.app`; AltStore may resign as `com.loopsegments.app.<suffix>`. **USB launch lookup is independent of that suffix** (and of whatever alphanumeric suffix AltStore shows in App IDs / the app name): each run re-resolves on the phone (`Resolve-LoopSegmentsBundleId.py` — prefix `com.loopsegments.app.*` or display name **Loop Segments**). LAN companion talks `:8765` only (ignores bundle id). |
| App ID renew vs suffix | AltStore **Renew App IDs** extends the same Apple slot — it does **not** change the resigned suffix. A new suffix appears only if AltStore **registers a new** App ID (e.g. delete + reinstall after the old slot expired). USB launch still finds the app either way. |
| Unlock | Needed for companion startup USB launch. Exit **3** if locked during launch — companion **warns** and Chromium stays open. Companion always probes LAN (prints UP/DOWN) then USB-launches to foreground the app unless `-SkipUsbLaunch` (skips relaunch when USB DVT already sees Loop Segments **foreground**; otherwise **`--no-kill-existing`** so a running export is not killed). If USB is missing but LAN is UP, warns and continues. Finish-time Home is skipped when the phone is locked (treated as already backgrounded) |
| Home on quit | Companion finish backgrounds Loop Segments over USB (`usb\Go-IphoneHomeViaUsb.ps1`) **only if it is still the foreground app**. Lock screen or already-backgrounded → skip (exit 0). Prefers **DVT `--userspace`** (SpringBoard, then Settings) — the same path as USB launch. **`core-device hid --userspace`** is skipped by default (iOS 26 RSD `TimeoutError` typer dump); pass `-TryUserspaceHid` to try it anyway. No USB → skip. Each attempt times out (~25s); `-SkipGoHome` never presses Home. A failed Home press does **not** fail the companion session (still exit 0), but the window **waits for Enter** so the dump stays readable. Direct runs of the Home script also wait on error unless `-NoWaitEnter`. Export continues in background only if the app’s **Keep Alive** is on (default since build 272 — details in [../ios/README.md](../ios/README.md)) |
| Trust / 7-day cert | Free/Personal Team installs **stop opening after ~7 days** without refresh. **SideStore:** LocalDevVPN → Refresh. **AltStore:** start AltServer → USB + unlock → **Refresh All** → Trust → open once. Scripts **skip AltServer by default**; pass `-EnsureAltServer` / `-EnsureAltStorePrep` for AltStore |
| AltStore UDID (1006) | **“could not determine this device's UDID”** — reinstall AltStore from AltServer (USB). Then **Refresh All**. If Loop Segments is **“not available”**, reinstall the **same** IPA via My Apps → **+** (new GitHub build not required). See tip above / [BUILD-WITHOUT-MAC.md](../ios/BUILD-WITHOUT-MAC.md) |
| AltServer | **Skipped by default** everywhere. Opt-in: companion/USB/setup `-EnsureAltServer`; deploy/copy-to-icloud `-EnsureAltStorePrep`. Optional logon start: `.\sideload\Register-AltServerAtLogon.ps1` |
| “already mounted” | Harmless — DDI is up; script skips remount (or use `-SkipMount`) |
| Background launch | **Not supported** — USB launch opens/foregrounds the app (DVT **`--no-kill-existing`** unless `-ForceRelaunch`); lock only after Keep Alive is running (app setting) |
| iOS 17+ / 26 launch | Tries **`dvt launch --userspace --no-kill-existing`** first (no admin). `core-device --userspace` RSD handshake timeouts are collapsed to one line and the next method is tried. If DVT also fails: elevated `py -3.12 -m pymobiledevice3 remote tunneld`, then `.\usb\Launch-LoopSegmentsViaUsb.ps1 -UseTunneld -SkipMount` |

## Day-to-day mount

After setup, double-click **`rclone\Mount-PhoneL.cmd`** or run:

```cmd
rclone\Mount-PhoneL.cmd
```

Same as `.\rclone\Mount-LoopSegmentsRclone.ps1` — reads **`loop-segments-windows.json`** (IP, drive letter, rclone paths). Leave the window open while **L:** is in use; **Ctrl+C** stops the mount. If `pcld_ios_media/` exists on the phone, the mount **starts there** (`L:\loop`, `L:\archive`, `L:\scripts`) — do not create a nested `L:\pcld_ios_media`. Otherwise Explorer shows `L:\pcld_ios_media\`. After WinFsp attaches, the mount script notifies Explorer (**This PC**) so **L:** appears without F5; the same notify runs when the letter is removed (mount **Ctrl+C** / console X / LAN-watch unmount / `-Remove`). While mounted, the script polls phone `status.json` and **kills rclone + exits** if LAN stays down ~60s (avoids Explorer hangs). If the phone LAN page cannot be reached at mount time, **`..\lan\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1`** runs **in-process** and uses USB/`pcapd` (`env_setup\altserver_refresh`) to align the phone with the PC/AltServer subnet (or, without USB, reboots off-subnet routers under `P:\all_scripts\5g_router_reboot`), then retries (`-SkipOffSubnetRouterReboot` to disable). Mount log: **`%TEMP%\loopsegments-rclone-mount.log`** (copied to **`rclone\loopsegments-rclone-mount.log`** on quit). If the IP changed: `.\setup\Set-LoopSegmentsLANHost.ps1 <new-ip>` first.

Optional args: **`rclone\Mount-PhoneL.cmd -ReadOnly`**, **`-Remove`**, **`-TestOnly`**, **`-Unstick`**, **`-Quick`**, **`-NoLanWatch`**, **`-LanDownSeconds`**, **`-LanPollSeconds`**.

**Explorer frozen after LAN dies:** wait for auto-unmount, or run **`rclone\Unstick-PhoneL.cmd`** (kills mount + restarts Explorer). If Explorer is already wedged: Task Manager → File → Run new task → full path to `Unstick-PhoneL.cmd`.

## Multiple iPhones — unified LAN listing

Each phone runs its own LAN server on **`http://<phone-ip>:8765/`**. To browse **all** phones from one place on the PC:

1. Add every phone to **`phoneLanHosts`** in `loop-segments-windows.json` (keep **`phoneLanHost`** as the primary rclone mount target):

```json
"phoneLanHost": "192.168.1.42",
"phoneLanHosts": [
  { "host": "192.168.1.42", "label": "iPhone A" },
  { "host": "192.168.1.43", "label": "iPhone B" }
]
```

2. One-shot JSON or HTML:

```powershell
.\lan\Get-LoopSegmentsUnifiedLANListing.ps1
.\lan\Get-LoopSegmentsUnifiedLANListing.ps1 -Format html -OutFile unified-lan.html
```

3. Live index page on the PC (re-polls phones on each refresh):

```powershell
.\lan\Serve-LoopSegmentsUnifiedLAN.ps1
# Open http://<pc-ip>:8766/
```

Links in the unified view point back to each phone’s `:8765` URL — playback and WebDAV still go to the phone that holds the file. **`rclone\Mount-LoopSegmentsRclone.ps1`** still mounts **one** phone at a time (`phoneLanHost`).

### LAN throughput (after rclone mount)

With **`L:`** up, measure PC ↔ phone Wi‑Fi both ways (phone HTTP + rclone mount copy) using a random media file under `L:\archive\` (or `L:\pcld_ios_media\archive\` if the mount is WebDAV root) (≥ `-MinBytes`, default **8 MB**):

```powershell
.\rclone\Mount-PhoneL.cmd          # leave open
.\lan\Measure-LoopSegmentsLanThroughput.ps1
# .\lan\Measure-LoopSegmentsLanThroughput.ps1 -MaxBytes 0      # full file
# .\lan\Measure-LoopSegmentsLanThroughput.ps1 -KeepLocal       # keep temp copy
```

Reports MB transferred and Mbps (default caps at **64 MB**), then recommends a **max media bitrate** for minute segments (**80%** of measured LAN, clamped 5–100 Mbps) and writes sidecars under `L:\scripts\lan_throughput.json` and `L:\archive\lan_recommended_segment_bitrate.json` (same names under `L:\pcld_ios_media\` if the mount is WebDAV root). **`run_batch_vr_hybrid.ps1`** / **`Run-TranscodeFfmpeg.ps1`** pick that up for `-SegmentVideoBitrateMbps` (flat + fisheye pass-2). If measured throughput is below **`minLanThroughputMbps`** (default **40**), **reboots Wi‑Fi on every known router except the current default gateway**, waits ~20s, and **re-measures** — up to **2** retries, or until throughput is at least the minimum. Companion runs the same loop after Chromium is open (this PC’s AP is left up). This is **not** 5G WAN speed.

**Do not run the probe during an active Virtual Desktop headset session.** VD streaming the PC screen uses about **50 Mbps** of LAN and will understate phone LAN capacity. The measure script prints this on the console (and warns again if Streamer is running).

## What goes in `loop-segments-windows.json`

| Field | Purpose |
|-------|---------|
| `phoneLanHost` | Primary iPhone IP for rclone mount (changes per Wi‑Fi) |
| `phoneLanHosts` | Optional array `{ host, label?, port? }` — unified LAN listing across multiple iPhones |
| `lanPort` | Usually `8765` |
| `minLanThroughputMbps` | Companion/measure: if LAN probe is below this (default `40`), reboot other routers (not current gateway), settle, re-check (up to 2 retries) |
| `mountDriveLetter` | Preferred phone mount letter (default `L`). If that letter is already taken (e.g. Koofr), mount picks a **random free D–Z** and saves it here so Unstick/companion stay in sync. Reuse if rclone is already on that letter. |
| `rcloneRemoteName` | Block name in `rclone.conf` for the phone (default `loopsegments`) |
| `rcloneConfigPath` | **Empty** = auto (`%APPDATA%\rclone\rclone.conf`; created blank on first mount if missing). Only set a full path for a non-default location. |
| `rcloneExe` | **Empty** = `rclone` on PATH |
| `winfspDllPath` | **Empty** = search Program Files; set full path if detection fails |
| `skipWinFspCheck` | `true` if Koofr mount already proves WinFsp works |
| `webdavUser` / `webdavPassword` | Phone LAN WebDAV (defaults match app) |
| `iCloudDownloads` | **Empty** = `%USERPROFILE%\iCloudDrive\Downloads` — target for repo-root **`copy-to-icloud.ps1`** (also used by **`deploy.ps1`**) |
| `dlnaFolder` | Optional note for Skybox / junction target |
| `skyboxExe` | Optional full path to **SKYBOX.exe** if auto-detect misses (companion starts SKYBOX VR desktop when idle and hides it to the tray) |
| `virtualDesktopStreamerExe` | Optional full path to **VirtualDesktop.Streamer.exe** if auto-detect misses (companion starts Streamer when idle, starts the service if stopped, and hides Streamer to the tray) |
| `notes` | Free text (e.g. "Koofr remote = koofr on M:") |

## Koofr + Loop Segments on one PC

- **Koofr** and **loopsegments** can share one **`rclone.conf`** — different remote names and drive letters.
- Example: Koofr on **`M:`**, phone on **`L:`** via `mountDriveLetter`.

## Moving to another PC

1. Clone, copy, or sync the repo (`.pcloudignore` skips per-PC junk; do **not** commit `loop-segments-windows.json`).
2. On the new PC: `.\setup\Setup-LoopSegmentsWindows.ps1 -PhoneHost <ip>` (clears foreign `rcloneConfigPath`, builds a local companion venv).
3. Leave **`rcloneConfigPath`** empty unless this PC stores rclone.conf somewhere non-standard.
4. Do **not** rely on a synced `pcloud_web_companion\.venv` — it embeds absolute Python paths from the old user/PC.

| Stays on P: / repo (intentional) | Machine-local only |
|----------------------------------|--------------------|
| Extension source, scripts | `%LOCALAPPDATA%\pcloud_web_companion\venv` |
| `chromium-profile.zip` (shared pCloud login) | Playwright browsers, unpacked extension, REST log |
| | `loop-segments-windows.json` (per-PC phone IP) |

Legacy one-line IP file `loop-segments-lan-host.txt` is still updated for compatibility (gitignored).

## Scripts

| Script | Role |
|--------|------|
| `setup\Setup-LoopSegmentsWindows.ps1` | **New PC bootstrap** — Python 3.12 / pymobiledevice3 / companion venv / portable json |
| `lib\Get-LoopSegmentsPython.ps1` | Shared Python picker (dot-sourced; prefer 3.12, skip 3.14+) |
| `lib\LoopSegments-Windows.ps1` | Shared config (dot-sourced; do not run alone) |
| `lib\Get-LoopSegmentsAltServer.ps1` | Loop Segments wrapper around **`..\env_setup\altserver_refresh\lib\Get-AltServer.ps1`** (locate/start); 7-day / Trust copy stays here |
| `lib\Get-LoopSegmentsSkybox.ps1` | Companion Skybox setup/teardown: dotsources repo-root **`Skybox_vr_pc`** submodule ([skybox-vr-pc](https://github.com/dsouzaankit/skybox-vr-pc); fallback `P:\all_scripts\Skybox_vr_pc`) for start/hide/quit + AirScreen `p_cld_media`, maps phone rclone `pcld_ios_media` (`-SkipSkybox` to skip) |
| `lib\Get-LoopSegmentsVirtualDesktop.ps1` | Locate/start **Virtual Desktop Streamer**, start the service if it is stopped, and hide the Streamer window to the **tray** (`-SkipVirtualDesktop` to skip). Companion finish does not quit Streamer |
| `lib\Get-LoopSegmentsClash.ps1` | Optional: if Clash/mihomo is running, UAC-run **`env_setup\altserver_refresh\VpnMulticast\Remove-VpnMulticastRoute.ps1`** so TUN `224.0.0.0/4` does not steal `.local` mDNS. Phone-IP / `:8765` use numeric IPs and do not need this. |
| `setup\Set-LoopSegmentsWindows.ps1` | Edit per-PC json |
| `setup\Set-LoopSegmentsLANHost.ps1` | Quick IP-only update |
| `lan\Get-LoopSegmentsUnifiedLANListing.ps1` | **Pool media listings** from all `phoneLanHosts` → JSON or HTML |
| `lan\Serve-LoopSegmentsUnifiedLAN.ps1` | PC HTTP index on `:8766` (merged view; phones still serve files on `:8765`) |
| `lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1` | Wrong-subnet **loop** (wait tcp/23 → reboot → wait up to ~20s for new PC LAN IP or AP back on telnet → re-check, max 3 rounds; telnet fail continues) / forced / **off-subnet sequential** / **`-BouncePhoneLanAp`** (phone LAN page subnet AP after Wi‑Fi→www probe fail; ~20s tcp/23 wait; if WifiRestart drops the telnet session then tcp/23 returns, treats that as success and does **not** reboot twice; exits 1 if bounce does not confirm). Direct run waits for Enter; companion passes `-NoWaitEnter`. |
| `lan\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1` | In-process USB/`pcapd` via **`env_setup\altserver_refresh`** (phone IP vs PC/AltServer subnet), then wait for `:8765`. If already on-subnet, does not reboot just because the app is down. No USB / no Wi-Fi IP / no PC LAN IPv4 / AltServer subnet fail: wait then reboot off-subnet routers. `-NoWaitEnter` throws `LAN_RECOVER_EXIT:<code>` so companion/rclone are not killed. |
| `lan\Measure-LoopSegmentsLanThroughput.ps1` | Time up to 64 MB via phone HTTP from a random `L:\archive\` (or `L:\pcld_ios_media\archive\`) media file → Mbps + recommended max segment bitrate sidecar for hybrid batch |
| `rclone\Mount-PhoneL.cmd` | **Day-to-day** launcher → `Mount-LoopSegmentsRclone.ps1` |
| `rclone\Unstick-PhoneL.cmd` | Kill dead phone mount + restart Explorer |
| `rclone\Mount-LoopSegmentsRclone.ps1` | **`-TestOnly`** / mount / **`-Remove`** / **`-Unstick`** / **`-Quick`** / LAN watch / **`-RemovePort80Proxy`** |
| `%TEMP%\loopsegments-rclone-mount.log` | live rclone mount log (copied to `rclone\loopsegments-rclone-mount.log` on quit) |
| `pcloud_web_companion\Run-PCloudWebCompanion.ps1` | pCloud Chromium companion: gateway subnet check/reboot, USB-launch Loop Segments, sync profile, start browser |
| `usb\Launch-LoopSegmentsViaUsb.ps1` | Force-open Loop Segments over USB (`pymobiledevice3`); DVT `--userspace --no-kill-existing` first; skips if already foreground; exit **3** if phone locked |
| `usb\Go-IphoneHomeViaUsb.ps1` | Background the app on companion finish if it is still foreground (skip when backgrounded or lock screen; DVT `--userspace` first; HID `--userspace` skipped unless `-TryUserspaceHid`); no USB → skip. Direct run waits for Enter on error; companion/watchdog pass `-NoWaitEnter` and companion pauses itself after a Home fail |
| `usb\Probe-IphoneUnlock.py` / `usb\Resolve-LoopSegmentsBundleId.py` / `usb\Probe-LoopSegmentsForeground.py` | Helpers for USB unlock probe, AltStore bundle-id suffix, and foreground skip |
| `pcloud_web_companion/` | MV3 extension + `run_chromium.ps1` (see that folder’s README) |
| `sideload\Register-AltServerAtLogon.ps1` | **AltStore only:** AltServer at logon. **SideStore:** skip or `-Unregister` (LocalDevVPN Wi‑Fi refresh; no PC). UsbWatch is a **different** task — unregister with `env_setup\altserver_refresh\usb\Register-IphoneUsbAltServer.ps1 -Unregister` |
| `sideload\Register-SideloadlyAutoRefresh.ps1` | **Fallback only** — Sideloadly daemon if AltStore fails |
| `archive/` | Legacy `net use` / port-80 proxy, `Sync-FromPhoneLAN.ps1`, optional HTTP **`Copy-ToLoopSegmentsPhoneLAN.ps1`** (no **L:** mount) |

If you previously registered Sideloadly USB-watch tasks, re-run `.\sideload\Register-SideloadlyAutoRefresh.ps1 -WatchUsb` once so the scheduled task points at the new script path.

### Legacy WebDAV mapped to `http://localhost/`

`-ViaPort80Proxy` (archive script) added a **local** `:80` redirect to the phone. Prefer **`http://<phone-ip>:8765/`** + rclone today. Cleanup:

1. Run **elevated**: `.\rclone\Mount-LoopSegmentsRclone.ps1 -RemovePort80Proxy`
2. **`net use L: /delete /y`** if Explorer still shows an old mapping.

See [../ios/README.md](../ios/README.md) and [../WORKFLOW.md](../WORKFLOW.md).
