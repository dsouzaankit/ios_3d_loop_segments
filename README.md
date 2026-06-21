# ios_3d_loop_segments

**iPhone cellular → pCloud → segment export → (PC) → DLNA**

The iPhone app automates **pCloud export** on cellular. Getting files onto the PC **automatically** is **not** solved by USB + Apple Devices (manual save only). See **[FEASIBILITY.md](FEASIBILITY.md)**.

| Automated today | Not automated today |
|-----------------|---------------------|
| pCloud → phone `pcld_ios_media/loop/op_00|01` + `pcld_ios_media/_working`; PC via **LAN HTTP** / scripts (see [ios/README.md](ios/README.md)) | Apple Devices USB save; legacy scripts in `windows/archive/` |
| **PC:** `Run-SegmentCopy.ps1` in [`3d_loop_segments`](../3d_loop_segments/) (sibling repo) | Legacy Photos/USB PowerShell sync scripts (removed from `windows/`) |

**Practical production:** run **`Run-SegmentCopy.ps1`** on the PC for unattended DLNA; use the iPhone app when the PC is unavailable.

| Step | Device | Connection |
|------|--------|------------|
| Export from pCloud | iPhone | Cellular (Wi‑Fi off OK) |
| Expose `Exports/` on PC | iPhone → PC | Browser / download on `http://<ip>:8765/`, or manual USB |
| Play on TV | PC → LAN | WLAN (DLNA server on Windows) |

Full guide: **[WORKFLOW.md](WORKFLOW.md)**

---

## Windows (after iPhone export)

**Live PC sync:** **LAN server on Wi‑Fi** on the phone, then:

```powershell
cd P:\all_scripts\ios_3d_loop_segments\windows
.\Set-LoopSegmentsLANHost.ps1 <phone-ip>
.\Mount-LoopSegmentsRclone.ps1 -TestOnly
```

Copy segment files into your DLNA folder (or use [WORKFLOW.md](WORKFLOW.md)). See [ios/README.md](ios/README.md).

---

## iPhone app (no Mac on your desk)

Sources: [`ios/`](ios/). Install: **[ios/BUILD-WITHOUT-MAC.md](ios/BUILD-WITHOUT-MAC.md)** — **AltStore + AltServer** (primary) or paid TestFlight; Sideloadly only if AltStore fails.

**Free install (~7-day certs):**

| Piece | Notes |
|-------|--------|
| **Install IPA** | On the **iPhone**: AltStore → **My Apps → +** (not AltServer sideload on PC) |
| **Refresh** | **You** tap **AltStore → Refresh All** (USB) — AltServer signs; it does **not** refresh on plug-in alone. Wi‑Fi: AltStore may refresh in background if pairing works ([§3](ios/BUILD-WITHOUT-MAC.md#3-automate-weekly-refresh-altserver--altstore)) |
| **Wi‑Fi refresh** | Often **broken** on Windows 11 (iTunes Wi‑Fi sync / Apple Devices / proxy). **Reliable habit: USB + Refresh All** weekly — see [BUILD-WITHOUT-MAC.md §3](ios/BUILD-WITHOUT-MAC.md#3-automate-weekly-refresh-altserver--altstore) |
| **Signing errors** | iCloud (Apple direct, not Store) + **iTunes → Account → Authorizations → Deauthorize → Authorize** |
| **AMDS missing** | Full **iTunes uninstall/reinstall** (`iTunes64Setup.exe`, admin). **Do not** install Microsoft Store **Apple Devices** afterward — it removes **Apple Mobile Device Service** |
| **Trust** | [Once per install](ios/BUILD-WITHOUT-MAC.md#trust-the-developer-on-iphone-required-once-not-weekly) — Settings → General → VPN & Device Management |

Optional: `windows/Register-AltServerAtLogon.ps1` keeps AltServer in the tray; you still plug in USB for refresh when Wi‑Fi pairing fails.

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
| [windows/Mount-LoopSegmentsRclone.ps1](windows/Mount-LoopSegmentsRclone.ps1) | WebDAV **`-TestOnly`** / **mount** / `-Remove` / `-RemovePort80Proxy` — see [RCLONE-PHONE-MOUNT.md](windows/RCLONE-PHONE-MOUNT.md) |
| [windows/Set-LoopSegmentsWindows.ps1](windows/Set-LoopSegmentsWindows.ps1) | Per-PC paths (rclone, WinFsp, drive letter) |
| [windows/archive/](windows/archive/) | Legacy `net use` / port-80 proxy, `Sync-FromPhoneLAN.ps1` |
| [codemagic.yaml](codemagic.yaml) | Cloud iOS build |

PotPlayer registry resume and **PC-side** `Run-SegmentCopy.ps1` are **not** part of this repo.
