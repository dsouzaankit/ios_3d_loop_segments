import AVFoundation
import CoreMedia
import Foundation

/// Stream-copy one 60s window from a local file (as fast as disk allows).
enum SegmentPassThroughExporter {
    static func exportWindow(
        asset: AVURLAsset,
        videoFormat: CMFormatDescription,
        audioFormat: CMFormatDescription?,
        rangeStart: CMTime,
        rangeDuration: CMTime,
        outputURL: URL,
        sourceLabel: String,
        isCancelled: (() -> Bool)? = nil,
        log: @escaping (String) -> Void
    ) async throws {
        _ = audioFormat
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw SegmentExporterError.noVideoTrack
        }
        let rangeEnd = CMTimeAdd(rangeStart, rangeDuration)

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            log("Reader could not open (\(sourceLabel)): \(error.localizedDescription)")
            throw SegmentExporterError.readerFailed(error)
        }
        let readerLeadInSeconds = min(45.0, max(0, CMTimeGetSeconds(rangeStart)))
        let readerStart = CMTimeSubtract(
            rangeStart,
            CMTime(seconds: readerLeadInSeconds, preferredTimescale: rangeStart.timescale)
        )
        reader.timeRange = CMTimeRange(start: readerStart, end: rangeEnd)

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw SegmentExporterError.readerSetupFailed
        }
        reader.add(videoOutput)

        guard reader.startReading() else {
            if let readerError = reader.error {
                log("Reader failed (\(sourceLabel)): \(readerError.localizedDescription)")
                throw SegmentExporterError.readerFailed(readerError)
            }
            log("Reader could not start (\(sourceLabel)) — sparse temp may need more download, or pCloud range reads were interrupted")
            throw SegmentExporterError.readerSetupFailed
        }

        try? FileManager.default.removeItem(at: outputURL)
        log("Staging \(outputURL.lastPathComponent) via \(sourceLabel) (media \(formatMediaTime(rangeStart))–\(formatMediaTime(rangeEnd)), video-only)")

        var writerContext: SegmentWriterContext?
        var startedWriter = false
        var timelineOrigin: CMTime?
        var skippedBeforeRange = 0
        var skippedNonKeyframe = 0
        var inRangeVideoSamples = 0
        var lastInRangePTS = rangeStart
        let label = sourceLabel.lowercased()
        let relaxKeyframeGating = label.contains("pcloud stream") || label.contains("sparse temp + pcloud")
        let maxKeyframeScan = relaxKeyframeGating ? 2400 : 480
        let earliestStart = relaxKeyframeGating
            ? CMTimeSubtract(
                rangeStart,
                CMTime(seconds: ExportDeliveryPolicy.maxKeyframeStartOffsetSeconds, preferredTimescale: rangeStart.timescale)
            )
            : rangeStart
        let minInRangeVideoSamples = 24
        var lastProgressLog = CFAbsoluteTimeGetCurrent()
        var lastSampleAt = CFAbsoluteTimeGetCurrent()
        let stallBeforeFirstSample: Double = 90
        let stallAfterStart: Double = 90
        let stallWithFewSamples: Double = 45
        let readerQueue = DispatchQueue(label: "com.loopsegments.passthrough-reader")

        let heartbeat = Task {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                if startedWriter {
                    log("Passthrough — \(inRangeVideoSamples) video samples written so far…")
                } else {
                    log("Passthrough — waiting for reader / writer…")
                }
            }
        }
        defer { heartbeat.cancel() }

        while true {
            if isCancelled?() == true {
                throw SegmentExporterError.cancelled
            }
            if reader.status == .failed {
                throw reader.error.map { SegmentExporterError.readerFailed($0) }
                    ?? SegmentExporterError.readerSetupFailed
            }

            let now = CFAbsoluteTimeGetCurrent()
            if !startedWriter, now - lastSampleAt > stallBeforeFirstSample {
                log(
                    "Export stalled \(Int(stallBeforeFirstSample))s waiting for first video sample — download more temp data or try seek 0 min on Wi‑Fi"
                )
                throw SegmentExporterError.readerSetupFailed
            }
            if startedWriter,
               inRangeVideoSamples < minInRangeVideoSamples,
               now - lastSampleAt > stallWithFewSamples {
                try? FileManager.default.removeItem(at: outputURL)
                log(
                    "Export stalled — only \(inRangeVideoSamples) video samples after \(Int(stallWithFewSamples))s (need \(minInRangeVideoSamples)); dense-download this minute and retry"
                )
                throw SegmentExporterError.segmentOutputTooSmall(0)
            }
            if startedWriter, now - lastSampleAt > stallAfterStart {
                log("Export stalled \(Int(stallAfterStart))s — ending segment with \(inRangeVideoSamples) samples")
                break
            }
            if now - lastProgressLog >= 10 {
                lastProgressLog = now
                log(
                    String(
                        format: "Export in progress — %d video samples in window, reader active…",
                        inRangeVideoSamples
                    )
                )
            }

            await Task.yield()
            guard let videoSample = await copyNextSample(on: readerQueue, from: videoOutput) else {
                if !startedWriter {
                    log(
                        "Reader ended — \(skippedBeforeRange) samples before \(formatMediaTime(rangeStart)), " +
                            "\(skippedNonKeyframe) non-sync skipped (reader status \(reader.status.rawValue))"
                    )
                }
                break
            }
            lastSampleAt = CFAbsoluteTimeGetCurrent()

            let pts = CMSampleBufferGetPresentationTimeStamp(videoSample)
            if !startedWriter {
                if CMTimeCompare(pts, earliestStart) < 0 {
                    skippedBeforeRange += 1
                    continue
                }
                let hasSync = HEVCSyncSample.isReliableSyncPoint(
                    videoSample,
                    videoFormat: videoFormat,
                    strictHEVCNALScan: true
                )
                if !hasSync {
                    skippedNonKeyframe += 1
                    if skippedNonKeyframe >= maxKeyframeScan {
                        log(
                            "No HEVC sync in \(maxKeyframeScan) frames at \(formatMediaTime(rangeStart)) — dense-download this minute or try seek 0 min"
                        )
                        throw SegmentExporterError.noKeyframeInWindow
                    }
                    continue
                }
                timelineOrigin = pts
                let ctx = try SegmentWriterContext(
                    outputURL: outputURL,
                    videoFormat: videoFormat,
                    audioFormat: nil,
                    realTime: false
                )
                ctx.start(at: .zero)
                writerContext = ctx
                startedWriter = true
                if skippedNonKeyframe > 0 {
                    log("Started on frame \(skippedNonKeyframe + 1) in window (HEVC sync scan)")
                }
                log("Segment timestamps reset to 0 (source PTS \(formatMediaTime(pts)))")
            }

            let origin = timelineOrigin ?? rangeStart
            let timedSample = try SegmentSampleTiming.retimeToSegmentStart(videoSample, subtract: origin)
            try await writerContext?.append(
                timedSample,
                track: .video,
                isCancelled: isCancelled,
                log: log
            )
            if CMTimeCompare(pts, rangeStart) >= 0 {
                inRangeVideoSamples += 1
                lastInRangePTS = pts
            }
        }

        guard startedWriter else {
            log(
                "No segment start — skipped \(skippedBeforeRange) pre-window, \(skippedNonKeyframe) non-sync (\(sourceLabel))"
            )
            if skippedBeforeRange > 0, skippedNonKeyframe == 0 {
                throw SegmentExporterError.timelineByteWindowMismatch(
                    mediaTime: formatMediaTime(rangeStart)
                )
            }
            throw SegmentExporterError.noKeyframeInWindow
        }

        let segmentOrigin = timelineOrigin ?? rangeStart
        let startOffsetInWindow = CMTimeGetSeconds(CMTimeSubtract(segmentOrigin, rangeStart))
        let coveredSeconds = CMTimeGetSeconds(CMTimeSubtract(lastInRangePTS, segmentOrigin))
        let needSeconds = CMTimeGetSeconds(rangeDuration) * 0.85
        if startOffsetInWindow > ExportDeliveryPolicy.maxKeyframeStartOffsetSeconds {
            try? FileManager.default.removeItem(at: outputURL)
            log(
                String(
                    format: "Segment starts at %@ (%.0fs into window) — need keyframe near %@",
                    formatMediaTime(segmentOrigin),
                    startOffsetInWindow,
                    formatMediaTime(rangeStart)
                )
            )
            throw SegmentExporterError.segmentOutputTooSmall(0)
        }
        if inRangeVideoSamples < minInRangeVideoSamples || coveredSeconds < needSeconds {
            try? FileManager.default.removeItem(at: outputURL)
            log(
                String(
                    format: "Segment incomplete — %d video samples, ~%.0fs written (need ~%d samples / ~%.0fs from first keyframe)",
                    inRangeVideoSamples,
                    coveredSeconds,
                    minInRangeVideoSamples,
                    needSeconds
                )
            )
            throw SegmentExporterError.segmentOutputTooSmall(0)
        }

        if let writerContext {
            try await writerContext.finish()
        }
    }

    private static func copyNextSample(
        on queue: DispatchQueue,
        from output: AVAssetReaderTrackOutput
    ) async -> CMSampleBuffer? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: output.copyNextSampleBuffer())
            }
        }
    }

    private static func formatMediaTime(_ time: CMTime) -> String {
        let seconds = CMTimeGetSeconds(time)
        let min = Int(seconds) / 60
        let sec = Int(seconds) % 60
        return String(format: "%d:%02d", min, sec)
    }
}
