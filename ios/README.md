https://github.com/dsouzaankit/ios_3d_loop_segments/actions/workflows/ios-build.yml

PS P:\all_scripts\ios_3d_loop_segments\windows> .\Set-LoopSegmentsDestination.ps1 'C:\Users\dsouzaankit\Downloads\ios_3d_out'
PS P:\all_scripts\ios_3d_loop_segments\windows> .\Sync-FromIPhonePhotos-Watch.cmd
PS P:\all_scripts\ios_3d_loop_segments\windows> .\Sync-FromIPhonePhotos.ps1


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
- Passthrough to MP4 when supported: H.264, HEVC, AV1 + AAC
- 60s segments, two-file rotate (`3d_op_00` / `3d_op_01`)
- Real-time read pacing (like ffmpeg `-re`)
- Runs until end of file or **Stop**

Implementation: `LoopSegments/Services/Export/SegmentExporter.swift`

## No Mac on your desk

[BUILD-WITHOUT-MAC.md](BUILD-WITHOUT-MAC.md) — GitHub Actions / Codemagic.

## Windows sync

After export, on PC:

```powershell
..\windows\Sync-IphoneSegments.ps1 -WaitForDevice
```
