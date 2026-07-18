# Loop Segments — Windows (portable)

Scripts work on **any Windows PC** after you copy or clone this repo. Machine-specific paths live in **`loop-segments-windows.json`** (gitignored), not in the scripts. All scripts resolve paths from **`$PSScriptRoot`** in this folder.

**PowerShell:** scripts target **Windows PowerShell 5.1** (`#Requires -Version 5.1`, built into Windows — no PowerShell 7 / `pwsh` install needed). Child helpers (REST log sink, exit watchdog, USB launch) also call **`powershell.exe`** (5.1), not `pwsh`. That is why a blue console can appear for USB launch; background helpers use a no-window start so they should not flash.

## Typical `.ps1` run sequence (`windows\`)

```powershell
cd <repo>\windows

# 1) Once per PC (Python 3.12, pymobiledevice3, companion venv/Chromium, portable json)
.\Setup-LoopSegmentsWindows.ps1 -PhoneHost 10.0.100.10

# 2) Once (optional): AltServer at logon — needed for AltStore / ~7-day sideload refresh
.\Register-AltServerAtLogon.ps1

# 3) Day-to-day: pCloud companion (probes :8765/browse; USB-launches app if LAN down)
.\Run-PCloudWebCompanion.ps1
#    Quit: close Chromium, Ctrl+C, or console X — kills Chromium, syncs profile,
#    then USB Home (app Keep Alive default on — see ../ios/README.md; -SkipGoHome to skip)

# Optional helpers
.\Set-LoopSegmentsWindows.ps1 -Show          # show/edit per-PC json
.\Set-LoopSegmentsLANHost.ps1 <phone-ip>     # IP changed on Wi-Fi
.\Launch-LoopSegmentsViaUsb.ps1 -SkipMount   # open app over USB only
.\Mount-LoopSegmentsRclone.ps1 -TestOnly     # probe phone LAN / WebDAV
.\Mount-LoopSegmentsRclone.ps1               # mount L: (optional; WinFsp)
```

If Loop Segments won’t open after ~7 days: start **AltServer** → USB + unlock → AltStore **Refresh All** → **Settings → General → VPN & Device Management → DEVELOPER APP → iPhone Developer: \<email\> → Trust** (entry may appear only after a failed open) → open app once → retry.

## First time on a PC

```powershell
cd <repo>\windows   # e.g. where this README lives

# One shot: Python 3.12 + pymobiledevice3 + companion venv/Chromium + portable json
.\Setup-LoopSegmentsWindows.ps1 -PhoneHost 10.0.100.10

.\Set-LoopSegmentsWindows.ps1 -Show
.\Mount-LoopSegmentsRclone.ps1 -TestOnly
.\Mount-LoopSegmentsRclone.ps1          # rclone mount -> drive letter (WinFsp)
```

Or step by step: copy `loop-segments-windows.example.json` → `loop-segments-windows.json`, then `.\Set-LoopSegmentsWindows.ps1`.

Phone LAN is **HTTP + WebDAV** on `:8765` (Basic auth **`admin` / `iosadmin`** — same as Skybox). **rclone mount** is optional; it can feel sluggish vs browser/Skybox direct WebDAV — see **[RCLONE-PHONE-MOUNT.md](RCLONE-PHONE-MOUNT.md)**.

## pCloud web helper (integrated)

Chromium + MV3 extension lives in **`windows\pcloud_web_companion\`**. Before Chromium starts it runs the USB launch script (blocks if the phone is locked).

```powershell
.\Run-PCloudWebCompanion.ps1
# if :8765/browse is already up → skip unlock/USB launch; else unlock first (locked → exit 3)
# .\Run-PCloudWebCompanion.ps1 -SkipUsbLaunch   # Chromium only
# Profile: full sync to P:; local AppData cleared after companion finishes (gitignored)
# Quit: close Chromium, or Ctrl+C / console X — syncs profile, then USB Home if unlocked
# On finish: USB Home backgrounds the app (needs Keep Alive for export — see ios README).
#   Locked / no USB → Home skipped. -SkipGoHome leaves app foreground
```

**Machine-local** (not synced via pCloud): companion venv, Playwright Chromium, and the unpacked extension under `%LOCALAPPDATA%\pcloud_web_companion\`. The repo `.venv` is removed if present — do not recreate it on `P:`.

Details: [`pcloud_web_companion\README.md`](pcloud_web_companion/README.md).

## Open Loop Segments over USB (pymobiledevice3)

Force-launch the app from the PC when the iPhone is **USB-connected** and trusted (iTunes / Apple Mobile Device Support). Used standalone or by `Run-PCloudWebCompanion.ps1` before Chromium. Scripts: `Launch-LoopSegmentsViaUsb.ps1`, `Resolve-LoopSegmentsBundleId.py`, `Probe-IphoneUnlock.py`.

```powershell
# Prefer Setup (installs 3.12 tooling). Manual:
py install 3.12
py -3.12 -m pip install -U pymobiledevice3
# Phone: Settings → Privacy & Security → Developer Mode → On
# Unlock phone, then:
.\Launch-LoopSegmentsViaUsb.ps1
# If Developer Disk Image is already mounted:
.\Launch-LoopSegmentsViaUsb.ps1 -SkipMount
```

| Topic | Notes |
|-------|--------|
| Bundle id | Usually `com.loopsegments.app`; AltStore may resign as `com.loopsegments.app.<suffix>`. **USB launch lookup is independent of that suffix** (and of whatever alphanumeric suffix AltStore shows in App IDs / the app name): each run re-resolves on the phone (`Resolve-LoopSegmentsBundleId.py` — prefix `com.loopsegments.app.*` or display name **Loop Segments**). LAN companion talks `:8765` only (ignores bundle id). |
| App ID renew vs suffix | AltStore **Renew App IDs** extends the same Apple slot — it does **not** change the resigned suffix. A new suffix appears only if AltStore **registers a new** App ID (e.g. delete + reinstall after the old slot expired). USB launch still finds the app either way. |
| Unlock | Needed when LAN is down (USB launch) **and** for finish-time Home press. Exit **3** if locked during launch — companion will not start Chromium. If `:8765/browse` is already reachable, USB launch is skipped; Home on quit still needs unlock if you want the app backgrounded |
| Home on quit | Companion finish presses **Home** over USB (`Go-IphoneHomeViaUsb.ps1`) to background Loop Segments. Requires USB + **unlocked** phone; otherwise skipped. `-SkipGoHome` leaves the app foreground. Export continues in background only if the app’s **Keep Alive** is on (default since build 272 — details in [../ios/README.md](../ios/README.md)) |
| Trust / 7-day cert | Free/Personal Team installs **stop opening after ~7 days** without AltStore refresh (cert refresh — separate from App ID renew above). **Resolution:** start AltServer → USB + unlock → AltStore **Refresh All** → **Settings → General → VPN & Device Management → Developer App → Trust** → open Loop Segments once → retry. Missing AltServer is always reported. USB detect failure auto-starts AltServer when installed |
| AltServer | Companion / USB launch / Setup always report status + the unavailable-app resolution. Optional logon start: `.\Register-AltServerAtLogon.ps1` |
| “already mounted” | Harmless — DDI is up; script skips remount (or use `-SkipMount`) |
| Background launch | **Not supported** — USB launch opens the app; lock only after Keep Alive is running (app setting) |
| iOS 17+ tunnel | If DVT fails: elevated `py -3.12 -m pymobiledevice3 remote tunneld`, then `.\Launch-LoopSegmentsViaUsb.ps1 -UseTunneld -SkipMount` |

## Day-to-day mount

After setup, double-click **`Mount-PhoneL.cmd`** or run:

```cmd
Mount-PhoneL.cmd
```

Same as `.\Mount-LoopSegmentsRclone.ps1` — reads **`loop-segments-windows.json`** (IP, drive letter, rclone paths). Leave the window open while **L:** is in use; **Ctrl+C** stops the mount. If the IP changed: `.\Set-LoopSegmentsLANHost.ps1 <new-ip>` first.

Optional args: **`Mount-PhoneL.cmd -ReadOnly`**, **`-Remove`**, **`-TestOnly`**.

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
.\Get-LoopSegmentsUnifiedLANListing.ps1
.\Get-LoopSegmentsUnifiedLANListing.ps1 -Format html -OutFile unified-lan.html
```

3. Live index page on the PC (re-polls phones on each refresh):

```powershell
.\Serve-LoopSegmentsUnifiedLAN.ps1
# Open http://<pc-ip>:8766/
```

Links in the unified view point back to each phone’s `:8765` URL — playback and WebDAV still go to the phone that holds the file. **`Mount-LoopSegmentsRclone.ps1`** still mounts **one** phone at a time (`phoneLanHost`).

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
2. On the new PC: `.\Setup-LoopSegmentsWindows.ps1 -PhoneHost <ip>` (clears foreign `rcloneConfigPath`, builds a local companion venv).
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
| `Setup-LoopSegmentsWindows.ps1` | **New PC bootstrap** — Python 3.12 / pymobiledevice3 / companion venv / portable json |
| `Get-LoopSegmentsPython.ps1` | Shared Python picker (dot-sourced; prefer 3.12, skip 3.14+) |
| `LoopSegments-Windows.ps1` | Shared config (dot-sourced; do not run alone) |
| `Set-LoopSegmentsWindows.ps1` | Edit per-PC json |
| `Set-LoopSegmentsLANHost.ps1` | Quick IP-only update |
| `Get-LoopSegmentsUnifiedLANListing.ps1` | **Pool media listings** from all `phoneLanHosts` → JSON or HTML |
| `Serve-LoopSegmentsUnifiedLAN.ps1` | PC HTTP index on `:8766` (merged view; phones still serve files on `:8765`) |
| `Mount-PhoneL.cmd` | **Day-to-day** launcher → `Mount-LoopSegmentsRclone.ps1` |
| `Mount-LoopSegmentsRclone.ps1` | **`-TestOnly`** = HTTP + PROPFIND + `rclone ls`; default = **read/write** **L:** (copy bootstrap `.ps1` and folders under `pcld_ios_media\`; ≤ 2 MB per file on phone); **`-ReadOnly`** = DLNA-only; **`-Remove`** / **`-RemovePort80Proxy`** |
| `Run-PCloudWebCompanion.ps1` | pCloud Chromium companion: USB-launch Loop Segments, sync profile, start browser |
| `Launch-LoopSegmentsViaUsb.ps1` | Force-open Loop Segments over USB (`pymobiledevice3`); exit **3** if phone locked |
| `Go-IphoneHomeViaUsb.ps1` | Press Home over USB to background the app (companion finish); needs USB + unlocked; exit **3** if locked |
| `Probe-IphoneUnlock.py` / `Resolve-LoopSegmentsBundleId.py` | Helpers for USB unlock probe + AltStore bundle-id suffix |
| `pcloud_web_companion/` | MV3 extension + `run_chromium.ps1` (see that folder’s README) |
| `Get-LoopSegmentsAltServer.ps1` | Locate/start AltServer; warn if missing (7-day AltStore expiry) |
| `Register-AltServerAtLogon.ps1` | **AltServer** at logon ([BUILD-WITHOUT-MAC.md](../ios/BUILD-WITHOUT-MAC.md) §3). Wi‑Fi refresh often fails on Win11 — **USB + AltStore Refresh All** weekly is the reliable path |
| `Register-SideloadlyAutoRefresh.ps1` | **Fallback only** — Sideloadly daemon if AltStore fails |
| `RCLONE-PHONE-MOUNT.md` | Optional rclone mount notes (sluggish vs Skybox) |
| `archive/` | Legacy `net use` / port-80 proxy, `Sync-FromPhoneLAN.ps1`, optional HTTP **`Copy-ToLoopSegmentsPhoneLAN.ps1`** (no **L:** mount) |

### Legacy WebDAV mapped to `http://localhost/`

`-ViaPort80Proxy` (archive script) added a **local** `:80` redirect to the phone. Prefer **`http://<phone-ip>:8765/`** + rclone today. Cleanup:

1. Run **elevated**: `.\Mount-LoopSegmentsRclone.ps1 -RemovePort80Proxy`
2. **`net use L: /delete /y`** if Explorer still shows an old mapping.

See [../ios/README.md](../ios/README.md) and [../WORKFLOW.md](../WORKFLOW.md).
