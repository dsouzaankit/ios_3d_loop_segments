import AVFoundation
import CoreMedia
import Foundation

/// Confirms a local temp file can supply a full passthrough window before we write a segment.
enum SegmentLocalReadiness {
    private static let minVideoSamplesFor60s = 24
    private static let minOutputBytes: Int64 = 512 * 1024

    static func waitUntilReadable(
        fileURL: URL,
        videoFormat: CMFormatDescription,
        rangeStart: CMTime,
        rangeDuration: CMTime,
        totalFileBytes: Int64,
        contiguousBytesOnDisk: () -> Int64,
        bytesRequiredOnDisk: Int64,
        indexTailOnDisk: () -> Bool,
        isCancelled: () -> Bool,
        log: (String) -> Void
    ) async throws {
        let probeFloor = probeMinContiguousBytes(
            totalFileBytes: totalFileBytes,
            bytesRequiredOnDisk: bytesRequiredOnDisk,
            rangeDuration: rangeDuration
        )
        var lastLog = CFAbsoluteTimeGetCurrent()
        var zeroSampleStreak = 0
        while true {
            if isCancelled() { throw SegmentExporterError.cancelled }
            let contiguous = contiguousBytesOnDisk()
            let needOnDisk = max(bytesRequiredOnDisk, probeFloor)
            if contiguous < needOnDisk {
                try await Task.sleep(nanoseconds: 250_000_000)
                continue
            }

            switch await probeWindow(
                fileURL: fileURL,
                rangeStart: rangeStart,
                rangeDuration: rangeDuration
            ) {
            case .ok(let videoSamples):
                if totalFileBytes > 0, contiguous >= totalFileBytes {
                    log("Readiness OK — full temp file on disk (\(formatBytes(contiguous))), \(videoSamples) video samples in window")
                } else if indexTailOnDisk() {
                    log("Readiness OK — \(formatBytes(contiguous)) contiguous + \(videoSamples) video samples (index at EOF)")
                } else {
                    log("Readiness OK — \(videoSamples) video samples in window (\(formatBytes(contiguous)) on disk)")
                }
                return
            case .needsMoreData(let reason):
                if reason.contains("only 0 video samples") {
                    zeroSampleStreak += 1
                } else {
                    zeroSampleStreak = 0
                }
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastLog >= 15 {
                    lastLog = now
                    log("Waiting for clearer source — \(reason) (\(formatBytes(contiguous)) / \(formatBytes(needOnDisk)))")
                }
                if zeroSampleStreak >= 6, contiguous >= needOnDisk {
                    if CodecSupport.isAV1Video(videoFormat) {
                        throw SegmentExporterError.unsupportedCodec(CodecSupport.fourCCString(videoFormat))
                    }
                }
                if zeroSampleStreak >= 8, contiguous >= needOnDisk {
                    log("Readiness: enough bytes on disk but reader still sees 0 samples — waiting for more contiguous download")
                }
                if zeroSampleStreak >= 20, contiguous >= needOnDisk {
                    throw SegmentExporterError.unsupportedCodec(CodecSupport.fourCCString(videoFormat))
                }
            case .failed(let error):
                throw error
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    static func validateOutputFile(at url: URL, log: (String) -> Void) throws {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        guard bytes >= minOutputBytes else {
            throw SegmentExporterError.segmentOutputTooSmall(bytes)
        }
        log("Segment size OK — \(bytes / 1024) KB")
    }

    /// Extra contiguous bytes before trusting AVAssetReader on sparse moov-at-EOF temp files.
    private static func probeMinContiguousBytes(
        totalFileBytes: Int64,
        bytesRequiredOnDisk: Int64,
        rangeDuration: CMTime
    ) -> Int64 {
        guard totalFileBytes > 0 else { return bytesRequiredOnDisk }
        let windowSeconds = CMTimeGetSeconds(rangeDuration)
        guard windowSeconds > 0 else { return bytesRequiredOnDisk }

        var fraction = min(0.4, windowSeconds / 600.0)
        if totalFileBytes > 1_000_000_000, windowSeconds <= 60.5 {
            fraction = max(fraction, 0.22)
        } else if totalFileBytes > 500_000_000, windowSeconds <= 60.5 {
            fraction = max(fraction, 0.14)
        }
        let fromSize = Int64(Double(totalFileBytes) * fraction)
        return max(bytesRequiredOnDisk, fromSize)
    }

    private enum ProbeResult {
        case ok(videoSamples: Int)
        case needsMoreData(String)
        case failed(Error)
    }

    private static func probeWindow(
        fileURL: URL,
        rangeStart: CMTime,
        rangeDuration: CMTime
    ) async -> ProbeResult {
        let asset = AVURLAsset(
            url: fileURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )

        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.load(.tracks)
        } catch {
            return .needsMoreData("cannot load tracks")
        }
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            return .needsMoreData("no video track visible yet")
        }

        let rangeEnd = CMTimeAdd(rangeStart, rangeDuration)
        guard let reader = try? AVAssetReader(asset: asset) else {
            return .needsMoreData("cannot open reader")
        }
        reader.timeRange = CMTimeRange(start: rangeStart, end: rangeEnd)

        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            return .needsMoreData("reader not ready")
        }
        guard reader.startReading() else {
            if let err = reader.error {
                return .needsMoreData("reader not ready — \(err.localizedDescription)")
            }
            return .needsMoreData("reader not ready")
        }

        var videoCount = 0
        var inRangeCount = 0
        var lastPTS = rangeStart

        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            videoCount += 1
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if CMTimeCompare(pts, rangeStart) >= 0 {
                inRangeCount += 1
                lastPTS = pts
            }
        }

        if reader.status == .failed {
            let detail = reader.error?.localizedDescription ?? "read stopped early"
            return .needsMoreData(detail)
        }

        if videoCount > 0, inRangeCount == 0 {
            return .needsMoreData("reader saw \(videoCount) samples but none in 0:00 window yet")
        }

        let coveredSeconds = CMTimeGetSeconds(CMTimeSubtract(lastPTS, rangeStart))
        let needSeconds = CMTimeGetSeconds(rangeDuration) * 0.85

        if inRangeCount < minVideoSamplesFor60s {
            return .needsMoreData("only \(inRangeCount) video samples in window (incomplete)")
        }
        if coveredSeconds < needSeconds {
            return .needsMoreData(String(format: "timeline covers %.0fs, need ~%.0fs", coveredSeconds, needSeconds))
        }
        return .ok(videoSamples: inRangeCount)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
        }
        return "\(bytes) B"
    }
}
