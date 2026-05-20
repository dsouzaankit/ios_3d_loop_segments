# Loop Segments — Windows (portable)

Scripts work on **any Windows PC** after you copy or clone this repo. Machine-specific paths live in **`loop-segments-windows.json`** (gitignored), not in the scripts.

## First time on a PC

```powershell
cd P:\all_scripts\ios_3d_loop_segments\windows   # or your clone path

Copy-Item loop-segments-windows.example.json loop-segments-windows.json
.\Set-LoopSegmentsWindows.ps1 -PhoneHost 10.0.100.10
# Or interactive: .\Set-LoopSegmentsWindows.ps1

.\Set-LoopSegmentsWindows.ps1 -Show    # rclone.conf, WinFsp, drive letter
.\Mount-LoopSegmentsRclone.ps1 -TestOnly
.\Mount-LoopSegmentsRclone.ps1
```

## What goes in `loop-segments-windows.json`

| Field | Purpose |
|-------|---------|
| `phoneLanHost` | iPhone IP (changes per Wi‑Fi) |
| `lanPort` | Usually `8765` |
| `mountDriveLetter` | e.g. `L` — use **`M`** if Koofr already uses `L:` |
| `rcloneRemoteName` | Default `loopsegments` (separate from Koofr remote name) |
| `rcloneConfigPath` | **Empty** = auto (`rclone config file`, usually `%APPDATA%\rclone\rclone.conf`) |
| `rcloneExe` | **Empty** = `rclone` on PATH |
| `winfspDllPath` | **Empty** = search Program Files; set full path if detection fails |
| `skipWinFspCheck` | `true` if Koofr mount already proves WinFsp works |
| `dlnaFolder` | Optional note for Skybox / junction target |
| `notes` | Free text (e.g. "Koofr remote = koofr") |

## Koofr + phone mount on one PC

- Both use the **same** `rclone.conf`; this repo only adds a **`[loopsegments]`** section.
- Use **different drive letters** (Koofr `K:`, phone `L:`) via `mountDriveLetter`.
- Run `.\Set-LoopSegmentsWindows.ps1 -Show` to confirm which `rclone.conf` is used.

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
| `Mount-LoopSegmentsRclone.ps1` | Mount phone Exports |
| | `-Remove` = stop rclone mount; **`-RemovePort80Proxy`** = undo legacy `netsh` port 80→8765 proxy (admin) |
| `archive/` | Old sync / `net use` WebDAV scripts (`Map-LoopSegmentsWebDAV.ps1 -ViaPort80Proxy`) |

### Legacy WebDAV mapped to `http://localhost/`

`-ViaPort80Proxy` added a **local** `:80` (or `:8080`) redirect to the phone. Windows then maps the drive via **localhost**. After cleanup:

1. Run **elevated**: `.\Mount-LoopSegmentsRclone.ps1 -RemovePort80Proxy`
2. If rules still listed, **`git pull`** — deletes now match rows from `netsh interface portproxy show v4tov4` including listen address **`*`** (older script only tried `0.0.0.0`, which does not remove `*`).
3. Run **`net use`** and **`net use L: /delete /y`** (or whatever letter Explorer shows).

See [../ios/README.md](../ios/README.md) and [../WORKFLOW.md](../WORKFLOW.md).
