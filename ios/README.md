https://github.com/dsouzaankit/ios_3d_loop_segments/actions/workflows/ios-build.yml

cd P:\all_scripts\ios_3d_loop_segments\windows
.\Set-LoopSegmentsDestination.ps1 'C:\Users\dsouzaankit\Downloads\ios_3d_out'
# .\Sync-FromPhonePhotos-Watch.cmd
.\Set-LoopSegmentsLANHost.ps1 10.0.100.10
.\Sync-FromPhoneLAN.ps1 -Discover
.\Sync-FromPhoneLAN.ps1 -Watch

Notes:
phone should be unlocked, app on foreground, screen on!


# Loop Segments (iOS)

**Cellular → pCloud WebDAV → segment export → LAN (or USB) → PC DLNA.** See [../WORKFLOW.md](../WORKFLOW.md).

Build **1.0.6+** uses **AVFoundation** stream copy to `3d_op_00.mp4` / `3d_op_01.mp4` (no embedded ffmpeg). Required on **iOS 26.x** (ffmpeg-kit crashes at launch).

## Open in Xcode (requires macOS or cloud CI)

**Option A — XcodeGen**

```bash
cd ios
brew install xcodegen   # on macOS
xcodegen generate
open LoopSegments.xcodeproj
```

No ffmpeg SPM dependency in [project.yml](project.yml).

**Option B — manual**

1. New iOS App (SwiftUI, iOS 17+).
2. Add all files under `LoopSegments/`.
3. Merge [LoopSegments/Resources/Info.plist](LoopSegments/Resources/Info.plist) keys.

## Export (AVFoundation)

- WebDAV: `WebDAVResourceLoader` + Basic auth on `AVURLAsset`
- Passthrough to MP4 when supported: H.264, HEVC (hvc1/hev1) + AAC (AV1 sources are rejected at probe)
- 60s segments; phone keeps **one** file (`3d_op_00.mp4`); PC DLNA pair via **`Sync-FromPhoneLAN.ps1 -Watch`** (build 103+) or USB. **Dense fill** per minute is the default (sparse temp shell, not a full 17 GB copy); see transport table below for large-file exceptions.
- Real-time read pacing (like ffmpeg `-re`)
- Runs until end of file or **Stop**

Implementation: `LoopSegments/Services/Export/SegmentExporter.swift`

## PC sync (primary — LAN)

1. On the phone: **Serve Exports on Wi‑Fi while exporting** (export screen).
2. On the PC (same LAN):

```powershell
cd ..\windows
.\Set-LoopSegmentsLANHost.ps1 192.168.1.42   # IP from export log
.\Sync-FromPhoneLAN.ps1 -Watch
```

pCloud can stay on **cellular** while the LAN server serves `Documents/Exports/` on port **8765** (`3d_op_00.mp4`, logs, and optionally `_export_source_working.mp4` — the in-progress sparse temp; only while export runs, not for `-Watch` sync).

### Export transport

| Mode | When | Behavior |
|------|------|----------|
| **Dense fill** (default) | Source **&lt; ~1.5 GB**, or large file **first minute at seek 0** | Sparse temp once; **one dense pCloud download per minute window**; `file://` passthrough → `3d_op_00.mp4` |
| **Remote passthrough** | Sparse temp, minute **not** at file byte 0, source **&lt; ~1.5 GB** or **H.264** | **Capped pCloud reads** → HTTPS → export session; then dense + local if needed. |
| **Large HEVC mid-file** | **≥ ~1.5 GB**, HEVC, minute not at byte 0 (e.g. seek **30:00**) | **Dense-fill ~1 GB window** → **local export session** (remote passthrough skipped; matches seek‑0 minute‑1 success). |
| **Local export session** | Entire source dense on disk (small file or seek‑0 tail fill) | Passthrough via `AVAssetExportSession` on the temp file for every minute |
| **Hybrid (capped)** | Mid-file on **smaller** large sources where custom URL + sparse temp still opens | Head + dense window + MP4 index at EOF; falls back to HTTPS if reader fails |

Export needs enough free space for the sparse shell plus one minute’s dense window (or HTTPS range reads). Check `export_latest.txt` for which path ran.

**Not** a full-file download to the phone and **not** the old ffmpeg stream-export path — still one ~60s segment at a time, still passthrough on device, still LAN/USB to PC.

## Photos library (deactivated in app)

The Photos import sub-workflow is **off** (`PhotosSegmentPublisher.workflowEnabled = false` in source). Re-enable there to restore the export UI and library sync.

Legacy PC path: `Sync-FromIPhonePhotos.ps1 -Watch` (MTP / Internal Storage). Not used when Photos workflow is disabled.

## Search: `tokenSaved=false` / no API token

WebDAV browse and export work without the REST token. **Search** needs `userinfo?getauth=1` to return an `auth` field.

If `search_debug.txt` shows `result=0 but no auth` with your `userid`, pCloud recognized the account but **did not issue a search token**. Common causes:

| Check | Action |
|-------|--------|
| Wrong datacenter | Sign out → match **US** vs **Europe** to [my.pCloud](https://my.pcloud.com) (Settings → Data regions) |
| **2FA enabled** | pCloud often blocks third-party API tokens while WebDAV still works — try signing in after disabling 2FA, or an app-specific password if your account has one under Security |
| Stale API session | Build **88+** uses a cookieless login session; sign out and sign in again |
| Timeout | Search prepare allows **45s** for token fetch across regional API hosts |

Export and folder browse use **WebDAV only** — you do not need search for those.

## No Mac on your desk

[BUILD-WITHOUT-MAC.md](BUILD-WITHOUT-MAC.md) — GitHub Actions / Codemagic.

## Windows sync (USB → DLNA)

**`Documents/Exports/3d_op_*.mp4` is the full-quality DLNA source on the phone.** Apple does **not** expose that folder to PowerShell as a live USB drive path. You copy to the PC with **Apple Devices → Loop Segments → Exports → Save to PC** (manual folder pick each session, or a remembered Windows path).

| Step | PowerShell can automate? |
|------|---------------------------|
| Phone **Exports** → PC (USB) | **No** — Apple limitation; not scriptable via `Sync-IphoneSegments.ps1` in the usual Apple Devices workflow |
| PC save folder → DLNA library (`F:\f1_media\...`) | **Yes** — after you saved into `LoopSegmentsIncoming` (or similar): `windows\Copy-FromIncoming.ps1`, `Watch-LoopSegmentsIncoming.ps1` |
| Live ~60s segment refresh on PC | **Yes (LAN)** — **`Sync-FromPhoneLAN.ps1 -Watch`** while export runs and **Serve Exports on Wi‑Fi** is on (port **8765**) |

**LAN (build 103+):** Phone on Wi‑Fi serves `http://<phone-ip>:8765/3d_op_00.mp4` during export (pCloud can stay on cellular). PC script copies to the older DLNA slot — no USB, no Photos.

```powershell
cd ..\windows
.\Set-LoopSegmentsLANHost.ps1 192.168.1.42   # IP from export log
.\Sync-FromPhoneLAN.ps1 -Discover
.\Sync-FromPhoneLAN.ps1 -Watch
```

`Sync-IphoneSegments.ps1` only helps if Explorer shows a **readable** iPhone `…\Loop Segments\Exports` path. **`Sync-FromIPhonePhotos.ps1`** remains in `windows/` for legacy MTP use if you re-enable Photos in the app.

Details: [../WORKFLOW.md](../WORKFLOW.md) §3, [../FEASIBILITY.md](../FEASIBILITY.md).

After a manual Apple Devices save into an incoming folder:

```powershell
cd ..\windows
.\Copy-FromIncoming.ps1
```
