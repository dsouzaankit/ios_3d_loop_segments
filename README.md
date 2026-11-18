# ios_3d_loop_segments

**iPhone cellular → pCloud → segment export → (PC) → DLNA**

The iPhone app automates **pCloud export** on cellular. Getting files onto the PC **automatically** is **not** solved by USB + Apple Devices (manual save only). See **[FEASIBILITY.md](FEASIBILITY.md)**.

| Automated today | Not automated today |
|-----------------|---------------------|
| pCloud → phone `pcld_ios_media/loop/op_00|01` + `pcld_ios_media/_working`; PC via **LAN HTTP** / scripts (see [ios/README.md](ios/README.md)) | Apple Devices USB save; legacy scripts in `windows/archive/` |
| **PC:** `Run-SegmentCopy.ps1` in [`3d_loop_segments`](../3d_loop_segments/) (sibling repo) | Legacy Photos/USB PowerShell sync scripts (removed from `windows/`) |

**Practical production:** run **`Run-SegmentCopy.ps1`** on the PC for unattended DLNA; use the iPhone app when the PC is unavailable.

**PC companion (browse + request export):** [`windows/pcloud_web_companion`](windows/pcloud_web_companion) — clone with **`--recurse-submodules`** (repo-root **`env_setup/`**: AltServer + phone-subnet; **`Skybox_vr_pc/`**: SKYBOX desktop AirScreen helpers). On each Windows PC run `windows\setup\Setup-LoopSegmentsWindows.ps1` once, then `windows\pcloud_web_companion\Run-PCloudWebCompanion.ps1` (USB-opens Loop Segments if unlocked; Chromium profile zip lives on P: as `windows\pcloud_web_companion\chromium-profile.zip`, extracted to local AppData and cleared after exit). Browse pCloud on the PC while the phone exports over cellular via LAN REST (`/export_from_folder.json`, etc.).

| Step | Device | Connection |
|------|--------|------------|
| Export from pCloud | iPhone | Cellular (Wi‑Fi off OK) |
| Expose `pcld_ios_media/` on PC | iPhone → PC | Browser / download on `http://<ip>:8765/` (USB cannot reach it) |
| Play on TV | PC → LAN | WLAN (DLNA server on Windows) |

Full guide: **[WORKFLOW.md](WORKFLOW.md)**

---

## Windows (after iPhone export)

**Live PC sync:** **LAN server on Wi‑Fi** on the phone, then:

```powershell
cd P:\all_scripts\ios_3d_loop_segments\windows
.\setup\Set-LoopSegmentsLANHost.ps1   # USB-connected phone → Wi-Fi IP (or pass <phone-ip>)
.\rclone\Mount-LoopSegmentsRclone.ps1 -TestOnly
```

Copy segment files into your DLNA folder (or use [WORKFLOW.md](WORKFLOW.md)). See [ios/README.md](ios/README.md).

---

## iPhone app (no Mac on your desk)

Sources: [`ios/`](ios/). Install: **[ios/BUILD-WITHOUT-MAC.md](ios/BUILD-WITHOUT-MAC.md)** — **SideStore nightly** (preferred when AltStore flakes) or **AltStore + AltServer**; paid TestFlight; Sideloadly only as last resort.

**Deploy IPA to iCloud (Windows):** from repo root, `.\deploy.ps1` triggers GitHub **ios-build**, downloads the IPA locally, then **calls `.\copy-to-icloud.ps1`** (requires `gh auth login`). AltServer tray prep is **skipped by default** — pass `-EnsureAltStorePrep` for AltStore. Phone-subnet check stays on **USB plug-in**, not IPA deploy. After it triggers the build, if the iPhone is on **USB**, it connects **LocalDevVPN** if it is not (Loop Segments stays open during the build; the USB install relaunches it for the handover; with `-SkipUsbInstall` the phone is left alone): it launches LocalDevVPN over USB, whose **Auto-connect on launch** setting (switch it on once) connects it, then goes back to the Home Screen (`windows\usb\Prepare-PhoneForSideStoreViaUsb.ps1`; `-SkipPhonePrep` turns it off). It skips LocalDevVPN when the **PC-signed USB install** is ready (below). No router is touched. **PC-signed USB install (tried first):** with SideStore's exported certificate in `windows\signing\` and zsign set up, the PC signs the IPA and installs it over USB in about 5 s: no tap, no Wi‑Fi moves, no LocalDevVPN ([windows/README.md → PC-signed USB install](windows/README.md#pc-signed-usb-install-zsign-no-install-tap)). Not set up or failed: the SideStore install below. **USB install via SideStore (build 428+ on the phone):** after the download, with the iPhone on USB, `deploy.ps1` first moves the **phone and this PC off the phone LAN** (the `phoneLanHost` /24 from the config): if the phone is on it, it bounces that AP so the phone hops to another saved Wi‑Fi, and the PC joins the phone's new network, because SideStore needs www over Wi‑Fi to sign and the phone LAN Wi‑Fi has no gateway (LAN only; the app prefers 5G for internet). This is the opposite of the web companion, which needs both **on** the phone LAN; nothing moves them back after the install: the phone usually rejoins the phone LAN by itself once that AP's Wi‑Fi is back (iOS auto-join prefers it, typically when the phone wakes), and the companion's start-up network check moves the PC, and the phone if still needed. Pin the network with `ipaInstallWifiProfile` (empty = first saved profile in range off that subnet). It then serves the IPA once on that network (`http://<PC IP>:8766/<random>/LoopSegments.ipa`, plain TCP listener, no admin) and launches Loop Segments over USB with `-openURL sidestore://install?url=…`. The app opens that link and quits, SideStore shows **Install**: **tap it** (the only manual step). The script waits until the phone reports the new build, then switches **LocalDevVPN back off if this deploy switched it on** (left on if the install is not confirmed). `windows\usb\Install-LoopSegmentsIpaViaUsb.ps1`; Each try first quits SideStore and restarts LocalDevVPN (tunnel and app, about 12 s), so SideStore starts fresh with a new tunnel. Only the handover launches Loop Segments, so with a Face ID lock on it you confirm once per try. A failed install is retried once, then (unless `-NoPhoneRestart`) the phone is restarted over USB — the best fix for SideStore errors other than an offline LocalDevVPN — and after you unlock it, tried a last time. `-SkipUsbInstall` turns it off. The iCloud copy is still made as a fallback. Paste-only (no build): `.\copy-to-icloud.ps1` — stamped `LoopSegments-b{build}-{time}.ipa` + prune older `LoopSegments*.ipa` (same idea as `web_auto_parking\deploy.ps1`).

**Free install (~7-day certs):**

| Piece | Notes |
|-------|--------|
| **Install IPA** | On the **iPhone**: **SideStore** or **AltStore** → **My Apps → +** (not AltServer/Sideloadly “sideload from PC” if you want in-store refresh) |
| **SideStore** | Use **nightly** ([docs](https://docs.sidestore.io/docs/installation/prerequisites)): **iloader** (USB once) + **LocalDevVPN** (on for every install/refresh). Stable SideStore hit the same **incorrect data format** as AltStore; **nightly worked**. Free ID = **3 apps** — do **not** keep AltStore + SideStore together |
| **Refresh (SideStore)** | **No PC** — LocalDevVPN + Wi‑Fi → SideStore → tap **7 DAYS** / Refresh (works after expiry too). PC only if pairing dies (iloader). **Device Reachability (Ping) unreachable** / **Pairing file not found** → [reinstall SideStore via iloader](ios/BUILD-WITHOUT-MAC.md#reinstall-or-update-sidestore-with-iloader) (stable worked here), then re-add apps via **My Apps → +**. |
| **Refresh (AltStore)** | **You** tap **AltStore → Refresh All** (**USB**) — AltServer signs; it does **not** refresh on plug-in alone. USB works even with multiple gateways. Wi‑Fi: often **broken** on Win11 — see [BUILD-WITHOUT-MAC.md §3](ios/BUILD-WITHOUT-MAC.md#3-automate-weekly-refresh-altserver--altstore) |
| **Signing errors** | AltStore: iCloud (Apple direct) + **iTunes → Deauthorize → Authorize**. SideStore: change anisette / re-pair with iloader. Wait for a **fully local** IPA (no iCloud stub) before My Apps → + |
| **Trust** | [Once per install](ios/BUILD-WITHOUT-MAC.md#trust-the-developer-on-iphone-required-once-not-weekly) — Settings → General → VPN & Device Management |

Optional (AltStore path only): `windows/sideload/Register-AltServerAtLogon.ps1` keeps AltServer in the tray. Scripts **skip AltServer by default** — pass `-EnsureAltServer` (companion / USB / setup) or `-EnsureAltStorePrep` (deploy / copy-to-icloud).

Export uses **AVFoundation** on device (no embedded ffmpeg). **iOS 26.x:** **1.0.5+** to launch; **1.1.0** for export and fixed logs. Rebuild IPA from GitHub Actions if the phone still shows 1.0.5.

On phone: **Settings → Cellular → Loop Segments → On**.

---

## Layout

| Path | Role |
|------|------|
| [WORKFLOW.md](WORKFLOW.md) | Step-by-step cellular / LAN / DLNA |
| [DESIGN.md](DESIGN.md) | Architecture |
| [deploy.ps1](deploy.ps1) | Windows: Actions IPA → local, then runs [copy-to-icloud.ps1](copy-to-icloud.ps1) |
| [bump-build.ps1](bump-build.ps1) | Windows: build number + 1 (`ios/project.yml`) and a README build note, commit + push, then runs `deploy.ps1` — a new IPA with no app changes (e.g. to test the USB install, which skips a phone already on that build). If a built IPA is newer than the USB phone's build (e.g. a deploy that timed out), it runs `deploy.ps1 -UseLatest` for that one instead. `-DryRun`, `-NoDeploy`, `-Note`, `-ForceBump` |
| [reinstall-latest.ps1](reinstall-latest.ps1) | Windows: `deploy.ps1 -UseLatest -ForceUsbInstall` — (re)install the newest already-built IPA (download, iCloud copy, USB install) with **no** GitHub build and no bump: installs when its build is the same as or newer than the phone's (the same build is reinstalled; an older one never is), e.g. after a deploy timed out. Passes `-SkipICloud`, `-SkipUsbInstall`, `-NoPhoneRestart`, ... |
| [copy-to-icloud.ps1](copy-to-icloud.ps1) | Stamped iCloud paste + prune (shared by deploy; no build) |
| [ios/](ios/) | Loop Segments iPhone app |
| [windows/README.md](windows/README.md) | **Portable PC setup** (`loop-segments-windows.json`) |
| [env_setup/](env_setup/) | Submodule: start AltServer; phone Wi-Fi IPv4 over USB (the phone's network monitor, `pcapd` sniffing as the fallback) vs PC/AltServer subnet ([ios_env_setup](https://github.com/dsouzaankit/ios_env_setup)) |
| [Skybox_vr_pc/](Skybox_vr_pc/) | Submodule: SKYBOX VR desktop start/hide/quit + AirScreen Add-folders ([skybox-vr-pc](https://github.com/dsouzaankit/skybox-vr-pc)) |
| [windows/rclone/Mount-LoopSegmentsRclone.ps1](windows/rclone/Mount-LoopSegmentsRclone.ps1) | WebDAV **`-TestOnly`** / **mount** / `-Remove` / `-Unstick` / LAN watch — see [RCLONE-PHONE-MOUNT.md](windows/rclone/RCLONE-PHONE-MOUNT.md) |
| [windows/setup/Set-LoopSegmentsWindows.ps1](windows/setup/Set-LoopSegmentsWindows.ps1) | Per-PC paths (rclone, WinFsp, drive letter) |
| [windows/archive/](windows/archive/) | Legacy `net use` / port-80 proxy, `Sync-FromPhoneLAN.ps1` |
| [codemagic.yaml](codemagic.yaml) | Cloud iOS build |

PotPlayer registry resume and **PC-side** `Run-SegmentCopy.ps1` are **not** part of this repo.
