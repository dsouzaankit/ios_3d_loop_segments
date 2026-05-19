# ios_3d_loop_segments

**iPhone cellular → pCloud → segment export → (PC) → DLNA**

The iPhone app automates **pCloud export** on cellular. Getting files onto the PC **automatically** is **not** solved by USB + Apple Devices (manual save only). See **[FEASIBILITY.md](FEASIBILITY.md)**.

| Automated today | Not automated today |
|-----------------|---------------------|
| pCloud → phone `op_00.mp4`; PC pair via `Sync-FromPhoneLAN.ps1 -Watch` (Wi‑Fi) | Apple Devices manual save to DLNA folder (one-off) |
| **PC:** `Run-SegmentCopy.ps1` in [`3d_loop_segments`](../3d_loop_segments/) (sibling repo) | Legacy Photos/USB PowerShell sync scripts (removed from `windows/`) |

**Practical production:** run **`Run-SegmentCopy.ps1`** on the PC for unattended DLNA; use the iPhone app when the PC is unavailable.

| Step | Device | Connection |
|------|--------|------------|
| Export from pCloud | iPhone | Cellular (Wi‑Fi off OK) |
| Copy `op_*.mp4` | iPhone → PC | Wi‑Fi (`Sync-FromPhoneLAN.ps1`) or manual USB |
| Play on TV | PC → LAN | WLAN (DLNA server on Windows) |

Full guide: **[WORKFLOW.md](WORKFLOW.md)**

---

## Windows (after iPhone export)

**Live PC sync:** **Serve Exports on Wi‑Fi** on the phone, then:

```powershell
cd P:\all_scripts\ios_3d_loop_segments\windows
.\Set-LoopSegmentsLANHost.ps1 <phone-ip>   # once, from export log
.\Sync-FromPhoneLAN.ps1 -Watch
```

Or **Apple Devices** → **Loop Segments → Exports** → save `op_00.mp4` directly to `F:\f1_media\3d_fullsbs_trans`. See [ios/README.md](ios/README.md).

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
| [windows/Sync-FromPhoneLAN.ps1](windows/Sync-FromPhoneLAN.ps1) | Wi‑Fi pull `op_00.mp4` → PC DLNA pair |
| [windows/Set-LoopSegmentsLANHost.ps1](windows/Set-LoopSegmentsLANHost.ps1) | Save phone LAN IP |
| [windows/Set-LoopSegmentsDestination.ps1](windows/Set-LoopSegmentsDestination.ps1) | Save PC DLNA folder |
| [codemagic.yaml](codemagic.yaml) | Cloud iOS build |

PotPlayer registry resume and **PC-side** `Run-SegmentCopy.ps1` are **not** part of this repo.
