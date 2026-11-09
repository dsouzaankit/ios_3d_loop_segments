import AVFoundation
import CoreMedia
import Foundation

enum SegmentTrackKind {
    case video
    case audio
}

final class SegmentWriterContext {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private var audioAbandoned = false

    init(
        outputURL: URL,
        videoFormat: CMFormatDescription,
        audioFormat: CMFormatDescription?,
        videoTransform: CGAffineTransform = .identity,
        realTime: Bool = true
    ) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: videoFormat
        )
        videoInput.expectsMediaDataInRealTime = realTime
        if videoTransform != .identity {
            videoInput.transform = videoTransform
        }

        if let audioFormat {
            audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: audioFormat
            )
            audioInput?.expectsMediaDataInRealTime = realTime
        } else {
            audioInput = nil
        }

        guard writer.canAdd(videoInput) else {
            throw SegmentExporterError.writerSetupFailed
        }
        writer.add(videoInput)

        if let audioInput {
            guard writer.canAdd(audioInput) else {
                throw SegmentExporterError.writerSetupFailed
            }
            writer.add(audioInput)
        }
    }

    func start(at sourceTime: CMTime) {
        writer.startWriting()
        writer.startSession(atSourceTime: sourceTime)
    }

    /// Release a failed writer so the output path can be deleted and retried (-11847 if left in `.writing`).
    func cancelIfNeeded() {
        guard writer.status == .writing else { return }
        videoInput.markAsFinished()
        writer.cancelWriting()
    }

    private static let writerReadyTimeoutSeconds: Double = 30
    private static let writerReadyLogIntervalSeconds: Double = 10

    /// Stop accepting audio samples; writer keeps video track open.
    func abandonAudio() {
        guard let audioInput, !audioAbandoned else { return }
        audioAbandoned = true
        audioInput.markAsFinished()
    }

    func append(
        _ sample: CMSampleBuffer,
        track: SegmentTrackKind,
        isCancelled: (() -> Bool)? = nil,
        log: ((String) -> Void)? = nil
    ) async throws {
        let input: AVAssetWriterInput
        switch track {
        case .video: input = videoInput
        case .audio:
            guard let audioInput, !audioAbandoned else { return }
            input = audioInput
        }

        let waitStart = CFAbsoluteTimeGetCurrent()
        var lastWaitLog = waitStart
        while !input.isReadyForMoreMediaData {
            if isCancelled?() == true {
                throw SegmentExporterError.cancelled
            }
            let now = CFAbsoluteTimeGetCurrent()
            if now - waitStart >= Self.writerReadyTimeoutSeconds {
                if track == .audio {
                    throw SegmentExporterError.writerAudioStall
                }
                throw SegmentExporterError.writerBackpressure
            }
            if now - lastWaitLog >= Self.writerReadyLogIntervalSeconds {
                lastWaitLog = now
                log?(
                    String(
                        format: "Writer waiting for ready — %.0fs (\(track))",
                        now - waitStart
                    )
                )
            }
            await Task.yield()
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        guard input.append(sample) else {
            let err = writer.error ?? NSError(domain: "SegmentWriter", code: -1)
            throw SegmentExporterError.writerFailed(err)
        }
    }

    func finish() async throws {
        videoInput.markAsFinished()
        if !audioAbandoned {
        audioInput?.markAsFinished()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        if writer.status == .failed {
            throw writer.error.map { SegmentExporterError.writerFailed($0) }
                ?? SegmentExporterError.writerSetupFailed
        }
    }
}
