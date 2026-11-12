# rclone drive letter mount of the iPhone LAN export (optional PC workflow)

The phone’s LAN server (**`http://<ip>:8765/`**) implements **HTTP + WebDAV** (PROPFIND, PUT/MKCOL/DELETE/**MOVE** under writable `pcld_ios_media/` paths, Basic auth **`admin`** / the app's password (Export screen)) so clients like **Quest Skybox** can add it as a **WebDAV** library directly — **no PC rclone step required**. Media files live in **Application Support** on the phone (hidden from the Files app); **rclone still maps `L:`** via WebDAV — not via USB. If `pcld_ios_media/` exists on the phone, the mount **starts there** (`L:\loop`, `L:\archive`); otherwise Explorer shows `L:\pcld_ios_media\`.

On **Windows**, you can map the same URL with **`rclone mount`** (WinFsp + `type = webdav` in `rclone.conf`) to get a **drive letter** for Explorer. After the letter attaches, the mount script notifies Explorer so **This PC** shows it without F5; it notifies again when the letter is unmapped (Ctrl+C / console X / LAN-watch / `-Remove`). That path can feel **sluggish**, show **VFS/listing quirks**, or hang compared to **Skybox → phone WebDAV** or **plain HTTP** downloads.

For **Quest Skybox**, companion prefers **`rclone serve dlna`** (`Serve-LoopSegmentsRcloneDlna.ps1` / **`Serve-PhoneDlna.cmd`**) over mapping `L:` into Skybox AirScreen Add-folders. DLNA advertises the phone WebDAV tree on the LAN (`rcloneDlnaAddr` / `rcloneDlnaName` in `loop-segments-windows.json`, default `:7879` / `Loop Segments`). Discover it under Skybox **Network**.

**If Explorer freezes after the phone LAN goes down:** the mount script **polls** `status.json` and **kills rclone + exits** after ~60s unreachable (override with `-LanDownSeconds` / `-LanPollSeconds`, or `-NoLanWatch`). rclone writes **`%TEMP%\loopsegments-rclone-mount.log`** (local disk — it cannot create the log on pCloud `P:`). On quit/abort/next start that file is copied to **`windows\rclone\loopsegments-rclone-mount.log`**. Manual escape: double-click **`Unstick-PhoneL.cmd`** (or `.\Mount-LoopSegmentsRclone.ps1 -Unstick`) to kill the mount and restart Explorer. If Explorer is already wedged, use **Task Manager → File → Run new task** and paste the full path to `Unstick-PhoneL.cmd`.

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

**`L:` is read/write by default.** If the mount starts at `pcld_ios_media/`, copy a bootstrap **`.ps1`** to **`L:\`** (not `L:\pcld_ios_media\`). If the mount is WebDAV root, copy to **`L:\pcld_ios_media\`**. Run it on the PC so it can sync **`scripts\`** and other allowed subfolders via **`L:`**. The phone rejects writes to **`loop\`**, **`_working.mp4`**, and segment files. **≤ 2 MB** per PUT. **MOVE** (Explorer rename) is supported on writable paths (local on phone — no re-download). Same-folder paste still downloads unless/until server **COPY** exists. **`Mount-LoopSegmentsRclone.ps1 -ReadOnly`** for a read-only Explorer letter. For Quest DLNA without AirScreen of `L:`, use **`Serve-LoopSegmentsRcloneDlna.ps1`**. Without a mount, see **`../archive/Copy-ToLoopSegmentsPhoneLAN.ps1`** (HTTP PUT).

Mounted paths (start directory `pcld_ios_media/`):

- **`L:\*.ps1`** — bootstrap sync scripts (writable)
- **`L:\scripts\`** — nested scripts/tools (writable)
- **`L:\archive\`** — retained videos (writable); **`archive\*.ps1`** robocopy helpers survive **Clear media** (videos do not)
- **`L:\loop\`** — read-only on phone
- **`L:\_working.mp4`** — read-only on phone

If Explorer instead shows **`L:\pcld_ios_media\`**, the mount is WebDAV root (folder missing at mount time). Use the same names under that folder. A nested empty **`L:\pcld_ios_media`** while `L:\loop` already exists is a leftover — delete it; it is not a second media tree.

Preferred **`mountDriveLetter`** in `loop-segments-windows.json` is tried first (default `L`). If that letter is already taken (Koofr, etc.), the mount script picks a **random free D–Z** and writes it back to json.

## Getting phone media into Skybox on Quest

DLNA is the only route that both plays in Skybox VR and needs no setup on the headset, but the companion no longer starts it by default: `rclone serve dlna` has no password option and lists the phone's folders to anyone who can reach the PC. Start it with `Run-PCloudWebCompanion.ps1 -EnableRcloneDlna` (or `Serve-PhoneDlna.cmd`), or use WebDAV direct below.

| Route | Plays in Skybox VR | Setup |
|---|---|---|
| **`rclone serve dlna`** (companion `-EnableRcloneDlna`) | Yes | None on the headset: Skybox finds **Loop Segments** under **Network** by itself (the companion removes that entry from SKYBOX at quit; it is found again the next time DLNA is served) |
| **WebDAV direct to the phone** (`http://<phone>:8765/`, `admin` / the app's password (Export screen)) | Yes, one hop fewer (no PC in the middle) | None: press **Push** on the companion's Quest control page; it adds **Loop Segments** (signed in) over adb, and the companion removes it at close (`questSkyboxWebDav`, [../quest/README.md](../quest/README.md#skybox-phone-as-a-webdav-server-from-the-control-page)). By hand: Skybox **Network** → Add → Add WebDAV server |
| **AirScreen folder of the `L:` mount** | **No**: it lists in Add-folders but never streams | Automatable through the PC app, but pointless. The companion no longer maps it |

**Do not map `L:` into Skybox AirScreen** for phone media. Quest Browser (`/xr`) is a separate path and cannot play WMV.

**Explorer / scripts:** the optional **`rclone mount`** to `L:` is for PC use only (still started by the companion unless `-SkipRcloneMount`).

### If rclone DLNA playback stutters

Phone WebDAV → PC `rclone serve dlna` → Quest is an extra hop. When that stutters or buffers:

1. Prefer **[3d_playlist_local](https://github.com/dsouzaankit/3d_playlist_local)** — transcode/output to the **`3d_fullsbs_trans`** AirScreen share (mapped via `Skybox_vr_pc` / `skybox_vr_pc.config.json`) and play that share on Quest.
2. Or add the phone as **WebDAV** directly in Skybox Network (`http://<phone>:8765/`, `admin` / the app's password (Export screen)) — no PC rclone.
3. Check LAN Mbps (`..\lan\Measure-LoopSegmentsLanThroughput.ps1` / companion probe) and keep segment bitrate under the recommended sidecar; avoid Virtual Desktop streaming during the probe or heavy play.

`p_cld_media` AirScreen remains for local pCloud folder media; it is not a substitute for phone `L:` / DLNA.

### AirScreen shares are not DLNA

SKYBOX AirScreen shares (`p_cld_media`, `3d_fullsbs_trans`, ...) use SKYBOX's own protocol, not DLNA. TVs, VLC, Kodi and other DLNA clients do not see them; only the Skybox app on the Quest does. Checked on this PC: an SSDP search for DLNA media servers gets no answer from SKYBOX.

They are still reachable from the network: SKYBOX's backend (`airscreen-backend.exe`) listens on all interfaces (TCP 8018 control API, TCP 41338, UDP 1900; `SKYBOX.exe` on TCP 41001), its installer's firewall rule allows inbound on Private and Public networks, and the API answers without credentials (`GET /ping`, `POST /node_info` from the PC's LAN address returned 200). `/node` adds or removes a shared folder (what `Skybox_vr_pc` uses); it was not tried from the LAN, but it is likely just as open. The firewall is left as installed on purpose. To lock it down later, allow inbound to `SKYBOX.exe` and `airscreen-backend.exe` only from `127.0.0.1` and the Quest's IP (fixed with a DHCP reservation), and narrow the existing allow rules, since any matching allow rule wins.

## Scripts

| Script | Role |
|--------|------|
| **`Mount-LoopSegmentsRclone.ps1`** | Optional Explorer letter — test, mount, `-Remove`, `-Unstick`, `-Quick`, LAN watch |
| **`Mount-PhoneL.cmd`** | Day-to-day launcher → mount script |
| **`Serve-LoopSegmentsRcloneDlna.ps1`** | **Quest path** — `rclone serve dlna` over phone WebDAV (`-Remove`, `-TestOnly`, `-Quick`, `-Hidden`, LAN watch). Companion uses `-Hidden` (no console). |
| **`Serve-PhoneDlna.cmd`** | Day-to-day launcher → DLNA serve script |
| **`Unstick-PhoneL.cmd`** | Kill dead phone mount + restart Explorer |
| **`%TEMP%\loopsegments-rclone-mount.log`** | live rclone mount log (Temp; copied to `windows\rclone\` on quit) |
| **`%TEMP%\loopsegments-rclone-dlna.log`** | live rclone DLNA serve log |
| **`../setup/Set-LoopSegmentsWindows.ps1`** | Per-PC json (IP, drive letter, rclone paths) |
| **`../archive/Map-LoopSegmentsWebDAV.ps1`** | Legacy `net use` / port 80 proxy (not recommended) |

## See also

- **[../README.md](../README.md)** — portable Windows config  
- **[../../ios/README.md](../../ios/README.md)** — Skybox WebDAV, LAN writable scripts
