# Legacy: rclone WebDAV mount of the iPhone LAN export server

Current Loop Segments builds serve **`Documents/Exports/`** on the LAN as **plain HTTP** (GET/HEAD/OPTIONS, Range, HTML index, `status.json`). **WebDAV (PROPFIND / LOCK) is not implemented** on the phone, so **`rclone` `type = webdav`** against `http://<phone>:8765/` **no longer works** for listing or `rclone mount`.

This document describes the **old** Windows workflow for readers on archived IPAs or for comparison.

## What used to work

1. **WinFsp** on Windows (required for `rclone mount` to a drive letter).
2. **`Mount-LoopSegmentsRclone-WebDAVMount-Legacy.ps1`** (copy in this folder): wrote a **`[loopsegments]`** block into `rclone.conf` (`type = webdav`, Basic auth), ran **`rclone ls`** and **`rclone mount`** to a drive letter from `loop-segments-windows.json`.
3. **DLNA / Explorer** could index that drive (e.g. `L:\pcld_ios_media\loop\`).

## Why it was retired

- Mapped-drive clients depend on **WebDAV** semantics; maintaining that in-app was simplified to **HTTP-only** file serving.
- **`rclone` `http`** against the LAN URL is **not** a drop-in replacement (directory listing / nested paths do not match a stable “remote” tree; users reported errors such as *Entry doesn't belong in directory* and hangs).

## What to use instead (current)

| Goal | Approach |
|------|----------|
| Quick check | `..\Mount-LoopSegmentsRclone.ps1 -TestOnly` |
| Copy segments to PC | Browser at `http://<ip>:8765/`, **`Invoke-WebRequest`**, or **`Sync-FromPhoneLAN.ps1`** in this `archive/` folder |
| Unattended pCloud → PC | **`Run-SegmentCopy.ps1`** (sibling **`3d_loop_segments`** repo) |
| Other cloud drives (Koofr, etc.) | Your existing **rclone** remotes — unrelated to the phone LAN server |

## Files

| File | Role |
|------|------|
| **`Mount-LoopSegmentsRclone-WebDAVMount-Legacy.ps1`** | Full legacy mount script (reference / old builds) |
| **`Map-LoopSegmentsWebDAV.ps1`** | Legacy `net use` / port 80 proxy experiments |
