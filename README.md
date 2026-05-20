# ios_3d_loop_segments

**iPhone cellular → pCloud → segment export → (PC) → DLNA**

The iPhone app automates **pCloud export** on cellular. Getting files onto the PC **automatically** is **not** solved by USB + Apple Devices (manual save only). See **[FEASIBILITY.md](FEASIBILITY.md)**.

| Automated today | Not automated today |
|-----------------|---------------------|
| pCloud → phone `pcld_ios_media/loop/op_00|01` + `pcld_ios_media/_working`; PC via `Mount-LoopSegmentsRclone.ps1` → Skybox DLNA | Apple Devices USB save; legacy scripts in `windows/archive/` |
| **PC:** `Run-SegmentCopy.ps1` in [`3d_loop_segments`](../3d_loop_segments/) (sibling repo) | Legacy Photos/USB PowerShell sync scripts (removed from `windows/`) |

**Practical production:** run **`Run-SegmentCopy.ps1`** on the PC for unattended DLNA; use the iPhone app when the PC is unavailable.

| Step | Device | Connection |
|------|--------|------------|
| Export from pCloud | iPhone | Cellular (Wi‑Fi off OK) |
| Expose `Exports/` on PC | iPhone → PC | rclone mount (`Mount-LoopSegmentsRclone.ps1`) or manual USB |
| Play on TV | PC → LAN | WLAN (DLNA server on Windows) |

Full guide: **[WORKFLOW.md](WORKFLOW.md)**

---

## Windows (after iPhone export)

**Live PC sync:** **Serve Exports on Wi‑Fi** on the phone, then:

```powershell
cd P:\all_scripts\ios_3d_loop_segments\windows
.\Set-LoopSegmentsLANHost.ps1 <phone-ip>   # once, from export log
.\Mount-LoopSegmentsRclone.ps1
```

Point Skybox PC / DLNA at `L:\loop\` (segments) or `L:\` (includes `_working.mp4`). See [ios/README.md](ios/README.md).

---

## iPhone app (no Mac on your desk)

Sources: [`ios/`](ios/). Install on your phone: **[ios/BUILD-WITHOUT-MAC.md](ios/BUILD-WITHOUT-MAC.md)** — **$0** (free Apple ID + Sideloadly on Windows) or paid TestFlight.

Export uses **AVFoundation** on device (no embedded ffmpeg). **iOS 26.x:** **1.0.5+** to launch; **1.1.0** for export and fixed logs. Rebuild IPA from GitHub Actions if the phone still shows 1.0.5.

On phone: **Settings → Cellular → Loop Segments → On**.

---

## Layout

| Path | Role |
|------|------|
| [WORKFLOW.md](WORKFLOW.md) | Step-by-step cellular / LAN / DLNA |
| [DESIGN.md](DESIGN.md) | Architecture |
| [ios/](ios/) | Loop Segments iPhone app |
| [windows/README.md](windows/README.md) | **Portable PC setup** (`loop-segments-windows.json`) |
| [windows/Mount-LoopSegmentsRclone.ps1](windows/Mount-LoopSegmentsRclone.ps1) | rclone WebDAV mount of phone `Exports/` |
| [windows/Set-LoopSegmentsWindows.ps1](windows/Set-LoopSegmentsWindows.ps1) | Per-PC paths (rclone, WinFsp, drive letter) |
| [windows/archive/](windows/archive/) | Legacy sync / `net use` WebDAV scripts |
| [codemagic.yaml](codemagic.yaml) | Cloud iOS build |

PotPlayer registry resume and **PC-side** `Run-SegmentCopy.ps1` are **not** part of this repo.
