https://github.com/dsouzaankit/ios_3d_loop_segments/actions/workflows/ios-build.yml

cd P:\all_scripts\ios_3d_loop_segments\windows
Copy-Item loop-segments-windows.example.json loop-segments-windows.json   # once per PC
.\Set-LoopSegmentsWindows.ps1 -PhoneHost 10.0.100.10
.\Mount-LoopSegmentsRclone.ps1 -TestOnly   # optional LAN probe; PC rclone drive mount is optional/sluggish — see ../windows/archive/RCLONE-PHONE-MOUNT-LEGACY.md
# Skybox (Quest): Add WebDAV → http://<phone-ip>:8765/ (IP from Export screen) · admin / iosadmin — see “Quest LAN playback” below

Notes:
LAN sequential prefetch from playback start (toward EOF if &lt;29 Mbps est., else exported+2 min horizon).
_working.mp4 is streamable only when seek=0:00!
Av1 is not supported, prefer h.265!
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
- 60s segments; phone alternates **`pcld_ios_media/loop/op_00.mp4`** / **`pcld_ios_media/loop/op_01.mp4`**; sparse in-progress copy **`pcld_ios_media/_working.mp4`**. **LAN:** **`http://<phone-ip>:8765/`** serves **HTTP** (files, index, Range) **and WebDAV** (PROPFIND / listings for Skybox, Windows clients). **Quest Skybox:** add **WebDAV** with **`admin` / `iosadmin`**. **PC:** browser / `Invoke-WebRequest` / **[`../windows/archive/Sync-FromPhoneLAN.ps1`](../windows/archive/Sync-FromPhoneLAN.ps1)**; optional **[`rclone`](../windows/archive/RCLONE-PHONE-MOUNT-LEGACY.md)** mount to a drive letter can feel **sluggish** — not required if Skybox talks to the phone directly. **Dense fill** per minute is the default.
- **Recovery when sparse probe fails:** probes **via pCloud before** creating `_working.mp4` when not resuming a paused sparse export; abandons any stale sparse shell when vanilla/HLS starts; LAN hides `_working.mp4` while `_vanilla_download.*` is active. (1) **Vanilla WebDAV download** first if enabled (default on; **no API token** — works when `gethlslink` fails) → **`_vanilla_download.<ext>`**; MP4/MOV/M4V also **`_vanilla_faststart.mp4`**; (2) **pCloud HLS** only if vanilla is off or failed and estimated bitrate is above the **HLS cutoff** → **`_working_pcloud_transcode.mp4`**. Browser shows **WMV** and **TS** in the file list.
- Real-time read pacing (like ffmpeg `-re`); segments cut at **keyframes** (~60s target, not strict wall-clock grid)
- Runs until end of file, **Pause** (checkpoint + files kept), or **Stop** (clears paused state, removes `op_*.mp4`); **per-minute failsafe** skips a failed minute and continues dense-filling **`_working.mp4`**

Implementation: `LoopSegments/Services/Export/SegmentExporter.swift`

## PC sync (LAN — HTTP + WebDAV)

1. On the phone: **Serve Exports on Wi‑Fi** (export screen; app open on LAN).
2. **URLs:** **`http://<phone-ip>:8765/`** (from Export screen — best on **Windows**) or **`http://<iphone-name>.local:8765/`** (mDNS; same as **Settings → General → About → Name**). Bonjour advertises service **`loopsegments._http._tcp`**, not hostname `loopsegments.local`. HTML index, **`status.json`**, **GET**/**HEAD** with **Range**, plus **WebDAV** (PROPFIND, LOCK, etc.).
3. **Skybox on Quest:** WebDAV root above, Basic auth **`admin` / `iosadmin`** (same as in code). **PC DLNA:** usually copy or sync into a local folder; mounting the phone with **`rclone`** is **optional** and often **slow** vs playing from Skybox or using direct HTTP links — see [`../windows/archive/RCLONE-PHONE-MOUNT-LEGACY.md`](../windows/archive/RCLONE-PHONE-MOUNT-LEGACY.md).

Unattended **pCloud → PC** (no phone LAN): **`Run-SegmentCopy.ps1`** in the sibling **`3d_loop_segments`** repo.

LAN serves **`pcld_ios_media/**`** automatically (all video extensions on disk — `op_*.mp4`, `_working*.mp4`, `_vanilla_*`, faststart copies, WMV/MKV, etc.). **Excluded:** `*.staging.*`, `*.sparse.json`, hidden/temp remux files. **`_vanilla_download.<ext>`** is listed and served **while the WebDAV download runs** (growing file); MP4/MOV/M4V also refresh **`_vanilla_faststart.mp4`** every 25% during download. Root **logs** (`export_latest.txt`, …) stay allowlisted; **`search_debug.txt`** and **`export_session_*`** are not served. Port **8765**. **Browser / Pigasus / Skybox WebDAV:** same tree; **`#t=`** on the index handles resume for `_working` (clears after a finished export).

**Windows / `.local`:** **`http://iphone.local:8765/` usually fails** — that hostname only exists if About → Name is literally “iPhone” (otherwise it is e.g. `http://johns-iphone.local:8765/`). Windows often does not resolve any `.local` name without [Apple Bonjour](https://support.apple.com/kb/DL999). Use the **LAN IP** from Export (`http://10.x.x.x:8765/`). Test: `cd windows` → `.\Set-LoopSegmentsLANHost.ps1 <ip>` → `.\Mount-LoopSegmentsRclone.ps1 -TestOnly`.

### `_working.mp4`: browser scrubber vs export logs

`_working.mp4` is **sparse**: the file size and MP4 index at EOF make the browser **scrubber show the full movie duration** (you can drag near the end) even when most of the middle is still empty. **Only dense byte spans** play on LAN — not the scrubber position alone. **Serve Exports on:** no `op_*.mp4` segments — LAN serves `_working.mp4`, `_vanilla_download.*`, or transcode copy only. **Serve Exports off:** 60s segments export to `loop/op_*.mp4`. **Sequential LAN prefetch** fills `_working.mp4` toward EOF. Prefetch cutoff (default ~29 Mbps) applies only when Serve Exports is **off** (below cutoff → LAN preload only on sparse path). Each dense fill pauses prefetch briefly. **Seek &gt; 0:** prefetch from the seek byte offset; dense **first ~2 min at seek** on preload. Export logs and **`http://&lt;phone-ip&gt;:8765/`** show **`LAN playable till 12:34, exported 11:00, started 10:00`** (max contiguous dense playback from the seek in file timeline; also in `status.json`). LAN only serves dense bytes — not the scrubber alone.

Export logs with **`@ X Mbps`** mean a **pCloud** range read (dense fill or, for mid-file minutes, passthrough while the window is not dense yet). After a minute is dense on `_working.mp4`, the app uses **disk passthrough** for that segment (no second pCloud read for the same window). **Pause** keeps checkpoint + files; **Stop** clears paused state and removes published `op_*.mp4`.

### SMB vs HTTP / WebDAV on the phone

**True SMB** is not available. The app serves **HTTP + WebDAV** on **8765** (not a Windows file share). Mapped-drive / PROPFIND clients use **WebDAV**; browsers use **GET** on file URLs and the HTML index. Legacy **`net use`** notes and **PC rclone** script live under [`../windows/archive/`](../windows/archive/).

| File | HTTP/WebDAV URL | Skybox via PC DLNA |
|------|--------------------------------------|---------------------|
| `pcld_ios_media/loop/op_00.mp4`, `pcld_ios_media/loop/op_01.mp4` | Yes | Usually OK |
| `pcld_ios_media/_working.mp4` | Yes | May work (like VLC); sparse holes can break some servers |
| `pcld_ios_media/_working_pcloud_transcode.mp4` | Yes | HLS transcode in progress (not original WMV/MKV) |
| `pcld_ios_media/_vanilla_download.*` | Yes | Full dense copy (e.g. `.wmv`); Pigasus / Skybox HTTP |
| `pcld_ios_media/_vanilla_faststart.mp4` | Yes | Faststart MP4 sidecar when vanilla backup ran on MP4 |

### Quest LAN playback (Skybox vs Pigasus)

**pCloud WebDAV in Skybox** = full **HTTPS** files on pCloud’s server (what already works for you).

**Phone LAN** (`http://<ip>:8765`) = **HTTP + WebDAV** (same export tree). Players differ:

| Player | `pcld_ios_media/_working.mp4` (sparse) | `pcld_ios_media/loop/op_00.mp4` (segment) |
|--------|----------------------------------------|------------------------|
| **Pigasus** (direct URL / network file) | **Works** — uses HTTP **Range** | Should work |
| **Skybox (WebDAV to phone)** | Often **works** for LAN export (app serves WebDAV + Basic auth) | **5K+ HEVC** may still show “too large to decode”; try segments or Pigasus |
| **Quest browser** (index link, `#t=`) | Works for dense-filled regions | Works (**build 173+** — skip broken faststart remux from 171–172) |

**In-progress export on Quest:** **Skybox** → Add WebDAV server → `http://<ip>:8765/` · **`admin` / `iosadmin`**, or **Pigasus** / browser with direct URLs.

### Skybox (Quest) and the phone LAN

**pCloud** in Skybox uses **pCloud WebDAV** (unchanged).

**Phone** in Skybox: add **WebDAV** with base URL **`http://<ip>:8765/`** and **`admin` / `iosadmin`**. That uses the app’s **LAN WebDAV** implementation (not plain SMB).

**Reliable paths:**

- **Full movie on pCloud** — pCloud WebDAV in Skybox.
- **Phone export** — Skybox WebDAV to the phone, **Pigasus** / browser HTTP URLs, or copy to a PC folder for DLNA.

**PC test:**

```powershell
cd windows
.\Set-LoopSegmentsLANHost.ps1 10.0.100.10
.\Mount-LoopSegmentsRclone.ps1 -TestOnly
```

Expect **GET** **`status.json`** and index **`/`** OK. **`rclone`** drive mapping is optional and may be **slow**; see [`../windows/archive/`](../windows/archive/).

### Export transport

| Mode | When | Behavior |
|------|------|----------|
| **Dense fill** (default) | Source **&lt; ~1.5 GB**, or large file **first minute at seek 0** | Sparse temp once; **one dense pCloud download per minute window**; `file://` passthrough → `op_00.mp4` |
| **Remote passthrough** | Sparse temp, minute **not** at file byte 0, window **not** dense on `_working.mp4` yet | **Capped pCloud reads** → HTTPS → export session; then dense + local if needed. |
| **Local passthrough (mid-file)** | Minute window already **dense** on `_working.mp4` (head + index tail on disk) | Segment cut from **disk** — no second pCloud read for that minute |
| **Large HEVC mid-file** | **≥ ~1.5 GB**, HEVC, minute not at byte 0 (e.g. seek **30:00**) | **Dense-fill ~1 GB window** → **local export session** (remote passthrough skipped; matches seek‑0 minute‑1 success). |
| **Local export session** | Entire source dense on disk (small file or seek‑0 tail fill) | Passthrough via `AVAssetExportSession` on the temp file for every minute |
| **Hybrid (capped)** | Mid-file on **smaller** large sources where custom URL + sparse temp still opens | Head + dense window + MP4 index at EOF; falls back to HTTPS if reader fails |
| **Vanilla download** | Sparse probe fails; toggle on (default) | WebDAV **full file from 0:00** → **`_vanilla_download.<ext>`**; **60s segments** only when Serve Exports is **off** and source is not already faststart; LAN **`#t=`** on index for export seek |
| **pCloud HLS transcode** | Vanilla off/failed; above **HLS cutoff** | `gethlslink` (API token) → **`_working_pcloud_transcode.mp4`** + segments |

Export needs enough free space for the sparse shell plus one minute’s dense window (or HTTPS range reads). **Vanilla backup** needs space for the **entire** source file (plus **`_vanilla_faststart.mp4`** for MP4). Check `export_latest.txt` for which path ran.

Default export is still **one ~60s segment at a time** with passthrough on device (not ffmpeg on phone). Vanilla is an **optional full-file** fallback, not the normal path.

### Faststart remux (on phone)

**Faststart** = MP4 with **`moov` at the file head** (network-friendly layout) via `AVAssetExportSession` passthrough + `shouldOptimizeForNetworkUse` — **no re-encode**, container rearrange only (`MP4NetworkOptimize.swift`).

| Output | When |
|--------|------|
| **`loop/op_00.mp4`**, **`op_01.mp4`** | After each segment is written, if `moov` is still at EOF (Skybox / LAN players) |
| **`_vanilla_faststart.mp4`** | Only if **`_vanilla_download.mp4`** has moov-at-end; skipped when download already faststart |

**Pre-faststarting files on pCloud** (ffmpeg before upload) is optional for “play full movie from pCloud WebDAV”; it does **not** fix WMV probe failures, doubles handling if you remux after upload, and invalidates in-progress sparse resume if you replace the cloud object. The app keeps cloud originals untouched.

### Export screen settings (LAN section)

| Setting | Default | Effect |
|---------|---------|--------|
| **Prefetch to EOF when below** | 29 Mbps | LAN sparse preload horizon vs segment export |
| **pCloud HLS if WebDAV fails above** | 2.5 Mbps (1×) | Minimum estimated source bitrate for HLS fallback (0.25× / 0.5× / 2× / 4×) |
| **Vanilla download first (before HLS)** | On | Full WebDAV download before `gethlslink`; HLS only if vanilla fails |

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
| rclone+WinFsp mount on PC (optional; can be sluggish) | **[`../windows/archive/RCLONE-PHONE-MOUNT-LEGACY.md`](../windows/archive/RCLONE-PHONE-MOUNT-LEGACY.md)** — Skybox WebDAV to the phone does not need this |

```powershell
cd ..\windows
.\Set-LoopSegmentsLANHost.ps1 192.168.1.42
.\Mount-LoopSegmentsRclone.ps1 -TestOnly
# Copy files from the LAN index or use archive\Sync-FromPhoneLAN.ps1 — see WORKFLOW.md
```

Details: [../WORKFLOW.md](../WORKFLOW.md) §3, [../FEASIBILITY.md](../FEASIBILITY.md).
