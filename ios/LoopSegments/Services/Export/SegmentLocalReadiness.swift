import AVFoundation
import CoreMedia
import Foundation

/// Confirms a local temp file can supply a full passthrough window before we write a segment.
enum SegmentLocalReadiness {
    private static let minVideoSamplesFor60s = 24
    private static let minOutputBytes: Int64 = 512 * 1024
    private static let maxProbeSamples = 120
    private static let probeTimeoutLargeFile: Double = 90
    private static let probeTimeoutDefault: Double = 45
    /// Stop probing and let passthrough / stream fallback try (avoids infinite 0-sample loop).
    private static let maxReadinessWallSeconds: Double = 150
    private static let proceedAfterZeroSampleProbes = 10

    static func waitUntilReadable(
        fileURL: URL,
        rangeStart: CMTime,
        rangeDuration: CMTime,
        totalFileBytes: Int64,
        requiredByteRange: TimelineByteRange,
        isWindowDenseFilled: () -> Bool,
        windowFilledBytes: () -> Int64,
        filledByteSpan: () -> TimelineByteRange,
        indexTailOnDisk: () -> Bool,
        refreshMP4Index: () async throws -> Void,
        prepareSparseFileForReader: (() async throws -> Void)? = nil,
        isCancelled: () -> Bool,
        log: (String) -> Void
    ) async throws {
        let probeFloor = probeMinContiguousBytes(
            windowBytes: requiredByteRange.length,
            rangeDuration: rangeDuration
        )
        let needEnd = requiredByteRange.end + max(0, probeFloor - requiredByteRange.length)
        let probeTimeout = totalFileBytes > 1_000_000_000 ? probeTimeoutLargeFile : probeTimeoutDefault
        var lastLog = CFAbsoluteTimeGetCurrent()
        var zeroSampleStreak = 0
        var trackLoadStreak = 0
        var probeAttempts = 0
        var indexRefreshCount = 0
        var lastZeroSampleLog = CFAbsoluteTimeGetCurrent()
        var preparePassCount = 0
        let needWindowBytes = needEnd - requiredByteRange.start
        let wallStart = CFAbsoluteTimeGetCurrent()

        while true {
            if isCancelled() { throw SegmentExporterError.cancelled }
            let wallElapsed = CFAbsoluteTimeGetCurrent() - wallStart
            if wallElapsed >= maxReadinessWallSeconds {
                log(
                    "Readiness: stopping after \(Int(wallElapsed))s — proceeding to export (probe saw 0 samples; passthrough or pCloud stream will retry)"
                )
                return
            }
            let filled = filledByteSpan()
            let denseReady = isWindowDenseFilled()
            let rangeReady = denseReady || (filled.start <= requiredByteRange.start && filled.end >= needEnd)
            if !rangeReady {
                try await Task.sleep(nanoseconds: 250_000_000)
                continue
            }

            probeAttempts += 1
            let probeResult: ProbeResult
            do {
                probeResult = try await ExportAsyncTimeout.run(
                    seconds: probeTimeout,
                    operation: "Readiness probe"
                ) {
                    await probeWindow(
                        fileURL: fileURL,
                        rangeStart: rangeStart,
                        rangeDuration: rangeDuration
                    )
                }
            } catch is ExportAsyncTimeout.TimedOut {
                log(
                    "Readiness probe timed out after \(Int(probeTimeout))s — proceeding to export with \(formatBytes(filled.end - filled.start)) on disk (AVAssetReader was slow on sparse temp)"
                )
                return
            }

            switch probeResult {
            case .ok(let videoSamples):
                if totalFileBytes > 0, filled.end >= totalFileBytes {
                    log("Readiness OK — full temp file on disk (\(formatBytes(filled.end))), \(videoSamples) video samples in window")
                } else if indexTailOnDisk() {
                    log("Readiness OK — \(formatBytes(filled.start))–\(formatBytes(filled.end)) + \(videoSamples) video samples (index at EOF)")
                } else {
                    log("Readiness OK — \(videoSamples) video samples in window (\(formatBytes(filled.start))–\(formatBytes(filled.end)) on disk)")
                }
                return
            case .needsMoreData(let reason):
                let zeroInWindow = isZeroSampleInWindow(reason)
                if zeroInWindow {
                    zeroSampleStreak += 1
                } else {
                    zeroSampleStreak = 0
                }
                if isContainerOpenFailure(reason) || zeroInWindow {
                    trackLoadStreak += 1
                    if trackLoadStreak == 1 || trackLoadStreak == 4, indexRefreshCount < 4 {
                        indexRefreshCount += 1
                        let why = zeroInWindow
                            ? "probe saw 0 video samples in this minute"
                            : "AVFoundation could not open tracks"
                        log("Fetching MP4 index from pCloud (\(why))…")
                        try await refreshMP4Index()
                    }
                    if trackLoadStreak == 2, let prepare = prepareSparseFileForReader {
                        log("Sparse temp: ensuring file header + dense window before reader…")
                        try await prepare()
                        preparePassCount += 1
                    }
                } else {
                    trackLoadStreak = 0
                }
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastLog >= 15 {
                    lastLog = now
                    let filledInWindow = denseReady
                        ? windowFilledBytes()
                        : max(
                            0,
                            min(filled.end, needEnd) - max(filled.start, requiredByteRange.start)
                        )
                    let indexNote = indexTailOnDisk() ? "" : ", MP4 index still loading"
                    log(
                        "Waiting for clearer source — \(reason) (\(formatBytes(filledInWindow)) / \(formatBytes(needWindowBytes)) in window\(indexNote))"
                    )
                }
                let windowBytesReady = denseReady
                    ? windowFilledBytes() >= needWindowBytes
                    : max(
                        0,
                        min(filled.end, needEnd) - max(filled.start, requiredByteRange.start)
                    ) >= needWindowBytes
                if trackLoadStreak >= 3, rangeReady, windowBytesReady, indexTailOnDisk(), probeAttempts >= 2,
                   !reason.contains("only 0 video samples") {
                    log(
                        "Readiness: window + index on disk but tracks still not visible — exporting anyway (temp/stream fallback during passthrough)"
                    )
                    return
                }
                if trackLoadStreak >= 8, rangeReady, probeAttempts >= 4,
                   !reason.contains("only 0 video samples") {
                    log(
                        "Readiness: \(formatBytes(filled.end - filled.start)) on disk but tracks still not visible — exporting anyway (will retry reader during passthrough)"
                    )
                    return
                }
                if zeroInWindow, rangeReady {
                    let nowZero = CFAbsoluteTimeGetCurrent()
                    if nowZero - lastZeroSampleLog >= 15 {
                        lastZeroSampleLog = nowZero
                        let indexNote = indexTailOnDisk() ? "index at EOF on disk" : "still fetching MP4 index at EOF"
                        log(
                            "Readiness: 0 video samples in 0:00 window — \(formatBytes(windowFilledBytes())) / \(formatBytes(needWindowBytes)) downloaded (\(indexNote))"
                        )
                    }
                }
                if zeroInWindow, rangeReady, windowBytesReady, indexTailOnDisk(), probeAttempts >= proceedAfterZeroSampleProbes {
                    log(
                        "Readiness: window + index on disk but probe still 0 samples — proceeding to export (passthrough / stream fallback)"
                    )
                    return
                }
                if zeroInWindow, rangeReady, windowBytesReady, probeAttempts >= proceedAfterZeroSampleProbes + 4 {
                    log(
                        "Readiness: window on disk, probe still 0 samples — proceeding to export (index tail may still be loading)"
                    )
                    return
                }
            case .failed(let error):
                throw error
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    static func validateOutputFile(
        at url: URL,
        rangeDuration: CMTime,
        log: (String) -> Void
    ) async throws {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        guard bytes >= minOutputBytes else {
            throw SegmentExporterError.segmentOutputTooSmall(bytes)
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        let needSeconds = CMTimeGetSeconds(rangeDuration) * 0.85
        guard seconds.isFinite, seconds >= needSeconds else {
            throw SegmentExporterError.segmentOutputTooSmall(bytes)
        }
        log(String(format: "Segment size OK — %d KB, %.1fs duration", bytes / 1024, seconds))
    }

    private static func probeMinContiguousBytes(
        windowBytes: Int64,
        rangeDuration: CMTime
    ) -> Int64 {
        guard windowBytes > 0 else { return 0 }
        let windowSeconds = CMTimeGetSeconds(rangeDuration)
        guard windowSeconds > 0 else { return windowBytes }

        let extra = windowSeconds <= 60.5 ? Int64(16 * 1024 * 1024) : Int64(4 * 1024 * 1024)
        return windowBytes + extra
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
        let needSeconds = CMTimeGetSeconds(rangeDuration) * 0.85

        while reader.status == .reading, videoCount < maxProbeSamples {
            await Task.yield()
            guard let sample = output.copyNextSampleBuffer() else { break }
            videoCount += 1
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if CMTimeCompare(pts, rangeStart) >= 0 {
                inRangeCount += 1
                lastPTS = pts
            }
            let coveredSeconds = CMTimeGetSeconds(CMTimeSubtract(lastPTS, rangeStart))
            if inRangeCount >= minVideoSamplesFor60s, coveredSeconds >= needSeconds {
                return .ok(videoSamples: inRangeCount)
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

        if inRangeCount < minVideoSamplesFor60s {
            return .needsMoreData("only \(inRangeCount) video samples in window (incomplete)")
        }
        if coveredSeconds < needSeconds {
            return .needsMoreData(String(format: "timeline covers %.0fs, need ~%.0fs", coveredSeconds, needSeconds))
        }
        return .ok(videoSamples: inRangeCount)
    }

    private static func isContainerOpenFailure(_ reason: String) -> Bool {
        let lower = reason.lowercased()
        return lower.contains("cannot load tracks")
            || lower.contains("no video track visible")
            || lower.contains("cannot open reader")
            || lower.contains("cannot open")
    }

    /// Reader opens but finds no decodable frames in the export window (common when `moov` / byte map mismatch).
    private static func isZeroSampleInWindow(_ reason: String) -> Bool {
        let lower = reason.lowercased()
        if lower.contains("only 0 video samples") { return true }
        if lower.contains("none in 0:00 window") { return true }
        if lower.contains("0 video samples") && lower.contains("incomplete") { return true }
        return false
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
        }
        return "\(bytes) B"
    }
}
