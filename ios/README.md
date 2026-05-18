https://github.com/dsouzaankit/ios_3d_loop_segments/actions/workflows/ios-build.yml

PS P:\all_scripts\ios_3d_loop_segments\windows> .\Set-LoopSegmentsDestination.ps1 'C:\Users\dsouzaankit\Downloads\ios_3d_out'
PS P:\all_scripts\ios_3d_loop_segments\windows> .\Sync-FromIPhonePhotos-Watch.cmd
PS P:\all_scripts\ios_3d_loop_segments\windows> .\Sync-FromIPhonePhotos.ps1

Notes:
phone should be unlocked, app on foreground, screen on!


# Loop Segments (iOS)

**Cellular → pCloud WebDAV → segment export → USB → PC DLNA.** See [../WORKFLOW.md](../WORKFLOW.md).

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
- 60s segments; phone keeps **one** file (`3d_op_00.mp4`); PC DLNA pair via `Sync-FromIPhonePhotos.ps1` (build 92+). **Build 93+:** Photos on = **dense fill** per minute (not pCloud stream export).
- Real-time read pacing (like ffmpeg `-re`)
- Runs until end of file or **Stop**

Implementation: `LoopSegments/Services/Export/SegmentExporter.swift`

## Photos library (optional — not required for DLNA)

**Save segments to Photos** copies each finished segment into the **Loop Segments** album for PC import via Apple Devices / `Sync-FromIPhonePhotos.ps1`. This path is **optional**.

When **Photos is on** (default), export **dense-fills** each minute to sparse temp, passthroughs to **`3d_op_00.mp4`**, then imports to Photos (**PC MTP** often shows `IMG_*.mp4` under `202605_a`). First segment is slower than stream-export but more reliable on large moov-at-end HEVC. **`Sync-FromIPhonePhotos.ps1 -Watch`** copies the **newest** clip to the **older** of `3d_op_00` / `3d_op_01` on the PC. Low disk may still force pCloud stream (see export log).

| | **Exports (`3d_op_*.mp4`)** | **Photos import** |
|---|---------------------------|-------------------|
| Purpose | USB → PC → DLNA (primary) | Convenience / MTP script |
| Codec / resolution | Full **passthrough** HEVC or H.264 from source | Passthrough remux first; on **3302** → **H.264 transcode** (up to 1080p preset) for Photos only — **DLNA file never re-encoded** |
| Reliability | Reliable once export finishes | HEVC passthrough may need H.264 fallback (slower, 1–3 min/segment) |

**Photos 3302:** iOS often rejects programmatic import of **high‑resolution HEVC** (`PHPhotosErrorDomain` **3302**). The app then **transcodes to H.264** for the Photos copy only; `3d_op_00.mp4` in Exports stays full passthrough for DLNA. USB can also use **Files → Exports** without Photos. See [Apple HEVC support](https://support.apple.com/en-qa/116944).

Turn **Save segments to Photos** off only if you do not need MTP/USB sync to PC (dense fill still runs; no Photos import).

### Export transport (build 93+)

| Mode | When | Behavior |
|------|------|----------|
| **Dense + Photos** (default) | Photos toggle **on** | Sparse temp shell once; **one dense pCloud download per minute**; passthrough → `3d_op_00.mp4` → Photos import |
| **Dense, no Photos** | Photos toggle **off** | Same dense fill; no library import (use Exports if PC can see it) |
| **pCloud stream** | Very low free disk | Fallback only — see `export_latest.txt` |

No background prefetch + duplicate dense fill on the same minute (removed in build 93).

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
| Live ~60s segment refresh on PC | **No** via USB — use sibling repo **`Run-SegmentCopy.ps1`** (pCloud → PC) or a future LAN pull from the phone |

`Sync-IphoneSegments.ps1` only helps if Explorer shows a **readable** iPhone `…\Loop Segments\Exports` path. **`Sync-FromIPhonePhotos.ps1 -Watch`** is the Photos/MTP path when Apple Devices is unavailable: newest phone clip → older PC DLNA slot.

Details: [../WORKFLOW.md](../WORKFLOW.md) §3, [../FEASIBILITY.md](../FEASIBILITY.md).

After a manual Apple Devices save into an incoming folder:

```powershell
cd ..\windows
.\Copy-FromIncoming.ps1
```
