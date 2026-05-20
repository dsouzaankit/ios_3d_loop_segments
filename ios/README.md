https://github.com/dsouzaankit/ios_3d_loop_segments/actions/workflows/ios-build.yml

cd P:\all_scripts\ios_3d_loop_segments\windows
Copy-Item loop-segments-windows.example.json loop-segments-windows.json   # once per PC
.\Set-LoopSegmentsWindows.ps1 -PhoneHost 10.0.100.10
.\Mount-LoopSegmentsRclone.ps1 -TestOnly   # HTTP reachability only (rclone drive mount archived — see windows/archive/RCLONE-PHONE-MOUNT-LEGACY.md)
# Copy files: open http://<phone-ip>:8765/ in a browser, Invoke-WebRequest, USB, or archive/Sync-FromPhoneLAN.ps1 — [windows/README.md](../windows/README.md)

Notes:
phone must be unlocked, app in foreground, screen on:
  Optional: Settings > Display & Brightness > Auto-Lock > Never!


# Loop Segments (iOS)

**Cellular → pCloud WebDAV → segment export → LAN (or USB) → PC DLNA.** See [../WORKFLOW.md](../WORKFLOW.md).

Build **1.0.6+** uses **AVFoundation** stream copy to `op_00.mp4` / `op_01.mp4` (no embedded ffmpeg). Required on **iOS 26.x** (ffmpeg-kit crashes at launch).

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
- Passthrough to MP4 when supported: H.264, HEVC (hvc1/hev1) + **AAC audio** when the source has aac/mp4a (manual path was video-only before build 133; export session kept both tracks)
- 60s segments; phone alternates **`pcld_ios_media/loop/op_00.mp4`** / **`pcld_ios_media/loop/op_01.mp4`**; sparse in-progress copy **`pcld_ios_media/_working.mp4`**. PC: copy over **HTTP** from **`http://<phone-ip>:8765/`** (browser / `Invoke-WebRequest` / [`../windows/archive/Sync-FromPhoneLAN.ps1`](../windows/archive/Sync-FromPhoneLAN.ps1)) — **rclone WebDAV mount to the phone is archived.** **Dense fill** per minute is the default.
- Real-time read pacing (like ffmpeg `-re`); segments cut at **keyframes** (~60s target, not strict wall-clock grid)
- Runs until end of file or **Stop**; **per-minute failsafe** skips a failed minute and continues dense-filling **`_working.mp4`**

Implementation: `LoopSegments/Services/Export/SegmentExporter.swift`

## PC sync (LAN HTTP)

1. On the phone: **Serve Exports on Wi‑Fi** (export screen; app open on LAN).
2. On the PC: use **`http://<phone-ip>:8765/`** — HTML index, **`status.json`**, and direct file URLs (**GET**/**HEAD**, **Range** for video). Optional: `..\windows\Mount-LoopSegmentsRclone.ps1 -TestOnly` after **`Set-LoopSegmentsWindows.ps1 -PhoneHost …`**.
3. **DLNA:** download or sync segment files into a **local PC folder** your media server indexes (many servers handle that better than streaming sparse shells from the phone).

**Do not** point **`rclone mount`** or a **`webdav`** remote at the phone on current builds — the in-app server is **HTTP-only**. The old **rclone + WinFsp** workflow is **archived**: [`../windows/archive/RCLONE-PHONE-MOUNT-LEGACY.md`](../windows/archive/RCLONE-PHONE-MOUNT-LEGACY.md).

Unattended **pCloud → PC** (no phone LAN): **`Run-SegmentCopy.ps1`** in the sibling **`3d_loop_segments`** repo.

LAN serves `pcld_ios_media/loop/op_*.mp4`, `pcld_ios_media/_working.mp4`, and logs on port **8765**. **Browser / Pigasus:** `pcld_ios_media/loop/op_00.mp4` for segments; `pcld_ios_media/_working.mp4` for the working file (`#t=` on the index clears after a finished export so it is not stuck on an old seek).

### SMB vs HTTP on the phone

**True SMB** on the iPhone is not available. The app serves **plain HTTP** on port **8765** (GET/HEAD/OPTIONS). Archived WebDAV / `net use` / **rclone**-to-phone setup: [`../windows/archive/`](../windows/archive/) (**[RCLONE-PHONE-MOUNT-LEGACY.md](../windows/archive/RCLONE-PHONE-MOUNT-LEGACY.md)**, `Map-LoopSegmentsWebDAV.ps1`).

| File | After copy to PC / direct HTTP URL | Skybox via PC DLNA |
|------|--------------------------------------|---------------------|
| `pcld_ios_media/loop/op_00.mp4`, `pcld_ios_media/loop/op_01.mp4` | Yes | Usually OK |
| `pcld_ios_media/_working.mp4` | Yes | May work (like VLC); sparse holes can break some servers |

### Quest LAN playback (Skybox vs Pigasus)

**pCloud WebDAV in Skybox** = full **HTTPS** files on pCloud’s server (what already works for you).

**Phone LAN** (`http://<ip>:8765`) = **plain HTTP** for the export folder (no WebDAV). Players differ:

| Player | `pcld_ios_media/_working.mp4` (sparse) | `pcld_ios_media/loop/op_00.mp4` (segment) |
|--------|----------------------------------------|------------------------|
| **Pigasus** (direct URL / network file) | **Works** — uses HTTP **Range** (head + `moov` tail + dense minutes) | Should work |
| **Skybox (WebDAV to phone)** | **Do not use** — phone is HTTP only | N/A — use Pigasus / browser |
| **Quest browser** (index link, `#t=`) | Works for dense-filled regions | Works (**build 173+** — skip broken faststart remux from 171–172) |

**In-progress export on Quest:** use **Pigasus** with `http://<ip>:8765/pcld_ios_media/_working.mp4` (or the LAN index link with `#t=` resume).

### Skybox (Quest) and the phone LAN

**pCloud** in Skybox still uses **pCloud WebDAV** (unchanged).

**Phone LAN** is **HTTP only** — do not add it as a WebDAV server in Skybox. Prefer **Pigasus** or the **Quest browser** with direct URLs (`http://<ip>:8765/pcld_ios_media/loop/op_00.mp4`).

**Reliable paths:**

- **Full movie on pCloud** — pCloud WebDAV in Skybox (same as today).
- **Phone export files** — Pigasus / browser, or copy to a PC folder indexed by DLNA.

**PC test (HTTP only):**

```powershell
cd windows
.\Set-LoopSegmentsLANHost.ps1 10.0.100.10
.\Mount-LoopSegmentsRclone.ps1 -TestOnly
```

Expect `GET status.json` and `GET /` OK. There is no PROPFIND or rclone mount to the phone on current builds.

### Export transport

| Mode | When | Behavior |
|------|------|----------|
| **Dense fill** (default) | Source **&lt; ~1.5 GB**, or large file **first minute at seek 0** | Sparse temp once; **one dense pCloud download per minute window**; `file://` passthrough → `op_00.mp4` |
| **Remote passthrough** | Sparse temp, minute **not** at file byte 0, source **&lt; ~1.5 GB** or **H.264** | **Capped pCloud reads** → HTTPS → export session; then dense + local if needed. |
| **Large HEVC mid-file** | **≥ ~1.5 GB**, HEVC, minute not at byte 0 (e.g. seek **30:00**) | **Dense-fill ~1 GB window** → **local export session** (remote passthrough skipped; matches seek‑0 minute‑1 success). |
| **Local export session** | Entire source dense on disk (small file or seek‑0 tail fill) | Passthrough via `AVAssetExportSession` on the temp file for every minute |
| **Hybrid (capped)** | Mid-file on **smaller** large sources where custom URL + sparse temp still opens | Head + dense window + MP4 index at EOF; falls back to HTTPS if reader fails |

Export needs enough free space for the sparse shell plus one minute’s dense window (or HTTPS range reads). Check `export_latest.txt` for which path ran.

**Not** a full-file download to the phone and **not** the old ffmpeg stream-export path — still one ~60s segment at a time, still passthrough on device, still LAN/USB to PC.

## Photos library (deactivated in app)

The Photos import sub-workflow is **off** (`PhotosSegmentPublisher.workflowEnabled = false` in source). Re-enable there to restore the export UI and library sync.

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

## Windows sync (LAN → DLNA)

**`Documents/Exports/pcld_ios_media/loop/op_00.mp4` (and `op_01`) are the rotating segment sources; `pcld_ios_media/_working.mp4` is the sparse working copy.**

| Step | PowerShell / action |
|------|------------------------|
| Phone **Exports** → PC | **`http://<ip>:8765/`** in a browser, **`Invoke-WebRequest`**, USB, or **[`../windows/archive/Sync-FromPhoneLAN.ps1`](../windows/archive/Sync-FromPhoneLAN.ps1)**; optional **`../windows/Mount-LoopSegmentsRclone.ps1 -TestOnly`** |
| Manual USB | **Apple Devices** → Loop Segments → Exports → Save to PC |
| rclone+WinFsp to phone (old) | **[`../windows/archive/RCLONE-PHONE-MOUNT-LEGACY.md`](../windows/archive/RCLONE-PHONE-MOUNT-LEGACY.md)** |

```powershell
cd ..\windows
.\Set-LoopSegmentsLANHost.ps1 192.168.1.42
.\Mount-LoopSegmentsRclone.ps1 -TestOnly
# Copy files from the LAN index or use archive\Sync-FromPhoneLAN.ps1 — see WORKFLOW.md
```

Details: [../WORKFLOW.md](../WORKFLOW.md) §3, [../FEASIBILITY.md](../FEASIBILITY.md).
