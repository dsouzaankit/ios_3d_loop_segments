# Loop Segments (iOS)

**Cellular → pCloud WebDAV → segment export → USB → PC DLNA.** See [../WORKFLOW.md](../WORKFLOW.md). On **iOS 26.x**, build **1.0.5+** launches without embedded FFmpeg; export is stubbed until a compatible library is added.

## Open in Xcode (requires macOS or cloud CI)

**Option A — XcodeGen**

```bash
cd ios
brew install xcodegen   # on macOS
xcodegen generate
open LoopSegments.xcodeproj
```

SPM resolves **ffmpeg-kit-spm** (`FFmpeg-Kit` product) from [project.yml](project.yml).

**Option B — manual**

1. New iOS App (SwiftUI, iOS 17+).
2. Add all files under `LoopSegments/`.
3. **File → Add Package Dependencies** → `https://github.com/tylerjonesio/ffmpeg-kit-spm` → product **FFmpeg-Kit**.
4. Merge [LoopSegments/Resources/Info.plist](LoopSegments/Resources/Info.plist) keys.

## ffmpeg-kit

`FFmpegRunner.swift` calls:

```text
FFmpegKit.execute(withArgumentsAsync: …)
```

with the same arguments as `Run-SegmentCopy.ps1` (`-re`, `-c copy`, `-f segment`, `-segment_wrap 2`, `3d_op_%02d.mkv`).

The bundled **min** SPM binaries may omit some muxers. If export fails with “Unknown format” / missing segment muxer, switch to a **full** ffmpeg-kit XCFramework in `project.yml` (see [ffmpeg-kit-spm releases](https://github.com/tylerjonesio/ffmpeg-kit-spm/releases) or a maintained fork).

## No Mac on your desk

[BUILD-WITHOUT-MAC.md](BUILD-WITHOUT-MAC.md) — Codemagic / GitHub Actions using [../codemagic.yaml](../codemagic.yaml).

## Windows sync

After export, on PC:

```powershell
..\windows\Sync-IphoneSegments.ps1 -WaitForDevice
```
