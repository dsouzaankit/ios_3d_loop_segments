# Loop Segments FFmpeg (experimental)

Separate iOS app that exports **two rotating 60s MP4 segments** using embedded **FFmpeg** (not AVFoundation).

The production app lives in [../ios](../ios) (AVFoundation; no embedded FFmpeg — required for **iOS 26** launch stability).

## Why not ffmpeg-kit?

[FFmpegKit](https://github.com/arthenica/ffmpeg-kit) was **retired January 2025** (binaries removed from registries). Wrappers such as `codewithtamim/ffmpeg-kit-spm` only repackage the same discontinued stack. This project uses **[kewlbear/FFmpeg-iOS](https://github.com/kewlbear/FFmpeg-iOS)** instead: prebuilt libav + **fftools** (`ffmpeg` CLI) via `FFmpegSupport`, LGPL.

Trade-offs vs old ffmpeg-kit:

| | ffmpeg-kit (retired) | FFmpeg-iOS (this project) |
|--|----------------------|---------------------------|
| Maintenance | None | Community package (last binary drop ~2023) |
| API | `FFmpegKit.execute` + log callbacks | `ffmpeg([String])` → exit code |
| Cancel mid-run | `FFmpegKit.cancel()` | **No** — Stop is honored after the current `ffmpeg()` returns |
| Live export log in app | Yes | Command + exit code in `export_latest.txt`; details in Xcode console |

## Behavior

Same workflow as the main app ([../WORKFLOW.md](../WORKFLOW.md)): pCloud WebDAV → `3d_op_00.mp4` / `3d_op_01.mp4` in Documents/Exports → USB → PC DLNA.

Export argv (see shared `SegmentCopyCommand.swift`): `-ss`, `-re`, `-headers`, `-c copy`, `-f segment -segment_time 60 -segment_wrap 2`.

## Open in Xcode

```bash
cd ios-ffmpeg
brew install xcodegen   # macOS
xcodegen generate
open LoopSegmentsFFmpeg.xcodeproj
```

- **Bundle ID:** `com.loopsegments.ffmpeg`
- **SPM:** `FFmpeg-iOS` from `kewlbear/FFmpeg-iOS` ≥ `0.0.6-b`

## iOS 26 warning

Embedded FFmpeg **crashed at launch** with ffmpeg-kit on iOS 26 (removed from main app in v1.0.5). This build still loads large native libraries; FFmpeg is only invoked when export starts (`lazy` runner). **Verify on your device** before relying on it.

## CI

[ios-ffmpeg-build.yml](../.github/workflows/ios-ffmpeg-build.yml) — simulator smoke build.

## Shared code

Most pCloud/WebDAV UI is compiled from [../ios/LoopSegments](../ios/LoopSegments) (AVFoundation export stack excluded). FFmpeg-specific code is under `LoopSegmentsFFmpeg/`.
