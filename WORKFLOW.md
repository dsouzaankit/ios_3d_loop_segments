# Workflow: iPhone cellular → USB → PC DLNA (WLAN)

Three separate networks. **No Personal Hotspot** required. **No PC-side ffmpeg** — export runs only on the iPhone.

```text
┌─────────────────────────────────────────────────────────────────┐
│  iPhone (cellular LTE/5G only — Wi‑Fi off is OK for export)      │
│    Loop Segments app → pCloud WebDAV (internet)                 │
│    Writes Documents/Exports/3d_op_00.mp4, 3d_op_01.mp4          │
└────────────────────────────┬────────────────────────────────────┘
                             │ USB cable (file transfer only)
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  Windows PC                                                     │
│    Sync-IphoneSegments.ps1 → F:\f1_media\3d_fullsbs_trans       │
│    DLNA media server → WLAN → TV / receiver / PotPlayer         │
└─────────────────────────────────────────────────────────────────┘
```

| Step | Where | Network |
|------|--------|---------|
| 1. Browse pCloud, run export | iPhone | **Cellular** (or Wi‑Fi if you prefer) |
| 2. Copy segment MP4s | USB | No IP network |
| 3. LAN playback | PC + TV | **WLAN** (Ethernet to router also fine) |

The PC never pulls from pCloud and never runs ffmpeg for this workflow. The phone never serves DLNA.

---

## 1. Build and install the iPhone app (one-time)

You need an **IPA** built in the cloud (no local Mac). See [ios/BUILD-WITHOUT-MAC.md](ios/BUILD-WITHOUT-MAC.md).

Install via **TestFlight** or sideload (AltStore, etc.) with an Apple Developer account.

---

## 2. On the iPhone (cellular)

1. **Settings → Cellular → Loop Segments** → allow cellular data.
2. Optional: turn **Wi‑Fi off** to force cellular-only pCloud access (no hotspot).
3. Open **Loop Segments** → sign in to pCloud (US/EU).
4. Browse to a video → set seek (presets 0/10/15/30/45 min) → **Start export**.
5. Keep the app in the foreground until both `3d_op_00.mp4` and `3d_op_01.mp4` exist (Files → Loop Segments → Exports).

Large files on cellular: expect long runs; export paces reads in real time.

---

## 3. USB transfer to the PC

1. Connect iPhone with USB; unlock; tap **Trust** on the phone.
2. On Windows, open **Apple Devices** / Explorer → iPhone → **Loop Segments** → **Exports**.
3. Run sync (copies into DLNA library folder):

```powershell
cd P:\all_scripts\ios_3d_loop_segments\windows
.\Sync-IphoneSegments.ps1
```

If auto-discovery fails, paste the Exports path:

```powershell
.\Sync-IphoneSegments.ps1 -SourceRoot 'D:\Apple iPhone\Internal Storage\Loop Segments\Exports'
```

**Wait for device** (polls until both MP4s are visible):

```powershell
.\Sync-IphoneSegments.ps1 -WaitForDevice -WaitMinutes 30
```

Optional: register a logon task that runs sync when you sign in (after plugging in the phone):

```powershell
.\Register-UsbSyncTask.ps1
```

---

## 4. DLNA playback on WLAN

1. PC connected to the same **WLAN** as the TV/player (not via iPhone hotspot).
2. Windows **media streaming** (or your existing DLNA server) publishes `F:\f1_media\3d_fullsbs_trans`.
3. Open the library on the TV; play the rotating `3d_op_*.mp4` entries.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| PC can’t see iPhone | Trust PC, unlock phone, install Apple Devices / iTunes drivers |
| Sync can’t find Exports | Use `-SourceRoot` from Explorer address bar |
| DLNA empty | Confirm `3d_op_00.mp4` and `3d_op_01.mp4` in `F:\f1_media\3d_fullsbs_trans` |
| pCloud fails on phone | Approve WebDAV 2FA email; check cellular permission for app |
| Export fails on phone | `.\Sync-IphoneSegments.ps1` also copies logs → `%USERPROFILE%\Documents\LoopSegmentsLogs\export_latest.txt` (Windows USB often hides logs on the phone) |

---

## Not used in this workflow

- iPhone **Personal Hotspot** (PC does not share phone internet)
- **PC-side ffmpeg** / `Run-SegmentCopy.ps1` (legacy pipeline in `3d_loop_segments` repo)
- PotPlayer **RememberFiles** registry resume
- PC Wi‑Fi **idle stop** while ffmpeg runs on PC (not applicable when export is on the phone)
