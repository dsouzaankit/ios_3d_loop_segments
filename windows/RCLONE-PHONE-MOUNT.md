# rclone drive letter mount of the iPhone LAN export (optional PC workflow)

The phone’s LAN server (**`http://<ip>:8765/`**) implements **HTTP + WebDAV** (PROPFIND, PUT/MKCOL for scripts under `pcld_ios_media/`, Basic auth **`admin` / `iosadmin`**) so clients like **Quest Skybox** can add it as a **WebDAV** library directly — **no PC rclone step required**.

On **Windows**, you can map the same URL with **`rclone mount`** (WinFsp + `type = webdav` in `rclone.conf`) to get a **drive letter** for Explorer / DLNA folder indexing. That path can feel **sluggish**, show **VFS/listing quirks**, or hang compared to **Skybox → phone WebDAV** or **plain HTTP** downloads.

## Setup (portable across PCs)

1. **WinFsp** — required for `rclone mount` on Windows ([winfsp.dev](https://winfsp.dev/)).
2. **rclone** on PATH (or set `rcloneExe` in json).
3. Per-PC config (once per machine):

```powershell
cd windows
Copy-Item loop-segments-windows.example.json loop-segments-windows.json
.\Set-LoopSegmentsWindows.ps1 -PhoneHost 10.0.100.10
.\Mount-LoopSegmentsRclone.ps1 -TestOnly
.\Mount-LoopSegmentsRclone.ps1
```

The mount script writes/updates **`[loopsegments]`** in your **`rclone.conf`** (same file as Koofr if you use one). Settings: **`loop-segments-windows.json`** — see **[README.md](README.md)**.

Mounted paths (read-only):

- **`L:\pcld_ios_media\loop\op_00.mp4`** / **`op_01.mp4`**
- **`L:\pcld_ios_media\_working.mp4`** (sparse in-progress)
- **`L:\pcld_ios_media\scripts\`** (PC-created via WebDAV PUT when enabled)

Use a different **`mountDriveLetter`** if **`L:`** is already Koofr.

## When to skip rclone on the PC

- **Quest Skybox** with **WebDAV** to the phone — prefer if the goal is headset playback.
- **PC DLNA** without a mapped drive: browser, **`Invoke-WebRequest`**, or **`archive/Sync-FromPhoneLAN.ps1`** into a local folder.

## Scripts

| Script | Role |
|--------|------|
| **`Mount-LoopSegmentsRclone.ps1`** | **Active** — test, mount, `-Remove`, `-RemovePort80Proxy` |
| **`Set-LoopSegmentsWindows.ps1`** | Per-PC json (IP, drive letter, rclone paths) |
| **`archive/Map-LoopSegmentsWebDAV.ps1`** | Legacy `net use` / port 80 proxy (not recommended) |

## See also

- **[README.md](README.md)** — portable Windows config  
- **[../ios/README.md](../ios/README.md)** — Skybox WebDAV, LAN writable scripts
