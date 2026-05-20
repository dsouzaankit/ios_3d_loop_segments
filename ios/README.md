https://github.com/dsouzaankit/ios_3d_loop_segments/actions/workflows/ios-build.yml

cd P:\all_scripts\ios_3d_loop_segments\windows
Copy-Item loop-segments-windows.example.json loop-segments-windows.json   # once per PC
.\Set-LoopSegmentsWindows.ps1 -PhoneHost 10.0.100.10
.\Mount-LoopSegmentsRclone.ps1 -TestOnly
.\Mount-LoopSegmentsRclone.ps1          # mount drive from json (default L:)
# Skybox PC / DLNA: index <drive>\pcld_ios_media\ — see [windows/README.md](../windows/README.md)

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
- 60s segments; phone alternates **`pcld_ios_media/loop/op_00.mp4`** / **`pcld_ios_media/loop/op_01.mp4`**; sparse in-progress copy **`pcld_ios_media/_working.mp4`**. PC: **`Mount-LoopSegmentsRclone.ps1`** maps the whole folder. **Dense fill** per minute is the default.
- Real-time read pacing (like ffmpeg `-re`); segments cut at **keyframes** (~60s target, not strict wall-clock grid)
- Runs until end of file or **Stop**; **per-minute failsafe** skips a failed minute and continues dense-filling **`_working.mp4`**

Implementation: `LoopSegments/Services/Export/SegmentExporter.swift`

## PC sync (primary — rclone mount)

1. On the phone: **Serve Exports on Wi‑Fi** (export screen; app open on LAN).
2. On the PC: install **WinFsp** + **rclone**, then:

```powershell
cd ..\windows
.\Set-LoopSegmentsWindows.ps1 -PhoneHost 192.168.1.42   # once per PC (or -Show to verify)
.\Mount-LoopSegmentsRclone.ps1 -TestOnly
.\Mount-LoopSegmentsRclone.ps1               # keeps running — whole Exports on mount drive
```

3. Point **Skybox PC** / your DLNA library at the mount:
   - **`L:\pcld_ios_media\`** — anchor folder **\_working.mp4** plus **`loop\`** ( **`op_00` / `op_01`** for playlist/folder looping).
   - **`L:\`** — whole Exports folder (logs, `export_latest.txt`, etc.).

The mount exposes **everything** under `Documents/Exports/`. Index **`L:\pcld_ios_media\`** for a clear DLNA tree (`loop\` vs working file); index **`L:\pcld_ios_media\loop\`** alone if the player should loop only the alternating segments.

**`_working.mp4` on Skybox:** VLC on iOS plays it over plain HTTP with **Range** on dense-filled minutes only (same server rules). Skybox over **PC DLNA** may work too — especially with rclone **`--vfs-cache-mode full`** — but some DLNA servers choke on sparse “full size” files. Worth trying if you index `L:\`; if it stutters or fails, use **Pigasus** on Quest (`http://<ip>:8765/pcld_ios_media/_working.mp4`) or index **`L:\pcld_ios_media\`**.

Legacy copy / `net use` scripts: [`../windows/archive/`](../windows/archive/).

LAN serves `pcld_ios_media/loop/op_*.mp4`, `pcld_ios_media/_working.mp4`, and logs on port **8765**. **Browser / Pigasus:** `pcld_ios_media/loop/op_00.mp4` for segments; `pcld_ios_media/_working.mp4` for the working file (`#t=` on the index clears after a finished export so it is not stuck on an old seek).

### SMB vs WebDAV on the phone

**True SMB** on the iPhone is not available. The app serves **HTTP + WebDAV** on port **8765**. On Windows use **`Mount-LoopSegmentsRclone.ps1`** (WinFsp + rclone), not `net use` (often fails on :8765). Archived: [`../windows/archive/Map-LoopSegmentsWebDAV.ps1`](../windows/archive/Map-LoopSegmentsWebDAV.ps1).

| File | On mount `L:\` | Skybox via PC DLNA |
|------|----------------|---------------------|
| `pcld_ios_media/loop/op_00.mp4`, `pcld_ios_media/loop/op_01.mp4` | Yes | Usually OK |
| `pcld_ios_media/_working.mp4` | Yes | May work (like VLC); sparse holes can break some servers |

### Quest LAN playback (Skybox vs Pigasus)

**pCloud WebDAV in Skybox** = full **HTTPS** files on pCloud’s server (what already works for you).

**Phone LAN** (`http://<ip>:8765`) = plain HTTP + optional WebDAV for the export folder. Players differ:

| Player | `pcld_ios_media/_working.mp4` (sparse) | `pcld_ios_media/loop/op_00.mp4` (segment) |
|--------|----------------------------------------|------------------------|
| **Pigasus** (direct URL / network file) | **Works** — uses HTTP **Range** (head + `moov` tail + dense minutes) | Should work |
| **Skybox WebDAV** | Usually **fails** | Often **“too large to decode”** on 5K HEVC; use Pigasus/PC |
| **Quest browser** (index link, `#t=`) | Works for dense-filled regions | Works (**build 173+** — skip broken faststart remux from 171–172) |

**In-progress export on Quest:** use **Pigasus** with `http://<ip>:8765/pcld_ios_media/_working.mp4` (or the LAN index link with `#t=` resume). No WebDAV setup required.

### Skybox (Quest) WebDAV

Skybox over **WebDAV** on the phone is best-effort (not the same code path as Pigasus’s HTTP streaming).

| | pCloud WebDAV | Loop Segments LAN |
|--|----------------|-------------------|
| Transport | **HTTPS** | **HTTP** (port 8765) |
| Files | Full originals on cloud | `pcld_ios_media/loop/op_00|01.mp4` (~60s), sparse `pcld_ios_media/_working.mp4` |
| Server | Mature WebDAV | Minimal in-app server |

**Skybox on phone LAN:** build **173+** for playable segments in browser/Pigasus. Skybox may refuse **5K+ HEVC** (“video too large to decode”). For **`pcld_ios_media/_working.mp4`**, use **Pigasus** or the browser index, not Skybox WebDAV.

1. Phone: **Serve Exports on Wi‑Fi** on, app **in foreground**, same Wi‑Fi as Quest.
2. Skybox → **Add WebDAV server** → `http://10.0.100.10:8765/` · `admin` / `iosadmin`.
3. Prefer **`pcld_ios_media/loop/op_00.mp4` in Pigasus** (`http://<ip>:8765/pcld_ios_media/loop/op_00.mp4`) after a new segment publishes.

**Reliable Skybox paths (same as pCloud-quality playback):**

- **Full movie on pCloud** — use pCloud WebDAV in Skybox (what already works for you).
- **Phone export segment** — `Mount-LoopSegmentsRclone.ps1`, DLNA index `L:\pcld_ios_media\`, or Skybox → **SMB** to a local PC folder.

**PC test:**

```powershell
cd windows
.\Set-LoopSegmentsLANHost.ps1 10.0.100.10
.\Mount-LoopSegmentsRclone.ps1 -TestOnly
```

Expect PROPFIND OK and `pcld_ios_media/loop/op_00.mp4` listed. After mount, `L:\pcld_ios_media\_working.mp4` is visible if export has run.

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

| Step | PowerShell |
|------|------------|
| Phone **Exports** → PC | **`Mount-LoopSegmentsRclone.ps1`** (Wi‑Fi, port **8765**; **Serve Exports on Wi‑Fi** on) |
| Manual USB | **Apple Devices** → Loop Segments → Exports → Save to PC |
| Legacy local copy | [`../windows/archive/`](../windows/archive/) (`Sync-FromPhoneLAN.ps1`) |

```powershell
cd ..\windows
.\Set-LoopSegmentsLANHost.ps1 192.168.1.42
.\Mount-LoopSegmentsRclone.ps1
```

Details: [../WORKFLOW.md](../WORKFLOW.md) §3, [../FEASIBILITY.md](../FEASIBILITY.md).
