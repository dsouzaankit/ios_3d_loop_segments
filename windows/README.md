# Loop Segments — Windows (portable)

Scripts work on **any Windows PC** after you copy or clone this repo. Machine-specific paths live in **`loop-segments-windows.json`** (gitignored), not in the scripts.

## First time on a PC

```powershell
cd P:\all_scripts\ios_3d_loop_segments\windows   # or your clone path

Copy-Item loop-segments-windows.example.json loop-segments-windows.json
.\Set-LoopSegmentsWindows.ps1 -PhoneHost 10.0.100.10
# Or interactive: .\Set-LoopSegmentsWindows.ps1

.\Set-LoopSegmentsWindows.ps1 -Show
.\Mount-LoopSegmentsRclone.ps1 -TestOnly   # HTTP check to phone :8765 (not a drive mount)
```

**Phone → Windows drive letter via rclone** was removed when the app’s LAN server became **HTTP-only**. Historical script and notes: **[archive/RCLONE-PHONE-MOUNT-LEGACY.md](archive/RCLONE-PHONE-MOUNT-LEGACY.md)**.

## What goes in `loop-segments-windows.json`

| Field | Purpose |
|-------|---------|
| `phoneLanHost` | iPhone IP (changes per Wi‑Fi) |
| `lanPort` | Usually `8765` |
| `mountDriveLetter` | Drive letter for **legacy** `-Remove` (stopping old `rclone mount`) or Koofr; default `L` |
| `rcloneRemoteName` | Reserved name in `rclone.conf` (Koofr / other remotes); **not** used to mount the phone in current builds |
| `rcloneConfigPath` | **Empty** = auto (`rclone config file`, usually `%APPDATA%\rclone\rclone.conf`) |
| `rcloneExe` | **Empty** = `rclone` on PATH |
| `winfspDllPath` | **Empty** = search Program Files; set full path if detection fails |
| `skipWinFspCheck` | `true` if Koofr mount already proves WinFsp works |
| `dlnaFolder` | Optional note for Skybox / junction target |
| `notes` | Free text (e.g. "Koofr remote = koofr") |

## Koofr + Loop Segments on one PC

- **Koofr** (or other cloud) may still use **rclone** + WinFsp on a drive letter — that is **separate** from the phone.
- The **phone** is reached over **`http://<ip>:8765/`** (browser, `Invoke-WebRequest`, or **[archive/Sync-FromPhoneLAN.ps1](archive/Sync-FromPhoneLAN.ps1)**) — not `rclone mount` to the phone.

## Moving to another PC

1. Clone or copy the repo (do **not** commit `loop-segments-windows.json`).
2. Copy your json from the old PC, or run `Set-LoopSegmentsWindows.ps1` again.
3. Update **`phoneLanHost`** for the new LAN.
4. Leave **`rcloneConfigPath`** empty unless the new PC stores config elsewhere.

Legacy one-line IP file `loop-segments-lan-host.txt` is still updated for compatibility (gitignored).

## Scripts

| Script | Role |
|--------|------|
| `LoopSegments-Windows.ps1` | Shared config (dot-sourced; do not run alone) |
| `Set-LoopSegmentsWindows.ps1` | Edit per-PC json |
| `Set-LoopSegmentsLANHost.ps1` | Quick IP-only update |
| `Mount-LoopSegmentsRclone.ps1` | **`-TestOnly`** = HTTP probe to phone; **`-Remove`** = stop legacy `rclone` mount on `mountDriveLetter`; **`-RemovePort80Proxy`** = undo legacy `netsh` port 80→8765 proxy (admin) |
| `archive/` | **[RCLONE-PHONE-MOUNT-LEGACY.md](archive/RCLONE-PHONE-MOUNT-LEGACY.md)**, legacy WebDAV mount script, `Map-LoopSegmentsWebDAV.ps1`, `Sync-FromPhoneLAN.ps1` |

### Legacy WebDAV mapped to `http://localhost/`

`-ViaPort80Proxy` added a **local** `:80` (or `:8080`) redirect to the phone. Windows then attempted drive mapping via **localhost**. After cleanup:

1. Run **elevated**: `.\Mount-LoopSegmentsRclone.ps1 -RemovePort80Proxy`
2. If rules still listed, **`git pull`** — deletes now match rows from `netsh interface portproxy show v4tov4` including listen address **`*`** (older script only tried `0.0.0.0`, which does not remove `*`).
3. Run **`net use`** and **`net use L: /delete /y`** (or whatever letter Explorer shows).

See [../ios/README.md](../ios/README.md) and [../WORKFLOW.md](../WORKFLOW.md).
