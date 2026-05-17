# ios_3d_loop_segments

**iPhone cellular → pCloud → segment export → (PC) → DLNA**

The iPhone app automates **pCloud export** on cellular. Getting files onto the PC **automatically** is **not** solved by USB + Apple Devices (manual save only). See **[FEASIBILITY.md](FEASIBILITY.md)**.

| Automated today | Not automated today |
|-----------------|---------------------|
| pCloud → phone `3d_op_00/01.mp4` | Phone → PC DLNA folder (without manual Apple Devices or PC ffmpeg) |
| **PC:** `Run-SegmentCopy.ps1` in [`3d_loop_segments`](../3d_loop_segments/) (sibling repo) | Live 60s refresh on PC via USB |

**Practical production:** run **`Run-SegmentCopy.ps1`** on the PC for unattended DLNA; use the iPhone app when the PC is unavailable.

| Step | Device | Connection |
|------|--------|------------|
| Export from pCloud | iPhone | Cellular (Wi‑Fi off OK) |
| Copy `3d_op_*.mp4` | iPhone → PC | USB |
| Play on TV | PC → LAN | WLAN (DLNA server on Windows) |

Full guide: **[WORKFLOW.md](WORKFLOW.md)**

---

## Windows (after iPhone export)

**Apple Devices** → save `3d_op_*.mp4` to `F:\f1_media\3d_fullsbs_trans` (simplest), or save to `Documents\LoopSegmentsIncoming` then:

```powershell
cd P:\all_scripts\ios_3d_loop_segments\windows
.\Copy-FromIncoming.ps1
```

`Sync-IphoneSegments.ps1` only applies if your PC exposes a readable iPhone Exports path (uncommon with Apple Devices).

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
