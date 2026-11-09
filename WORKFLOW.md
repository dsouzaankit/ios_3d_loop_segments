# Workflow: iPhone cellular → PC DLNA (WLAN)

> **Feasibility:** USB cannot reach the segments at all: they live in the app's private storage, which **Apple Devices** and the **Files** app cannot see. Copying runs over Wi‑Fi. See **[FEASIBILITY.md](FEASIBILITY.md)** — production automation is either **PC `Run-SegmentCopy.ps1`** (pCloud → PC) or a **future Wi‑Fi pull** from the phone; USB copy is at best **once per export session**.

Three separate networks. **No Personal Hotspot** required for the iPhone path below.

```text
┌─────────────────────────────────────────────────────────────────┐
│  iPhone (cellular LTE/5G for pCloud; Wi‑Fi for LAN serve)        │
│    Loop Segments → pCloud WebDAV → pcld_ios_media/loop/op_00.mp4  │
└────────────────────────────┬────────────────────────────────────┘
                             │ Wi‑Fi (HTTP :8765 — copy files; see §3)
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  Windows PC — op_00/01 in DLNA folder → media server → TV       │
└─────────────────────────────────────────────────────────────────┘
```

| Step | Where | Network |
|------|--------|---------|
| 1. Browse pCloud, run export | iPhone | **Cellular** (or Wi‑Fi if you prefer) |
| 2. Copy segment MP4s | iPhone → PC | **Wi‑Fi** (USB cannot reach them) |
| 3. LAN playback | PC + TV | **WLAN** (Ethernet to router also fine) |

The PC never pulls from pCloud and never runs ffmpeg for this workflow. The phone never serves DLNA.

---

## 1. Build and install the iPhone app (one-time)

You need an **IPA** built in the cloud (no local Mac). See [ios/BUILD-WITHOUT-MAC.md](ios/BUILD-WITHOUT-MAC.md).

Install via **TestFlight** or sideload (**SideStore nightly** preferred when AltStore flakes; else **AltStore**; Sideloadly last) with a free or paid Apple ID — see [ios/BUILD-WITHOUT-MAC.md](ios/BUILD-WITHOUT-MAC.md).

---

## 2. On the iPhone (cellular)

1. **Settings → Cellular → Loop Segments** → allow cellular data.
2. Optional: turn **Wi‑Fi off** to force cellular-only pCloud access (no hotspot).
3. Open **Loop Segments** → sign in to pCloud (US/EU).
4. Browse to a video → set seek (presets 0/10/15/30/45 min) → **Start export**.
5. Keep the app in the foreground. Over Wi‑Fi (step 6), the LAN page **`http://<ip>:8765/`** shows `pcld_ios_media/loop/op_00.mp4` updating each ~60s of **media** time (first segment can take several minutes on large moov-at-end HEVC while the minute **dense-downloads**).
6. On the phone: enable **LAN server on Wi‑Fi** so the PC can reach **`http://<ip>:8765/`**. Photos library export is **off** by default — see [ios/README.md](ios/README.md).

Large files on cellular: first segment waits for index + dense window (`Downloading window … (dense fill)` → `Window on disk` in `export_latest.txt`). Later minutes reuse the same sparse temp shell; export does not keep up with live TV wall clock on slow LTE — OK if the DLNA player **loops** the PC pair.

---

## 3. Copy segments to the PC

### Automated (Wi‑Fi)

1. iPhone and PC on the **same Wi‑Fi**; **LAN server on Wi‑Fi** on in the app.
2. Note the phone IP from the export log (`LAN export: http://192.168.x.x:8765/`).
3. On the PC:

```powershell
cd "P:\all_scripts\iOS apps\ios_3d_loop_segments\windows"
Copy-Item loop-segments-windows.example.json loop-segments-windows.json   # first time on this PC
.\setup\Set-LoopSegmentsWindows.ps1 -PhoneHost 192.168.x.x
.\rclone\Mount-LoopSegmentsRclone.ps1 -TestOnly   # optional HTTP check
```

Open **`http://192.168.x.x:8765/`** in a browser and save files, use **`Invoke-WebRequest`**, or **[windows/archive/Sync-FromPhoneLAN.ps1](windows/archive/Sync-FromPhoneLAN.ps1)**. Per-PC json: [windows/README.md](windows/README.md).

Copy segment MP4s into your DLNA folder (or use **`Run-SegmentCopy.ps1`** from the sibling **`3d_loop_segments`** repo for pCloud → PC). Optional **rclone mount**: [windows/rclone/RCLONE-PHONE-MOUNT.md](windows/rclone/RCLONE-PHONE-MOUNT.md).

### Manual (USB / Apple Devices)

Not available. Segments live in the app's private storage (`Library/Application Support/pcld_ios_media/`), which Apple Devices cannot see. Use the Wi‑Fi copy above.

---

## 4. DLNA playback on WLAN

1. PC connected to the same **WLAN** as the TV/player (not via iPhone hotspot).
2. Windows **media streaming** (or your existing DLNA server) publishes `F:\f1_media\3d_fullsbs_trans`.
3. Open the library on the TV; play the rotating `op_*.mp4` entries.

---

## Where the files are

Media and logs live in the app's private storage, **`Library/Application Support/pcld_ios_media/`**. The **Files** app, **Apple Devices** and Explorer cannot see that folder, so reach it over Wi‑Fi.

| What | Where to get it |
|------|-----------------|
| Loop segments `op_00.mp4`, `op_01.mp4` | `http://<phone-ip>:8765/pcld_ios_media/loop/`, or the LAN page file list |
| Export log | `http://<phone-ip>:8765/pcld_ios_media/logs/export_latest.txt` |
| Archived exports | `http://<phone-ip>:8765/browse` → **On phone (playback)**; each `archive/` file has **Delete** |

**Files → On My iPhone → Loop Segments → Exports** is left over from older builds and is normally empty. **Explorer → Apple iPhone → Internal Storage** shows only Photos (folders like `202605_a`), never the app.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Internal Storage only `202605_a` folders | Those are **Photos**. The app's files are not visible over USB; use the LAN page `http://<phone-ip>:8765/` |
| PC can’t see iPhone | USB is not used here. Check the phone and PC are on the same Wi‑Fi, and **LAN server on Wi‑Fi** is on |
| Network timed out on export | Strong cellular; keep app foreground; try Wi‑Fi; read the export log at `http://<phone-ip>:8765/pcld_ios_media/logs/export_latest.txt` |
| LAN sync fails | Same Wi‑Fi; Local Network allowed for Loop Segments; IP in `windows/loop-segments-windows.json` (`phoneLanHost`); wait for `DLNA slot published` in `export_latest.txt` |
| DLNA empty | Confirm `op_00.mp4` and `op_01.mp4` in `F:\f1_media\3d_fullsbs_trans` |
| pCloud fails on phone | Approve WebDAV 2FA email; check cellular permission. **Authenticated WebDAV 404** (even on `/p_cld_media/`) while unauth still **401** is usually a **pCloud outage** — same 404 in browser/Cyberduck on `webdav.pcloud.com`; wait it out (see [ios/README.md](ios/README.md#pcloud-webdav-404-accountservice)). Europe API **1022** is wrong datacenter, not 2FA |
| Export fails on phone | Read `http://<phone-ip>:8765/pcld_ios_media/logs/export_latest.txt` |

---

## Not used in this workflow

- iPhone **Personal Hotspot** (PC does not share phone internet)
- **PC-side ffmpeg** / `Run-SegmentCopy.ps1` (legacy pipeline in `3d_loop_segments` repo)
- PotPlayer **RememberFiles** registry resume
- PC Wi‑Fi **idle stop** while ffmpeg runs on PC (not applicable when export is on the phone)
