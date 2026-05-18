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
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw SegmentExporterError.noVideoTrack
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
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
        reader.timeRange = CMTimeRange(
            start: readerStart,
            end: rangeEnd
        )

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw SegmentExporterError.readerSetupFailed
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw SegmentExporterError.readerSetupFailed
            }
            reader.add(output)
            audioOutput = output
        }

        guard reader.startReading() else {
            if let readerError = reader.error {
                log("Reader failed (\(sourceLabel)): \(readerError.localizedDescription)")
                throw SegmentExporterError.readerFailed(readerError)
            }
            log("Reader could not start (\(sourceLabel)) — sparse temp may need more download, or pCloud range reads were interrupted")
            throw SegmentExporterError.readerSetupFailed
        }

        try? FileManager.default.removeItem(at: outputURL)
        log("Staging \(outputURL.lastPathComponent) via \(sourceLabel) (media \(formatMediaTime(rangeStart))–\(formatMediaTime(rangeEnd)))")

        var writerContext: SegmentWriterContext?
        var heldAudio: CMSampleBuffer?
        var skipAudio = false
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
        /// `AVAssetReaderTrackOutput` is not thread-safe — never call `copyNextSampleBuffer` concurrently.
        let readerQueue = DispatchQueue(label: "com.loopsegments.passthrough-reader")

        final class PassthroughProgress: @unchecked Sendable {
            var inRangeVideoSamples = 0
            var startedWriter = false
        }
        let progress = PassthroughProgress()
        let heartbeat = Task {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                if progress.startedWriter {
                    log("Passthrough — \(progress.inRangeVideoSamples) video samples written so far…")
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
            let videoSample = await copyNextSample(on: readerQueue, from: videoOutput)
            if videoSample != nil {
                lastSampleAt = CFAbsoluteTimeGetCurrent()
            }
            if !skipAudio, heldAudio == nil, let audioOutput {
                heldAudio = await copyNextSample(on: readerQueue, from: audioOutput)
            }

            var candidates: [(track: SegmentTrackKind, sample: CMSampleBuffer)] = []
            if let videoSample { candidates.append((.video, videoSample)) }
            if let heldAudio { candidates.append((.audio, heldAudio)) }

            if candidates.isEmpty {
                if !startedWriter {
                    log(
                        "Reader ended — \(skippedBeforeRange) samples before \(formatMediaTime(rangeStart)), " +
                            "\(skippedNonKeyframe) non-sync skipped (reader status \(reader.status.rawValue))"
                    )
                }
                break
            }

            guard let next = selectNextCandidate(
                candidates,
                inRangeVideoSamples: inRangeVideoSamples,
                skipAudio: skipAudio,
                videoFirstUntil: minInRangeVideoSamples
            ) else {
                break
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(next.sample)
            if !startedWriter {
                if next.track == .audio {
                    heldAudio = nil
                    continue
                }
                if CMTimeCompare(pts, earliestStart) < 0 {
                    skippedBeforeRange += 1
                    continue
                }
                let requireSync = skippedNonKeyframe < maxKeyframeScan
                let hasSync = HEVCSyncSample.isReliableSyncPoint(
                    next.sample,
                    videoFormat: videoFormat,
                    strictHEVCNALScan: !relaxKeyframeGating
                )
                if requireSync, !hasSync {
                    skippedNonKeyframe += 1
                    continue
                }
                if !hasSync, relaxKeyframeGating {
                    log(
                        "Starting on in-range frame without confirmed HEVC sync (\(skippedNonKeyframe + 1) frames scanned, \(sourceLabel))"
                    )
                }
                timelineOrigin = pts
                let ctx = try SegmentWriterContext(
                    outputURL: outputURL,
                    videoFormat: videoFormat,
                    audioFormat: audioFormat,
                    realTime: false
                )
                ctx.start(at: .zero)
                writerContext = ctx
                startedWriter = true
                progress.startedWriter = true
                if skippedNonKeyframe > 0 {
                    log("Started on frame \(skippedNonKeyframe + 1) in window (HEVC sync scan)")
                }
                log("Segment timestamps reset to 0 (source PTS \(formatMediaTime(pts)))")
            }

            let origin = timelineOrigin ?? rangeStart
            let timedSample = try SegmentSampleTiming.retimeToSegmentStart(next.sample, subtract: origin)
            do {
                try await writerContext?.append(
                    timedSample,
                    track: next.track,
                    isCancelled: isCancelled,
                    log: log
                )
            } catch SegmentExporterError.writerAudioStall {
                log(
                    "Audio writer stalled — continuing video-only for this segment (DLNA may have no audio track)"
                )
                writerContext?.abandonAudio()
                skipAudio = true
                heldAudio = nil
                continue
            } catch SegmentExporterError.writerFailed(let underlying) {
                let ns = underlying as NSError
                log(
                    "Writer append failed (\(next.track)) at source \(formatMediaTime(pts)) — \(underlying.localizedDescription) (domain \(ns.domain) \(ns.code))"
                )
                throw SegmentExporterError.writerFailed(underlying)
            }
            if next.track == .video, CMTimeCompare(pts, rangeStart) >= 0 {
                inRangeVideoSamples += 1
                progress.inRangeVideoSamples = inRangeVideoSamples
                lastInRangePTS = pts
            }
            if next.track == .audio {
                heldAudio = nil
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

    private static func selectNextCandidate(
        _ candidates: [(track: SegmentTrackKind, sample: CMSampleBuffer)],
        inRangeVideoSamples: Int,
        skipAudio: Bool,
        videoFirstUntil: Int
    ) -> (track: SegmentTrackKind, sample: CMSampleBuffer)? {
        guard !candidates.isEmpty else { return nil }
        if skipAudio {
            return candidates.first { $0.track == .video }
        }
        if inRangeVideoSamples < videoFirstUntil,
           let video = candidates.first(where: { $0.track == .video }) {
            return video
        }
        return candidates.min(by: {
            CMSampleBufferGetPresentationTimeStamp($0.sample) <
                CMSampleBufferGetPresentationTimeStamp($1.sample)
        })
    }

    private static func formatMediaTime(_ time: CMTime) -> String {
        let seconds = CMTimeGetSeconds(time)
        let min = Int(seconds) / 60
        let sec = Int(seconds) % 60
        return String(format: "%d:%02d", min, sec)
    }
}
