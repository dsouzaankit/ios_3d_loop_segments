# Loop Segments — Windows (portable)

Scripts work on **any Windows PC** after you copy or clone this repo. Machine-specific paths live in **`loop-segments-windows.json`** (gitignored), not in the scripts. All scripts resolve paths from **`$PSScriptRoot`** in this folder.

## First time on a PC

```powershell
cd P:\all_scripts\ios_3d_loop_segments\windows   # or your clone path

Copy-Item loop-segments-windows.example.json loop-segments-windows.json
.\Set-LoopSegmentsWindows.ps1 -PhoneHost 10.0.100.10
# Or interactive: .\Set-LoopSegmentsWindows.ps1

.\Set-LoopSegmentsWindows.ps1 -Show
.\Mount-LoopSegmentsRclone.ps1 -TestOnly
.\Mount-LoopSegmentsRclone.ps1          # rclone mount -> drive letter (WinFsp)
```

Phone LAN is **HTTP + WebDAV** on `:8765` (Basic auth **`admin` / `iosadmin`** — same as Skybox). **rclone mount** is optional; it can feel sluggish vs browser/Skybox direct WebDAV — see **[RCLONE-PHONE-MOUNT.md](RCLONE-PHONE-MOUNT.md)**.

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

1. Clone or copy the repo (do **not** commit `loop-segments-windows.json`).
2. Copy your json from the old PC, or run `Set-LoopSegmentsWindows.ps1` again.
3. Update **`phoneLanHost`** for the new LAN.
4. Leave **`rcloneConfigPath`** empty unless the new PC stores config elsewhere (do not copy another user’s `C:\Users\…\rclone.conf` path).

Legacy one-line IP file `loop-segments-lan-host.txt` is still updated for compatibility (gitignored).

## Scripts

| Script | Role |
|--------|------|
| `LoopSegments-Windows.ps1` | Shared config (dot-sourced; do not run alone) |
| `Set-LoopSegmentsWindows.ps1` | Edit per-PC json |
| `Set-LoopSegmentsLANHost.ps1` | Quick IP-only update |
| `Get-LoopSegmentsUnifiedLANListing.ps1` | **Pool media listings** from all `phoneLanHosts` → JSON or HTML |
| `Serve-LoopSegmentsUnifiedLAN.ps1` | PC HTTP index on `:8766` (merged view; phones still serve files on `:8765`) |
| `Mount-PhoneL.cmd` | **Day-to-day** launcher → `Mount-LoopSegmentsRclone.ps1` |
| `Mount-LoopSegmentsRclone.ps1` | **`-TestOnly`** = HTTP + PROPFIND + `rclone ls`; default = **read/write** **L:** (copy bootstrap `.ps1` and folders under `pcld_ios_media\`; ≤ 2 MB per file on phone); **`-ReadOnly`** = DLNA-only; **`-Remove`** / **`-RemovePort80Proxy`** |
| `Register-AltServerAtLogon.ps1` | **AltServer** at logon ([BUILD-WITHOUT-MAC.md](../ios/BUILD-WITHOUT-MAC.md) §3). Wi‑Fi refresh often fails on Win11 — **USB + AltStore Refresh All** weekly is the reliable path |
| `Register-SideloadlyAutoRefresh.ps1` | **Fallback only** — Sideloadly daemon if AltStore fails |
| `RCLONE-PHONE-MOUNT.md` | Optional rclone mount notes (sluggish vs Skybox) |
| `archive/` | Legacy `net use` / port-80 proxy, `Sync-FromPhoneLAN.ps1`, optional HTTP **`Copy-ToLoopSegmentsPhoneLAN.ps1`** (no **L:** mount) |

### Legacy WebDAV mapped to `http://localhost/`

`-ViaPort80Proxy` (archive script) added a **local** `:80` redirect to the phone. Prefer **`http://<phone-ip>:8765/`** + rclone today. Cleanup:

1. Run **elevated**: `.\Mount-LoopSegmentsRclone.ps1 -RemovePort80Proxy`
2. **`net use L: /delete /y`** if Explorer still shows an old mapping.

See [../ios/README.md](../ios/README.md) and [../WORKFLOW.md](../WORKFLOW.md).
