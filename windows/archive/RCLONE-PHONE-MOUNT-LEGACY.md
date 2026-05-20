# rclone drive letter mount of the iPhone LAN export (optional PC workflow)

The phone’s LAN server (**`http://<ip>:8765/`**) implements **HTTP + WebDAV** (PROPFIND, listings, Basic auth **`admin` / `iosadmin`**) so clients like **Quest Skybox** can add it as a **WebDAV** library directly — **no PC rclone step required**.

On **Windows**, some users mapped the same URL with **`rclone mount`** (WinFsp + `type = webdav` in `rclone.conf`) to get a **drive letter** for Explorer / DLNA folder indexing. That path can feel **sluggish**, show **VFS/listing quirks** (e.g. *Entry doesn't belong in directory*), or hang compared to using **Skybox → phone WebDAV** or **plain HTTP** downloads.

This folder keeps the **full legacy mount script** and notes for that optional PC setup.

## Optional: what the rclone mount did

1. **WinFsp** on Windows (for `rclone mount` to a drive letter).
2. **`Mount-LoopSegmentsRclone-WebDAVMount-Legacy.ps1`**: wrote a **`[loopsegments]`** block into `rclone.conf` (`type = webdav`, Basic auth), ran **`rclone ls`** and **`rclone mount`** from `loop-segments-windows.json`.
3. **DLNA / Explorer** could index that drive (e.g. `L:\pcld_ios_media\loop\`).

## When to skip rclone on the PC

- **Quest Skybox** with **WebDAV** to the phone works for export playback for many users — prefer that if the goal is watching from the headset.
- **PC DLNA** without a mapped drive: **browser**, **`Invoke-WebRequest`**, or **`Sync-FromPhoneLAN.ps1`** into a local folder.

## Active scripts

| Location | Role |
|---------|------|
| **`../Mount-LoopSegmentsRclone.ps1`** | **`-TestOnly`** LAN probe (current repo default; may differ if you restore full mount in `../`) |
| **`Mount-LoopSegmentsRclone-WebDAVMount-Legacy.ps1`** | Historical **full** `rclone mount` flow (same auth as app) |
| **`Map-LoopSegmentsWebDAV.ps1`** | Legacy `net use` / port 80 proxy experiments |

## See also

- **[../README.md](../README.md)** — portable Windows config  
- **[../../ios/README.md](../../ios/README.md)** — Skybox WebDAV (`admin` / `iosadmin`), Pigasus HTTP URLs
