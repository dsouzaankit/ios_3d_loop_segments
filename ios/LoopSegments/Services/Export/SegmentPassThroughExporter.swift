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
    ) async throws -> SegmentPassThroughResult {
        let includeAudio = audioFormat != nil
        let videoTrack: AVAssetTrack?
        do {
            videoTrack = try await asset.loadTracks(withMediaType: .video).first
        } catch {
            log(
                "Could not load video track (\(sourceLabel), \(asset.url.scheme ?? "?")://…): \(error.localizedDescription)"
            )
            throw error
        }
        guard let videoTrack else {
            throw SegmentExporterError.noVideoTrack
        }
        let nominalEnd = CMTimeAdd(rangeStart, rangeDuration)
        let keyframeAligned = ExportDeliveryPolicy.keyframeAlignedBoundaries
        let huntSeconds = ExportDeliveryPolicy.keyframeEndHuntSeconds
        let readerEnd = keyframeAligned
            ? CMTimeAdd(
                nominalEnd,
                CMTime(seconds: huntSeconds, preferredTimescale: rangeStart.timescale)
            )
            : nominalEnd
        let cutAt = nominalEnd
        log(
            "Passthrough — source \(ExportTimelineLog.sourceRange(start: rangeStart, end: nominalEnd))" +
                (keyframeAligned ? " (cut at next keyframe, hunt +\(Int(huntSeconds))s)" : "")
        )
        let windowSeconds = CMTimeGetSeconds(rangeDuration)
        guard windowSeconds.isFinite, windowSeconds >= 0.5 else {
            log(
                "Segment window too short (\(String(format: "%.2f", windowSeconds))s at \(formatMediaTime(rangeStart))) — file may be at end"
            )
            throw SegmentExporterError.segmentOutputTooSmall(0)
        }

        let videoTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            log("Reader could not open (\(sourceLabel)): \(error.localizedDescription)")
            throw SegmentExporterError.readerFailed(error)
        }
        defer { reader.cancelReading() }
        let readerLeadInSeconds = min(45.0, max(0, CMTimeGetSeconds(rangeStart)))
        let readerStart = CMTimeSubtract(
            rangeStart,
            CMTime(seconds: readerLeadInSeconds, preferredTimescale: rangeStart.timescale)
        )
        reader.timeRange = CMTimeRange(start: readerStart, end: readerEnd)

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = true
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
        let label = sourceLabel.lowercased()
        let denseLocal = label.contains("dense local temp")
        let tracksNote = includeAudio ? "video+aac passthrough" : "video-only"
        log(
            "Staging \(outputURL.lastPathComponent) via \(sourceLabel) " +
                "(media \(formatMediaTime(rangeStart))–\(formatMediaTime(rangeEnd)), \(tracksNote)" +
                (denseLocal ? ", full window on disk" : "") + ")"
        )

        var writerContext: SegmentWriterContext?
        var exportFinishedOK = false
        defer {
            if !exportFinishedOK {
                writerContext?.cancelIfNeeded()
            }
        }
        var startedWriter = false
        var timelineOrigin: CMTime?
        var skippedBeforeRange = 0
        var skippedNonKeyframe = 0
        var inRangeVideoSamples = 0
        var lastInRangePTS = rangeStart
        var nextSegmentStartPTS: CMTime?
        var droppedPastNominalEnd = 0
        let relaxKeyframeGating = label.lowercased().contains("pcloud")
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
                let strictH264IDR = CMTimeGetSeconds(rangeStart) < 1.0
                let hasSync = HEVCSyncSample.isReliableSyncPoint(
                    videoSample,
                    videoFormat: videoFormat,
                    strictHEVCNALScan: true,
                    strictH264IDR: strictH264IDR
                )
                if !hasSync {
                    skippedNonKeyframe += 1
                    if skippedNonKeyframe >= maxKeyframeScan {
                        log(
                            "No keyframe in \(maxKeyframeScan) frames at \(formatMediaTime(rangeStart)) — dense-download this minute or try seek 0 min"
                        )
                        throw SegmentExporterError.noKeyframeInWindow
                    }
                    continue
                }
                timelineOrigin = pts
                let writerFormat: CMFormatDescription
                if let sampleDesc = CMSampleBufferGetFormatDescription(videoSample) {
                    writerFormat = CodecSupport.normalizedForMP4Writer(sampleDesc)
                    let probeSub = CMFormatDescriptionGetMediaSubType(videoFormat)
                    let sampleSub = CMFormatDescriptionGetMediaSubType(sampleDesc)
                    if probeSub != sampleSub {
                        log(
                            "Writer uses \(CodecSupport.fourCCString(writerFormat)) from first sample " +
                                "(probe had \(CodecSupport.fourCCString(videoFormat)))"
                        )
                    }
                } else {
                    writerFormat = videoFormat
                }
                let ctx = try SegmentWriterContext(
                    outputURL: outputURL,
                    videoFormat: writerFormat,
                    audioFormat: includeAudio ? audioFormat : nil,
                    videoTransform: videoTransform,
                    realTime: false
                )
                ctx.start(at: .zero)
                writerContext = ctx
                startedWriter = true
                if skippedNonKeyframe > 0 {
                    log("Started on frame \(skippedNonKeyframe + 1) in window (keyframe scan)")
                }
                log(
                    "Segment timestamps reset to 0 — first sample source PTS \(ExportTimelineLog.wallClock(pts)), " +
                        "window \(ExportTimelineLog.sourceRange(start: rangeStart, end: nominalEnd))"
                )
            }

            if keyframeAligned, startedWriter, CMTimeCompare(pts, cutAt) >= 0 {
                let writerFormatForSync = CMSampleBufferGetFormatDescription(videoSample)
                    ?? videoFormat
                let strictH264IDR = CMTimeGetSeconds(rangeStart) < 1.0
                if HEVCSyncSample.isReliableSyncPoint(
                    videoSample,
                    videoFormat: writerFormatForSync,
                    strictHEVCNALScan: true,
                    strictH264IDR: strictH264IDR
                ) {
                    nextSegmentStartPTS = pts
                    break
                }
                droppedPastNominalEnd += 1
                continue
            }

            let origin = timelineOrigin ?? rangeStart
            let timedSample = try SegmentSampleTiming.retimeToSegmentStart(videoSample, subtract: origin)
            do {
                try await writerContext?.append(
                    timedSample,
                    track: .video,
                    isCancelled: isCancelled,
                    log: log
                )
            } catch SegmentExporterError.writerFailed(let underlying) {
                let ns = underlying as NSError
                log(
                    "Video writer append failed (\(sourceLabel)): \(underlying.localizedDescription) " +
                        "(\(ns.domain) \(ns.code))"
                )
                throw SegmentExporterError.writerFailed(underlying)
            }
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

        let segmentEndPTS = lastInRangePTS
        let resolvedNextStart = nextSegmentStartPTS ?? nominalEnd
        if keyframeAligned, droppedPastNominalEnd > 0 {
            log(
                "Keyframe segment end — dropped \(droppedPastNominalEnd) frame(s) after \(formatMediaTime(nominalEnd)); " +
                    "next segment at \(formatMediaTime(resolvedNextStart))"
            )
        }

        if includeAudio, let writerContext {
            let segmentOrigin = timelineOrigin ?? rangeStart
            let audioEnd = keyframeAligned ? resolvedNextStart : nominalEnd
            await appendAudioPassthrough(
                asset: asset,
                readerStart: readerStart,
                rangeStart: rangeStart,
                rangeEnd: audioEnd,
                segmentOrigin: segmentOrigin,
                writerContext: writerContext,
                sourceLabel: sourceLabel,
                isCancelled: isCancelled,
                log: log
            )
        }

        if let writerContext {
            try await writerContext.finish()
        }
        log(
            "Passthrough finished — source \(ExportTimelineLog.sourceRange(start: segmentOrigin, end: segmentEndPTS)), " +
                "segment file 0:00–\(ExportTimelineLog.wallClock(seconds: CMTimeGetSeconds(CMTimeSubtract(segmentEndPTS, segmentOrigin))))"
        )
        return SegmentPassThroughResult(
            segmentStart: segmentOrigin,
            segmentEnd: segmentEndPTS,
            nextSegmentStart: resolvedNextStart
        )
        exportFinishedOK = true
    }

    private static func appendAudioPassthrough(
        asset: AVURLAsset,
        readerStart: CMTime,
        rangeStart: CMTime,
        rangeEnd: CMTime,
        segmentOrigin: CMTime,
        writerContext: SegmentWriterContext,
        sourceLabel: String,
        isCancelled: (() -> Bool)?,
        log: @escaping (String) -> Void
    ) async {
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            log("No audio track on source — finishing video-only segment (\(sourceLabel))")
            writerContext.abandonAudio()
            return
        }
        let audioReader: AVAssetReader
        do {
            audioReader = try AVAssetReader(asset: asset)
        } catch {
            log("Audio reader could not open (\(sourceLabel)) — video-only segment")
            writerContext.abandonAudio()
            return
        }
        defer { audioReader.cancelReading() }
        audioReader.timeRange = CMTimeRange(start: readerStart, end: rangeEnd)
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        audioOutput.alwaysCopiesSampleData = true
        guard audioReader.canAdd(audioOutput) else {
            log("Audio reader output not added — video-only segment")
            writerContext.abandonAudio()
            return
        }
        audioReader.add(audioOutput)
        guard audioReader.startReading() else {
            log("Audio reader could not start (\(sourceLabel)) — video-only segment")
            writerContext.abandonAudio()
            return
        }
        let queue = DispatchQueue(label: "com.loopsegments.passthrough-audio")
        var audioSamples = 0
        while let sample = await copyNextSample(on: queue, from: audioOutput) {
            if isCancelled?() == true { return }
            if audioReader.status == .failed { break }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if CMTimeCompare(pts, rangeStart) < 0 { continue }
            if CMTimeCompare(pts, rangeEnd) >= 0 { break }
            do {
                let timed = try SegmentSampleTiming.retimeToSegmentStart(sample, subtract: segmentOrigin)
                try await writerContext.append(
                    timed,
                    track: .audio,
                    isCancelled: isCancelled,
                    log: log
                )
                audioSamples += 1
            } catch SegmentExporterError.writerAudioStall {
                log("Audio writer stalled (\(sourceLabel)) — video-only segment")
                writerContext.abandonAudio()
                return
            } catch SegmentExporterError.writerFailed(let underlying) {
                log(
                    "Audio passthrough failed (\(sourceLabel)): \(underlying.localizedDescription) — video-only segment"
                )
                writerContext.abandonAudio()
                return
            } catch {
                log("Audio passthrough error (\(sourceLabel)) — video-only segment")
                writerContext.abandonAudio()
                return
            }
        }
        if audioSamples > 0 {
            log("Audio passthrough — \(audioSamples) AAC samples muxed (aligned to video segment start)")
        } else {
            log("No audio samples in window — video-only segment")
            writerContext.abandonAudio()
        }
    }

    /// Fallback when manual reader/writer returns -11800 on a fully local file (Apple-maintained passthrough mux).
    static func exportWindowViaExportSession(
        asset: AVURLAsset,
        rangeStart: CMTime,
        rangeDuration: CMTime,
        outputURL: URL,
        sourceLabel: String,
        log: @escaping (String) -> Void
    ) async throws -> SegmentPassThroughResult {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw SegmentExporterError.writerSetupFailed
        }
        try? FileManager.default.removeItem(at: outputURL)
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.timeRange = CMTimeRange(start: rangeStart, duration: rangeDuration)
        session.shouldOptimizeForNetworkUse = false
        log(
            "Staging \(outputURL.lastPathComponent) via AVAssetExportSession passthrough " +
                "(\(sourceLabel), media \(formatMediaTime(rangeStart))–\(formatMediaTime(CMTimeAdd(rangeStart, rangeDuration))))"
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }
        switch session.status {
        case .completed:
            let bytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?
                .int64Value ?? 0
            guard bytes > 0 else {
                throw SegmentExporterError.segmentOutputTooSmall(0)
            }
            log("AVAssetExportSession passthrough finished (\(formatBytes(bytes)))")
            let end = CMTimeAdd(rangeStart, rangeDuration)
            return SegmentPassThroughResult(
                segmentStart: rangeStart,
                segmentEnd: end,
                nextSegmentStart: end
            )
        case .failed:
            let err = session.error ?? NSError(domain: "AVAssetExportSession", code: -1)
            log("AVAssetExportSession failed (\(sourceLabel)): \(err.localizedDescription)")
            throw SegmentExporterError.writerFailed(err)
        case .cancelled:
            throw SegmentExporterError.cancelled
        default:
            throw SegmentExporterError.writerSetupFailed
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        }
        return "\(bytes) B"
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
