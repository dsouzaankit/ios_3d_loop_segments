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

        let reader = try AVAssetReader(asset: asset)
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
            throw reader.error.map { SegmentExporterError.readerFailed($0) }
                ?? SegmentExporterError.readerSetupFailed
        }

        try? FileManager.default.removeItem(at: outputURL)
        log("Staging \(outputURL.lastPathComponent) via \(sourceLabel) (media \(formatMediaTime(rangeStart))–\(formatMediaTime(rangeEnd)))")

        var writerContext: SegmentWriterContext?
        var heldAudio: CMSampleBuffer?
        var startedWriter = false
        var skippedBeforeKeyframe = 0

        while true {
            if reader.status == .failed {
                throw reader.error.map { SegmentExporterError.readerFailed($0) }
                    ?? SegmentExporterError.readerSetupFailed
            }

            let videoSample = videoOutput.copyNextSampleBuffer()
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
                if CMTimeCompare(pts, rangeStart) < 0 || !isSyncVideoSample(next.sample) {
                    skippedBeforeKeyframe += 1
                    continue
                }
                let ctx = try SegmentWriterContext(
                    outputURL: outputURL,
                    videoFormat: videoFormat,
                    audioFormat: audioFormat,
                    realTime: false
                )
                ctx.start(at: .zero)
                writerContext = ctx
                startedWriter = true
                if skippedBeforeKeyframe > 0 {
                    log("Skipped \(skippedBeforeKeyframe) frame(s) before first keyframe")
                }
            }

            try writerContext?.append(next.sample, track: next.track)
            if next.track == .audio {
                heldAudio = nil
            }
        }

        guard startedWriter else {
            throw SegmentExporterError.noKeyframeInWindow
        }

        if let writerContext {
            try await writerContext.finish()
        }
    }

    private static func isSyncVideoSample(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[AnyHashable: Any]],
              let first = attachments.first else {
            return true
        }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }

    private static func formatMediaTime(_ time: CMTime) -> String {
        let seconds = CMTimeGetSeconds(time)
        let min = Int(seconds) / 60
        let sec = Int(seconds) % 60
        return String(format: "%d:%02d", min, sec)
    }
}
