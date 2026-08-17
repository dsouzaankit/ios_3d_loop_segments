# rclone drive letter mount of the iPhone LAN export (optional PC workflow)

The phone’s LAN server (**`http://<ip>:8765/`**) implements **HTTP + WebDAV** (PROPFIND, PUT/MKCOL/DELETE/**MOVE** under writable `pcld_ios_media/` paths, Basic auth **`admin` / `iosadmin`**) so clients like **Quest Skybox** can add it as a **WebDAV** library directly — **no PC rclone step required**. Media files live in **Application Support** on the phone (hidden from the Files app); **rclone still maps `L:`** via WebDAV — not via USB. If `pcld_ios_media/` exists on the phone, the mount **starts there** (`L:\loop`, `L:\archive`); otherwise Explorer shows `L:\pcld_ios_media\`.

On **Windows**, you can map the same URL with **`rclone mount`** (WinFsp + `type = webdav` in `rclone.conf`) to get a **drive letter** for Explorer / DLNA folder indexing. That path can feel **sluggish**, show **VFS/listing quirks**, or hang compared to **Skybox → phone WebDAV** or **plain HTTP** downloads.

**If Explorer freezes after the phone LAN goes down:** the mount script **polls** `status.json` and **kills rclone + exits** after ~90s unreachable (override with `-LanDownSeconds` / `-LanPollSeconds`, or `-NoLanWatch`). Mount stderr/info: **`loopsegments-rclone-mount.log`** in this folder. Manual escape: double-click **`Unstick-PhoneL.cmd`** (or `.\Mount-LoopSegmentsRclone.ps1 -Unstick`) to kill the mount and restart Explorer. If Explorer is already wedged, use **Task Manager → File → Run new task** and paste the full path to `Unstick-PhoneL.cmd`.

## Setup (portable across PCs)

1. **WinFsp** — required for `rclone mount` on Windows ([winfsp.dev](https://winfsp.dev/)).
2. **rclone** on PATH (or set `rcloneExe` in json).
3. Per-PC config (once per machine):

```powershell
cd windows
Copy-Item loop-segments-windows.example.json loop-segments-windows.json
.\setup\Set-LoopSegmentsWindows.ps1 -PhoneHost 10.0.100.10
cd rclone
.\Mount-LoopSegmentsRclone.ps1 -TestOnly
.\Mount-LoopSegmentsRclone.ps1
```

Or day-to-day: double-click **`Mount-PhoneL.cmd`** in this folder.

The mount script writes/updates **`[loopsegments]`** in your **`rclone.conf`** (same file as Koofr if you use one). Settings: **`../loop-segments-windows.json`** — see **[../README.md](../README.md)**.

**`L:` is read/write by default.** If the mount starts at `pcld_ios_media/`, copy a bootstrap **`.ps1`** to **`L:\`** (not `L:\pcld_ios_media\`). If the mount is WebDAV root, copy to **`L:\pcld_ios_media\`**. Run it on the PC so it can sync **`scripts\`** and other allowed subfolders via **`L:`**. The phone rejects writes to **`loop\`**, **`_working.mp4`**, and segment files. **≤ 2 MB** per PUT. **MOVE** (Explorer rename) is supported on writable paths (local on phone — no re-download). Same-folder paste still downloads unless/until server **COPY** exists. **`Mount-LoopSegmentsRclone.ps1 -ReadOnly`** = DLNA-only. Without a mount, see **`../archive/Copy-ToLoopSegmentsPhoneLAN.ps1`** (HTTP PUT).

Mounted paths (start directory `pcld_ios_media/`):

- **`L:\*.ps1`** — bootstrap sync scripts (writable)
- **`L:\scripts\`** — nested scripts/tools (writable)
- **`L:\archive\`** — retained videos (writable); **`archive\*.ps1`** robocopy helpers survive **Clear media** (videos do not)
- **`L:\loop\`** — read-only on phone
- **`L:\_working.mp4`** — read-only on phone

If Explorer instead shows **`L:\pcld_ios_media\`**, the mount is WebDAV root (folder missing at mount time). Use the same names under that folder. A nested empty **`L:\pcld_ios_media`** while `L:\loop` already exists is a leftover — delete it; it is not a second media tree.

Use a different **`mountDriveLetter`** if **`L:`** is already Koofr.

## When to skip rclone on the PC

- **Quest Skybox** with **WebDAV** to the phone — prefer if the goal is headset playback.
- **PC DLNA** without a mapped drive: browser, **`Invoke-WebRequest`**, or **`../archive/Sync-FromPhoneLAN.ps1`** into a local folder.

## Scripts

| Script | Role |
|--------|------|
| **`Mount-LoopSegmentsRclone.ps1`** | **Active** — test, mount, `-Remove`, `-Unstick`, `-Quick`, LAN watch, `-RemovePort80Proxy` |
| **`Mount-PhoneL.cmd`** | Day-to-day launcher → mount script |
| **`Unstick-PhoneL.cmd`** | Kill dead phone mount + restart Explorer |
| **`loopsegments-rclone-mount.log`** | rclone mount log written next to these scripts (gitignored) |
| **`../setup/Set-LoopSegmentsWindows.ps1`** | Per-PC json (IP, drive letter, rclone paths) |
| **`../archive/Map-LoopSegmentsWebDAV.ps1`** | Legacy `net use` / port 80 proxy (not recommended) |

## See also

- **[../README.md](../README.md)** — portable Windows config  
- **[../../ios/README.md](../../ios/README.md)** — Skybox WebDAV, LAN writable scripts
