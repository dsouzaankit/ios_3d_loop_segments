# Loop Segments — Windows (portable)

Scripts work on **any Windows PC** after you copy or clone this repo. Machine-specific paths live in **`loop-segments-windows.json`** (gitignored) in this folder. Shared helpers live in **`lib\`**; entry-point scripts are grouped by role under subfolders.

**PowerShell:** scripts target **Windows PowerShell 5.1** (`#Requires -Version 5.1`, built into Windows — no PowerShell 7 / `pwsh` install needed). Child helpers (REST log sink, exit watchdog, USB launch) also call **`powershell.exe`** (5.1), not `pwsh`. That is why a blue console can appear for USB launch; background helpers use a no-window start so they should not flash.

## Layout

| Folder | Role |
|--------|------|
| *(this folder)* | `README.md`, `loop-segments-windows.json` (+ example), legacy `loop-segments-lan-host.txt` |
| `lib/` | Shared helpers: `LoopSegments-Windows.ps1`, Python picker, AltServer helpers |
| `setup/` | New-PC bootstrap + edit per-PC json / LAN IP |
| `usb/` | Force-open / Home over USB (`pymobiledevice3`) |
| `sideload/` | AltServer logon task; Sideloadly fallback |
| `lan/` | Multi-phone unified listing / PC index on `:8766` |
| `rclone/` | Optional WinFsp drive-letter mount |
| `pcloud_web_companion/` | Chromium MV3 companion + `Run-PCloudWebCompanion.ps1` |
| `archive/` | Legacy `net use` / sync scripts |

## Typical `.ps1` run sequence (`windows\`)

```powershell
cd <repo>\windows

# 1) Once per PC (Python 3.12, pymobiledevice3, companion venv/Chromium, portable json)
.\setup\Setup-LoopSegmentsWindows.ps1 -PhoneHost 10.0.100.10

# 2) Once (optional): AltServer at logon — needed for AltStore / ~7-day sideload refresh
.\sideload\Register-AltServerAtLogon.ps1

# 3) Day-to-day: pCloud companion (prints LAN status; always USB-foregrounds app unless -SkipUsbLaunch)
.\pcloud_web_companion\Run-PCloudWebCompanion.ps1
#    Quit: close Chromium, Ctrl+C, or console X — kills Chromium, syncs profile,
#    then USB Home (app Keep Alive default on — see ../ios/README.md; -SkipGoHome to skip)

# Optional helpers
.\setup\Set-LoopSegmentsWindows.ps1 -Show          # show/edit per-PC json
.\setup\Set-LoopSegmentsLANHost.ps1 <phone-ip>     # IP changed on Wi-Fi
.\usb\Launch-LoopSegmentsViaUsb.ps1 -SkipMount    # open app over USB only
.\rclone\Mount-LoopSegmentsRclone.ps1 -TestOnly   # probe phone LAN / WebDAV
.\rclone\Mount-LoopSegmentsRclone.ps1             # mount L: (optional; WinFsp)
```

If Loop Segments won’t open after ~7 days: start **AltServer** → USB + unlock → AltStore **Refresh All** → **Settings → General → VPN & Device Management → DEVELOPER APP → iPhone Developer: \<email\> → Trust** (entry may appear only after a failed open) → open app once → retry.

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

Phone LAN is **HTTP + WebDAV** on `:8765` (Basic auth **`admin` / `iosadmin`** — same as Skybox). **rclone mount** is optional; it can feel sluggish vs browser/Skybox direct WebDAV — see **[rclone/RCLONE-PHONE-MOUNT.md](rclone/RCLONE-PHONE-MOUNT.md)**.

## pCloud web helper (integrated)

Chromium + MV3 extension lives in **`windows\pcloud_web_companion\`**. Before Chromium starts it prints LAN status, then USB-launches Loop Segments to foreground the app (blocks if the phone is locked).

**Multi-select tip:** in my.pcloud.com, click the **`v`** control to filter the folder by one of **five** types (including **Video**), then multi-select → Download — the companion cancels the zip and queues videos on the phone FIFO.

```powershell
.\pcloud_web_companion\Run-PCloudWebCompanion.ps1
# prints LAN UP/DOWN, then always USB-launches / foregrounds the app (locked → exit 3)
# .\pcloud_web_companion\Run-PCloudWebCompanion.ps1 -SkipUsbLaunch   # Chromium only
# Profile: full sync to P:; local AppData cleared after companion finishes (gitignored)
# Quit: close Chromium, or Ctrl+C / console X — syncs profile, then USB Home if unlocked
# On finish: USB Home backgrounds the app (needs Keep Alive for export — see ios README).
#   Locked / no USB → Home skipped. -SkipGoHome leaves app foreground
```

**Machine-local** (not synced via pCloud): companion venv, Playwright Chromium, and the unpacked extension under `%LOCALAPPDATA%\pcloud_web_companion\`. The repo `.venv` is removed if present — do not recreate it on `P:`.

Details: [`pcloud_web_companion\README.md`](pcloud_web_companion/README.md).

## Open Loop Segments over USB (pymobiledevice3)

Force-launch the app from the PC when the iPhone is **USB-connected** and trusted (iTunes / Apple Mobile Device Support). Used standalone or by `Run-PCloudWebCompanion.ps1` before Chromium. Scripts: `usb\Launch-LoopSegmentsViaUsb.ps1`, `usb\Resolve-LoopSegmentsBundleId.py`, `usb\Probe-IphoneUnlock.py`.

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
| Unlock | Needed for companion startup USB launch **and** for finish-time Home press. Exit **3** if locked during launch — companion will not start Chromium. Companion always probes LAN (prints UP/DOWN) then USB-launches to foreground the app unless `-SkipUsbLaunch`. Home on quit still needs unlock if you want the app backgrounded |
| Home on quit | Companion finish presses **Home** over USB (`usb\Go-IphoneHomeViaUsb.ps1`) to background Loop Segments. Requires USB + **unlocked** phone; otherwise skipped. Each pymobiledevice3 attempt times out (~25s) so finish cannot hang forever; `-SkipGoHome` leaves the app foreground. Export continues in background only if the app’s **Keep Alive** is on (default since build 272 — details in [../ios/README.md](../ios/README.md)) |
| Trust / 7-day cert | Free/Personal Team installs **stop opening after ~7 days** without AltStore refresh (cert refresh — separate from App ID renew above). **Resolution:** start AltServer → USB + unlock → AltStore **Refresh All** → **Settings → General → VPN & Device Management → Developer App → Trust** → open Loop Segments once → retry. Missing AltServer is always reported. USB detect failure auto-starts AltServer when installed |
| AltStore UDID (1006) | **“could not determine this device's UDID”** — reinstall AltStore from AltServer (USB). Then **Refresh All**. If Loop Segments is **“not available”**, reinstall the **same** IPA via My Apps → **+** (new GitHub build not required). See tip above / [BUILD-WITHOUT-MAC.md](../ios/BUILD-WITHOUT-MAC.md) |
| AltServer | Companion / USB launch / Setup always report status + the unavailable-app resolution. Optional logon start: `.\sideload\Register-AltServerAtLogon.ps1` |
| “already mounted” | Harmless — DDI is up; script skips remount (or use `-SkipMount`) |
| Background launch | **Not supported** — USB launch opens the app; lock only after Keep Alive is running (app setting) |
| iOS 17+ tunnel | If DVT fails: elevated `py -3.12 -m pymobiledevice3 remote tunneld`, then `.\usb\Launch-LoopSegmentsViaUsb.ps1 -UseTunneld -SkipMount` |

## Day-to-day mount

After setup, double-click **`rclone\Mount-PhoneL.cmd`** or run:

```cmd
rclone\Mount-PhoneL.cmd
```

Same as `.\rclone\Mount-LoopSegmentsRclone.ps1` — reads **`loop-segments-windows.json`** (IP, drive letter, rclone paths). Leave the window open while **L:** is in use; **Ctrl+C** stops the mount. If the IP changed: `.\setup\Set-LoopSegmentsLANHost.ps1 <new-ip>` first.

Optional args: **`rclone\Mount-PhoneL.cmd -ReadOnly`**, **`-Remove`**, **`-TestOnly`**.

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

## What goes in `loop-segments-windows.json`

| Field | Purpose |
|-------|---------|
| `phoneLanHost` | Primary iPhone IP for rclone mount (changes per Wi‑Fi) |
| `phoneLanHosts` | Optional array `{ host, label?, port? }` — unified LAN listing across multiple iPhones |
| `lanPort` | Usually `8765` |
| `mountDriveLetter` | Drive letter for phone mount (default `L`; pick another if Koofr uses `L`) |
| `rcloneRemoteName` | Block name in `rclone.conf` for the phone (default `loopsegments`) |
| `rcloneConfigPath` | **Empty** = auto (`%APPDATA%\rclone\rclone.conf`; created blank on first mount if missing). Only set a full path for a non-default location. |
| `rcloneExe` | **Empty** = `rclone` on PATH |
| `winfspDllPath` | **Empty** = search Program Files; set full path if detection fails |
| `skipWinFspCheck` | `true` if Koofr mount already proves WinFsp works |
| `webdavUser` / `webdavPassword` | Phone LAN WebDAV (defaults match app) |
| `dlnaFolder` | Optional note for Skybox / junction target |
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
| `chromium-profile\` (shared pCloud login) | Playwright browsers, unpacked extension, REST log |
| | `loop-segments-windows.json` (per-PC phone IP) |

Legacy one-line IP file `loop-segments-lan-host.txt` is still updated for compatibility (gitignored).

## Scripts

| Script | Role |
|--------|------|
| `setup\Setup-LoopSegmentsWindows.ps1` | **New PC bootstrap** — Python 3.12 / pymobiledevice3 / companion venv / portable json |
| `lib\Get-LoopSegmentsPython.ps1` | Shared Python picker (dot-sourced; prefer 3.12, skip 3.14+) |
| `lib\LoopSegments-Windows.ps1` | Shared config (dot-sourced; do not run alone) |
| `lib\Get-LoopSegmentsAltServer.ps1` | Locate/start AltServer; warn if missing (7-day AltStore expiry) |
| `setup\Set-LoopSegmentsWindows.ps1` | Edit per-PC json |
| `setup\Set-LoopSegmentsLANHost.ps1` | Quick IP-only update |
| `lan\Get-LoopSegmentsUnifiedLANListing.ps1` | **Pool media listings** from all `phoneLanHosts` → JSON or HTML |
| `lan\Serve-LoopSegmentsUnifiedLAN.ps1` | PC HTTP index on `:8766` (merged view; phones still serve files on `:8765`) |
| `rclone\Mount-PhoneL.cmd` | **Day-to-day** launcher → `Mount-LoopSegmentsRclone.ps1` |
| `rclone\Mount-LoopSegmentsRclone.ps1` | **`-TestOnly`** / mount / **`-Remove`** / **`-RemovePort80Proxy`** |
| `pcloud_web_companion\Run-PCloudWebCompanion.ps1` | pCloud Chromium companion: USB-launch Loop Segments, sync profile, start browser |
| `usb\Launch-LoopSegmentsViaUsb.ps1` | Force-open Loop Segments over USB (`pymobiledevice3`); exit **3** if phone locked |
| `usb\Go-IphoneHomeViaUsb.ps1` | Press Home over USB to background the app (companion finish); needs USB + unlocked; exit **3** if locked |
| `usb\Probe-IphoneUnlock.py` / `usb\Resolve-LoopSegmentsBundleId.py` | Helpers for USB unlock probe + AltStore bundle-id suffix |
| `pcloud_web_companion/` | MV3 extension + `run_chromium.ps1` (see that folder’s README) |
| `sideload\Register-AltServerAtLogon.ps1` | **AltServer** at logon ([BUILD-WITHOUT-MAC.md](../ios/BUILD-WITHOUT-MAC.md) §3). Wi‑Fi refresh often fails on Win11 — **USB + AltStore Refresh All** weekly is the reliable path |
| `sideload\Register-SideloadlyAutoRefresh.ps1` | **Fallback only** — Sideloadly daemon if AltStore fails |
| `archive/` | Legacy `net use` / port-80 proxy, `Sync-FromPhoneLAN.ps1`, optional HTTP **`Copy-ToLoopSegmentsPhoneLAN.ps1`** (no **L:** mount) |

If you previously registered Sideloadly USB-watch tasks, re-run `.\sideload\Register-SideloadlyAutoRefresh.ps1 -WatchUsb` once so the scheduled task points at the new script path.

### Legacy WebDAV mapped to `http://localhost/`

`-ViaPort80Proxy` (archive script) added a **local** `:80` redirect to the phone. Prefer **`http://<phone-ip>:8765/`** + rclone today. Cleanup:

1. Run **elevated**: `.\rclone\Mount-LoopSegmentsRclone.ps1 -RemovePort80Proxy`
2. **`net use L: /delete /y`** if Explorer still shows an old mapping.

See [../ios/README.md](../ios/README.md) and [../WORKFLOW.md](../WORKFLOW.md).
