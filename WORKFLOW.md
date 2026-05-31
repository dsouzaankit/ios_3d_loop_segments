# Workflow: iPhone cellular → PC DLNA (WLAN)

> **Feasibility:** Manual **Apple Devices → Save to PC** does **not** automate updating the DLNA folder while segments rotate. See **[FEASIBILITY.md](FEASIBILITY.md)** — production automation is either **PC `Run-SegmentCopy.ps1`** (pCloud → PC) or a **future Wi‑Fi pull** from the phone; USB copy is at best **once per export session**.

Three separate networks. **No Personal Hotspot** required for the iPhone path below.

```text
┌─────────────────────────────────────────────────────────────────┐
│  iPhone (cellular LTE/5G for pCloud; Wi‑Fi for LAN serve)        │
│    Loop Segments → pCloud WebDAV → Exports/op_00.mp4              │
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
| 2. Copy segment MP4s | iPhone → PC | **Wi‑Fi** (or manual USB via Apple Devices) |
| 3. LAN playback | PC + TV | **WLAN** (Ethernet to router also fine) |

The PC never pulls from pCloud and never runs ffmpeg for this workflow. The phone never serves DLNA.

---

## 1. Build and install the iPhone app (one-time)

You need an **IPA** built in the cloud (no local Mac). See [ios/BUILD-WITHOUT-MAC.md](ios/BUILD-WITHOUT-MAC.md).

Install via **TestFlight** or sideload (**AltStore** recommended; Sideloadly fallback) with a free or paid Apple ID — see [ios/BUILD-WITHOUT-MAC.md](ios/BUILD-WITHOUT-MAC.md).

---

## 2. On the iPhone (cellular)

1. **Settings → Cellular → Loop Segments** → allow cellular data.
2. Optional: turn **Wi‑Fi off** to force cellular-only pCloud access (no hotspot).
3. Open **Loop Segments** → sign in to pCloud (US/EU).
4. Browse to a video → set seek (presets 0/10/15/30/45 min) → **Start export**.
5. Keep the app in the foreground. On phone: **Files → Loop Segments → Exports** should show `op_00.mp4` updating each ~60s of **media** time (first segment can take several minutes on large moov-at-end HEVC while the minute **dense-downloads**).
6. On the phone: enable **LAN server on Wi‑Fi** so the PC can reach **`http://<ip>:8765/`**. Photos library export is **off** by default — see [ios/README.md](ios/README.md).

Large files on cellular: first segment waits for index + dense window (`Downloading window … (dense fill)` → `Window on disk` in `export_latest.txt`). Later minutes reuse the same sparse temp shell; export does not keep up with live TV wall clock on slow LTE — OK if the DLNA player **loops** the PC pair.

---

## 3. Copy segments to the PC

### Automated (Wi‑Fi)

1. iPhone and PC on the **same Wi‑Fi**; **LAN server on Wi‑Fi** on in the app.
2. Note the phone IP from the export log (`LAN export: http://192.168.x.x:8765/`).
3. On the PC:

```powershell
cd P:\all_scripts\ios_3d_loop_segments\windows
Copy-Item loop-segments-windows.example.json loop-segments-windows.json   # first time on this PC
.\Set-LoopSegmentsWindows.ps1 -PhoneHost 192.168.x.x
.\Mount-LoopSegmentsRclone.ps1 -TestOnly   # optional HTTP check
```

Open **`http://192.168.x.x:8765/`** in a browser and save files, use **`Invoke-WebRequest`**, or **[windows/archive/Sync-FromPhoneLAN.ps1](windows/archive/Sync-FromPhoneLAN.ps1)**. Per-PC json: [windows/README.md](windows/README.md).

Copy segment MP4s into your DLNA folder (or use **`Run-SegmentCopy.ps1`** from the sibling **`3d_loop_segments`** repo for pCloud → PC). Optional **rclone mount**: [windows/RCLONE-PHONE-MOUNT.md](windows/RCLONE-PHONE-MOUNT.md).

### Manual (USB / Apple Devices)

Apple Devices does **not** expose a scriptable phone path. Save **Loop Segments → Exports → op_00.mp4** directly to your DLNA folder (e.g. `F:\f1_media\3d_fullsbs_trans`) when prompted.

---

## 4. DLNA playback on WLAN

1. PC connected to the same **WLAN** as the TV/player (not via iPhone hotspot).
2. Windows **media streaming** (or your existing DLNA server) publishes `F:\f1_media\3d_fullsbs_trans`.
3. Open the library on the TV; play the rotating `op_*.mp4` entries.

---

## Finding **Loop Segments → Exports** on Windows

**`Internal Storage` with folders like `202605_a`, `202604_b`, …** = **Photos** (camera roll by month). That is normal. Your segment MP4s are **not** there.

| Where to look | What you should see |
|---------------|---------------------|
| **iPhone → Files → On My iPhone → Loop Segments → Exports** | `op_00.mp4`, `export_latest.txt`, `loop_segments_ok.txt` (always check here first) |
| **Apple Devices** → **Loop Segments** → **Exports** → **Save to PC** (you pick the Windows folder) | **Manual USB path** — save to `F:\f1_media\...` or use **LAN sync** above |
| **Explorer → This PC → Apple iPhone → Internal Storage** | Often **only** Photos (`202605_a`, …) — not the app |

If Explorer never shows **Loop Segments**:

1. Install/update **[Apple Devices](https://apps.microsoft.com/detail/9NP83LWLPZ9K)** (or iTunes for drivers).
2. Open the **Apple Devices** app → select iPhone → look for **Files** or apps list → **Loop Segments**.
3. On the phone, confirm exports exist in **Files** (step above).
4. Copy files manually: in **Files**, select `op_*.mp4` → **Share** → save to **iCloud Drive** / **OneDrive** / email to PC (workaround when USB app folders don’t mount).

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Internal Storage only `202605_a` folders | Those are **Photos**, not the app. Use **Files → On My iPhone → Loop Segments → Exports** on the phone; try **Apple Devices** app on PC for File Sharing |
| PC can’t see iPhone | Unlock phone, replug USB, open **Apple Devices** app; if Exports vanished during export, **stop export**, unlock, then browse again. Copy path from Explorer → `-SourceRoot` |
| Network timed out on export | Strong cellular; keep app foreground; try Wi‑Fi; read `Exports/export_latest.txt` |
| LAN sync fails | Same Wi‑Fi; Local Network allowed for Loop Segments; IP in `loop-segments-lan-host.txt`; wait for `DLNA slot published` in `export_latest.txt` |
| DLNA empty | Confirm `op_00.mp4` and `op_01.mp4` in `F:\f1_media\3d_fullsbs_trans` |
| pCloud fails on phone | Approve WebDAV 2FA email; check cellular permission for app |
| Export fails on phone | **Files → Loop Segments → Exports → export_latest.txt** on the phone |

---

## Not used in this workflow

- iPhone **Personal Hotspot** (PC does not share phone internet)
- **PC-side ffmpeg** / `Run-SegmentCopy.ps1` (legacy pipeline in `3d_loop_segments` repo)
- PotPlayer **RememberFiles** registry resume
- PC Wi‑Fi **idle stop** while ffmpeg runs on PC (not applicable when export is on the phone)
