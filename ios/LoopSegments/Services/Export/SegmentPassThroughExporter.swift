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
        log: (String) -> Void
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
        reader.timeRange = CMTimeRange(start: rangeStart, end: rangeEnd)

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
        var startedWriter = false
        var timelineOrigin: CMTime?
        var skippedBeforeRange = 0
        var skippedNonKeyframe = 0
        var inRangeVideoSamples = 0
        var lastInRangePTS = rangeStart
        let relaxKeyframeGating = sourceLabel.lowercased().contains("pcloud stream")
        let maxKeyframeScan = relaxKeyframeGating ? 2400 : 480
        let minInRangeVideoSamples = 24
        var lastProgressLog = CFAbsoluteTimeGetCurrent()
        var lastSampleAt = CFAbsoluteTimeGetCurrent()
        let stallBeforeFirstSample: Double = 120
        let stallAfterStart: Double = 180

        while true {
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
            if startedWriter, now - lastSampleAt > stallAfterStart {
                log("Export stalled \(Int(stallAfterStart))s — ending segment with \(inRangeVideoSamples) samples")
                break
            }
            if now - lastProgressLog >= 30 {
                lastProgressLog = now
                log(
                    String(
                        format: "Export in progress — %d video samples in window, reader active…",
                        inRangeVideoSamples
                    )
                )
            }

            await Task.yield()
            let videoSample = videoOutput.copyNextSampleBuffer()
            if videoSample != nil {
                lastSampleAt = CFAbsoluteTimeGetCurrent()
            }
            if heldAudio == nil {
                heldAudio = audioOutput?.copyNextSampleBuffer()
            }

            var candidates: [(track: SegmentTrackKind, sample: CMSampleBuffer)] = []
            if let videoSample { candidates.append((.video, videoSample)) }
            if let heldAudio { candidates.append((.audio, heldAudio)) }

            if candidates.isEmpty {
                break
            }

            guard let next = candidates.min(by: {
                CMSampleBufferGetPresentationTimeStamp($0.sample) <
                    CMSampleBufferGetPresentationTimeStamp($1.sample)
            }) else {
                break
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(next.sample)
            if !startedWriter {
                if next.track == .audio {
                    heldAudio = nil
                    continue
                }
                if CMTimeCompare(pts, rangeStart) < 0 {
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
                if skippedNonKeyframe > 0 {
                    log("Started on frame \(skippedNonKeyframe + 1) in window (HEVC sync scan)")
                }
                log("Segment timestamps reset to 0 (source PTS \(formatMediaTime(pts)))")
            }

            let origin = timelineOrigin ?? rangeStart
            let timedSample = try SegmentSampleTiming.retimeToSegmentStart(next.sample, subtract: origin)
            try writerContext?.append(timedSample, track: next.track)
            if next.track == .video, CMTimeCompare(pts, rangeStart) >= 0 {
                inRangeVideoSamples += 1
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
            throw SegmentExporterError.noKeyframeInWindow
        }

        let coveredSeconds = CMTimeGetSeconds(CMTimeSubtract(lastInRangePTS, rangeStart))
        let needSeconds = CMTimeGetSeconds(rangeDuration) * 0.85
        if inRangeVideoSamples < minInRangeVideoSamples || coveredSeconds < needSeconds {
            try? FileManager.default.removeItem(at: outputURL)
            log(
                String(
                    format: "Segment incomplete — %d video samples, ~%.0fs in window (need ~%d samples / ~%.0fs); download more temp data",
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

    private static func formatMediaTime(_ time: CMTime) -> String {
        let seconds = CMTimeGetSeconds(time)
        let min = Int(seconds) / 60
        let sec = Int(seconds) % 60
        return String(format: "%d:%02d", min, sec)
    }
}
