# ios_3d_loop_segments

**iPhone cellular → pCloud WebDAV → segment export → USB → PC → DLNA on WLAN**

No Personal Hotspot: the phone uses **cellular** for pCloud; the PC uses **WLAN** only for DLNA playback after a **USB** file copy. The PC does **not** run ffmpeg or pull from pCloud for this pipeline.

| Step | Device | Connection |
|------|--------|------------|
| Export from pCloud | iPhone | Cellular (Wi‑Fi off OK) |
| Copy `3d_op_*.mp4` | iPhone → PC | USB |
| Play on TV | PC → LAN | WLAN (DLNA server on Windows) |

Full guide: **[WORKFLOW.md](WORKFLOW.md)**

---

## Windows (after iPhone export)

```powershell
cd P:\all_scripts\ios_3d_loop_segments\windows
.\Sync-IphoneSegments.ps1 -WaitForDevice
```

Copies `3d_op_00.mp4` / `3d_op_01.mp4` into `F:\f1_media\3d_fullsbs_trans` for your existing DLNA server.

Optional logon auto-sync: `.\Register-UsbSyncTask.ps1`

---

## iPhone app (no Mac on your desk)

Sources: [`ios/`](ios/). Install on your phone: **[ios/BUILD-WITHOUT-MAC.md](ios/BUILD-WITHOUT-MAC.md)** — **$0** (free Apple ID + Sideloadly on Windows) or paid TestFlight.

Export uses **AVFoundation** on device (no embedded ffmpeg). **iOS 26.x:** **1.0.5+** to launch; **1.1.0** for export and fixed logs. Rebuild IPA from GitHub Actions if the phone still shows 1.0.5.

On phone: **Settings → Cellular → Loop Segments → On**.

---

## Layout

| Path | Role |
|------|------|
| [WORKFLOW.md](WORKFLOW.md) | Step-by-step cellular / USB / DLNA |
| [DESIGN.md](DESIGN.md) | Architecture |
| [ios/](ios/) | Loop Segments iPhone app |
| [windows/Sync-IphoneSegments.ps1](windows/Sync-IphoneSegments.ps1) | USB → DLNA folder only |
| [windows/Register-UsbSyncTask.ps1](windows/Register-UsbSyncTask.ps1) | Logon sync task |
| [codemagic.yaml](codemagic.yaml) | Cloud iOS build |

PotPlayer registry resume and **PC-side** `Run-SegmentCopy.ps1` are **not** part of this repo.
