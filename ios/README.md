https://github.com/dsouzaankit/ios_3d_loop_segments/actions/workflows/ios-build.yml

# read-only webdav windows setup (failing)
# prefer Skybox webdav <admin, iosadmin>
cd P:\all_scripts\ios_3d_loop_segments\windows
# onetime pwsh admin
Start-Process pwsh -Verb RunAs -ArgumentList "-NoExit", "-Command", "Set-Location '$PWD'"
.\Set-LoopSegmentsLANHost.ps1 10.0.100.10   # your phone IP
.\Map-LoopSegmentsWebDAV.ps1 -ConfigureWebClient   # once, admin, if mapping fails
.\Map-LoopSegmentsWebDAV.ps1
.\Map-LoopSegmentsWebDAV.ps1 -ViaPort80Proxy

cd P:\all_scripts\ios_3d_loop_segments\windows
.\Set-LoopSegmentsDestination.ps1 'D:\ios\loop_segs_out'
.\Set-LoopSegmentsLANHost.ps1 10.0.100.10
.\Sync-FromPhoneLAN.ps1 -Discover
.\Sync-FromPhoneLAN.ps1 -Watch

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
- 60s segments; phone keeps **one** file (`op_00.mp4`); PC DLNA pair via **`Sync-FromPhoneLAN.ps1 -Watch`** (build 103+) or USB. **Dense fill** per minute is the default (sparse temp shell, not a full 17 GB copy); see transport table below for large-file exceptions.
- Real-time read pacing (like ffmpeg `-re`); segments cut at **keyframes** (~60s target, not strict wall-clock grid)
- Runs until end of file or **Stop**; **per-minute failsafe** (build 130+) skips a failed minute and continues dense-filling `_export_source_working.mp4` (kept on disk and LAN until the next export replaces it)

Implementation: `LoopSegments/Services/Export/SegmentExporter.swift`

## PC sync (primary — LAN)

1. On the phone: **Serve Exports on Wi‑Fi** (export screen; stays on while the app is open).
2. On the PC (same LAN):

```powershell
cd ..\windows
.\Set-LoopSegmentsLANHost.ps1 192.168.1.42   # IP from export log
.\Sync-FromPhoneLAN.ps1 -Watch
```

pCloud can stay on **cellular** while the LAN server serves `Documents/Exports/` on port **8765** (`op_00.mp4`, logs, and `_export_source_working.mp4` from the last export until a new one overwrites it). **Browser playback:** use `op_00.mp4` (full segment). `_export_source_working.mp4` is a sparse partial copy — browsers often hang on **5K+**; use VLC, ffplay, or `Sync-FromPhoneLAN.ps1` (build **145+** adds HTTP **Range** so browsers can seek without downloading the whole file).

### SMB vs WebDAV (network folder on PC)

**True SMB** (`\\phone\share`) is **not** possible on iOS: there is no supported in-app SMB server API, and embedding one would be large, fragile, and a poor fit for the sandbox.

**WebDAV** on the same port (**8765**, build **146+**) is the supported alternative — Windows can map a drive letter:

```powershell
.\Set-LoopSegmentsLANHost.ps1 192.168.1.42
.\Map-LoopSegmentsWebDAV.ps1 -ConfigureWebClient   # once per PC (admin): WebClient + AuthForwardServerList
.\Map-LoopSegmentsWebDAV.ps1 -TestOnly             # HTTP + PROPFIND check before mapping
.\Map-LoopSegmentsWebDAV.ps1                       # maps L: to http://<phone>:8765/
```

Read-only; phone must stay on the LAN with **Serve Exports** enabled. For hands-off DLNA copy, keep using **`Sync-FromPhoneLAN.ps1 -Watch`**.

### Quest LAN playback (Skybox vs Pigasus)

**pCloud WebDAV in Skybox** = full **HTTPS** files on pCloud’s server (what already works for you).

**Phone LAN** (`http://<ip>:8765`) = plain HTTP + optional WebDAV for the export folder. Players differ:

| Player | `_export_source_working.mp4` (sparse) | `op_00.mp4` (segment) |
|--------|----------------------------------------|------------------------|
| **Pigasus** (direct URL / network file) | **Works** — uses HTTP **Range** (head + `moov` tail + dense minutes) | Should work |
| **Skybox WebDAV** | Usually **fails** | Often **“too large to decode”** on 5K HEVC; use Pigasus/PC |
| **Quest browser** (index link, `#t=`) | Works for dense-filled regions | Works (**build 173+** — skip broken faststart remux from 171–172) |

**In-progress export on Quest:** use **Pigasus** with the URL from the phone export log, e.g. `http://10.0.100.10:8765/_export_source_working.mp4` (or open the LAN index in the browser and tap that file — adds `#t=` resume). No WebDAV setup required.

### Skybox (Quest) WebDAV

Skybox over **WebDAV** on the phone is best-effort (not the same code path as Pigasus’s HTTP streaming).

| | pCloud WebDAV | Loop Segments LAN |
|--|----------------|-------------------|
| Transport | **HTTPS** | **HTTP** (port 8765) |
| Files | Full originals on cloud | `op_00.mp4` (~60s segment), sparse `_export_source_working.mp4` |
| Server | Mature WebDAV | Minimal in-app server |

**Skybox on phone LAN:** install **build 173+** (restores playable `op_00.mp4` on browser/Pigasus; **172** WebDAV listing). Skybox may still refuse **5K+ HEVC** segments (“video too large to decode”) even when the file is valid — use **Pigasus** or **PC SMB** for phone exports. For **`_export_source_working.mp4`**, use **Pigasus** or the browser index, not Skybox WebDAV.

1. Phone: **Serve Exports on Wi‑Fi** on, app **in foreground**, same Wi‑Fi as Quest.
2. Skybox → **Add WebDAV server** → `http://10.0.100.10:8765/` · `admin` / `iosadmin`.
3. Prefer **`op_00.mp4` in Pigasus** (`http://<ip>:8765/op_00.mp4`) after export publishes a **new** segment on **173+**.

**Reliable Skybox paths (same as pCloud-quality playback):**

- **Full movie on pCloud** — use pCloud WebDAV in Skybox (what already works for you).
- **Phone export segment** — `Sync-FromPhoneLAN.ps1 -Watch` on PC, then Skybox → **SMB** to the PC folder (Skybox handles SMB well), or Skybox PC client copy.

**PC test:**

```powershell
cd windows
.\Set-LoopSegmentsLANHost.ps1 10.0.100.10
.\Map-LoopSegmentsWebDAV.ps1 -TestOnly
```

Expect `PROPFIND 207`, `GET op_00.mp4` **206 without auth**, and **`moov atom in first 768 KB`**.

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

**`Documents/Exports/op_00.mp4` is the full-quality DLNA source on the phone.**

| Step | PowerShell |
|------|------------|
| Phone **Exports** → PC | **`Sync-FromPhoneLAN.ps1 -Watch`** (Wi‑Fi, port **8765**; **Serve Exports on Wi‑Fi** on) |
| Manual USB | **Apple Devices** → Loop Segments → Exports → Save to PC (pick DLNA folder) |

```powershell
cd ..\windows
.\Set-LoopSegmentsDestination.ps1 'F:\f1_media\3d_fullsbs_trans'   # once
.\Set-LoopSegmentsLANHost.ps1 192.168.1.42   # IP from export log
.\Sync-FromPhoneLAN.ps1 -Discover
.\Sync-FromPhoneLAN.ps1 -Watch
```

Details: [../WORKFLOW.md](../WORKFLOW.md) §3, [../FEASIBILITY.md](../FEASIBILITY.md).
