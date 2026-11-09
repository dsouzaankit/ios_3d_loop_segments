import AVFoundation
import CoreMedia
import Foundation

/// Error classification and decision rules (unit-tested in SegmentExporterRulesTests).
extension SegmentExporter {
    static func isWriterSampleRejection(_ error: Error) -> Bool {
        isRetriablePassthroughWriterFailure(error)
    }

    static func isUnsupportedAssetURLError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorUnsupportedURL { return true }
        return error.localizedDescription.lowercased().contains("unsupported url")
    }

    static func isHybridReaderOpenFailure(_ error: Error) -> Bool {
        let underlying: Error = {
            if case SegmentExporterError.readerFailed(let err) = error { return err }
            return error
        }()
        let text = underlying.localizedDescription.lowercased()
        if text.contains("operation stopped") || text.contains("cannot open") {
            return true
        }
        let ns = underlying as NSError
        return ns.domain == AVFoundationErrorDomain
    }

    static func isRetriablePassthroughWriterFailure(_ error: Error) -> Bool {
        guard case SegmentExporterError.writerFailed(let underlying) = error else { return false }
        let ns = underlying as NSError
        if ns.domain == AVFoundationErrorDomain {
            switch ns.code {
            case -11800, -11847:
                return true
            default:
                break
            }
        }
        let text = underlying.localizedDescription.lowercased()
        return text.contains("could not be completed") || text.contains("operation interrupted")
    }

    static func isAudioWriterRejection(_ error: Error, track: SegmentTrackKind) -> Bool {
        track == .audio && isRetriablePassthroughWriterFailure(error)
    }

    func formatSeekMs(_ ms: Int64) -> String {
        ExportTimelineLog.wallClock(seconds: Double(max(0, ms)) / 1000.0)
    }

    func formatMediaTimeForLog(_ time: CMTime) -> String {
        let seconds = CMTimeGetSeconds(time)
        let min = Int(seconds) / 60
        let sec = Int(seconds) % 60
        return String(format: "%d:%02d", min, sec)
    }

    static let midFilePrefetchThresholdBytes: Int64 = 32 * 1024 * 1024
    /// High-bitrate HEVC minute windows (e.g. ~700 MB/min) stall manual `AVAssetWriter`; use export session on disk.
    static let denseHEVCExportSessionWindowBytes: Int64 = 256 * 1024 * 1024

    static func shouldPreferExportSessionForDenseHEVCWindow(
        byteRange: TimelineByteRange,
        videoFormat: CMFormatDescription
    ) -> Bool {
        isHEVCFormat(videoFormat) && byteRange.length >= denseHEVCExportSessionWindowBytes
    }

    func exportDenseOnDiskViaExportSession(
        tempURL: URL,
        rangeStart: CMTime,
        rangeDuration: CMTime,
        outputURL: URL,
        sourceLabel: String,
        log: @escaping (String) -> Void
    ) async throws -> SegmentPassThroughResult {
        let fileAsset = AVURLAsset(
            url: tempURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        return try await SegmentPassThroughExporter.exportWindowViaExportSession(
            asset: fileAsset,
            rangeStart: rangeStart,
            rangeDuration: rangeDuration,
            outputURL: outputURL,
            sourceLabel: sourceLabel,
            log: log
        )
    }

    static func isHEVCFormat(_ format: CMFormatDescription) -> Bool {
        CodecSupport.isHEVCVideo(CMFormatDescriptionGetMediaSubType(format))
    }
    /// At seek 0, dense-fill bytes after the minute window so `file://` passthrough does not read zero-filled mdat.
    static let seekZeroDenseEntireFileMaxBytes: Int64 = 1024 * 1024 * 1024
    static let seekZeroDenseTailMaxBytes: Int64 = 256 * 1024 * 1024

    static func sourceQualifiesForPCloudHLSTranscode(
        fileBytes: Int64,
        durationSeconds: Double
    ) -> Bool {
        guard fileBytes > 0, durationSeconds > 0 else { return false }
        return impliedAverageMbps(fileBytes: fileBytes, durationSeconds: durationSeconds)
            > PCloudHLSLink.transcodeMinSourceMbps
    }

    static func shouldAttemptPCloudHLSFallback(
        error: Error,
        containerFormat: MediaContainerFormat,
        fileBytes: Int64
    ) -> Bool {
        guard fileBytes > 0 else { return false }
        guard let exportError = error as? SegmentExporterError else { return false }
        switch exportError {
        case .containerProbeFailed:
            break
        case .noVideoTrack:
            guard !containerFormat.probesSparseTempAsMP4 else { return false }
        default:
            return false
        }
        // Pre-check: file must be large enough that a 45 min movie could still exceed 2.5 Mbps.
        let heuristicSeconds = 45.0 * 60.0
        return impliedAverageMbps(fileBytes: fileBytes, durationSeconds: heuristicSeconds)
            > PCloudHLSLink.transcodeMinSourceMbps
    }

    /// Per-minute failsafe: keep dense-filling the sparse temp and serving it on LAN; do not abort the whole export.
    static func shouldSkipMinuteAndContinue(after error: Error) -> Bool {
        if let exportError = error as? SegmentExporterError {
            switch exportError {
            case .cancelled, .paused, .readerInterrupted, .seekPastEnd, .noVideoTrack,
                 .containerProbeFailed, .unsupportedCodec, .missingFormatDescription, .insufficientDiskSpace:
                return false
            case .readerSetupFailed, .readerFailed, .writerSetupFailed, .writerFailed,
                 .writerBackpressure, .writerAudioStall, .noKeyframeInWindow,
                 .timelineByteWindowMismatch, .segmentOutputTooSmall, .midFileTempUnreadable:
                return true
            }
        }
        return true
    }

    static func shouldStreamFallback(after error: Error) -> Bool {
        if let exportError = error as? SegmentExporterError {
            switch exportError {
            case .readerSetupFailed, .segmentOutputTooSmall:
                return true
            case .noKeyframeInWindow, .timelineByteWindowMismatch:
                return false
            case .readerFailed(let underlying):
                return isSparseContainerOpenFailure(underlying)
            case .writerFailed, .writerBackpressure:
                return true
            case .cancelled, .paused, .readerInterrupted, .seekPastEnd, .noVideoTrack, .containerProbeFailed,
                 .unsupportedCodec, .missingFormatDescription, .writerSetupFailed, .writerAudioStall,
                 .insufficientDiskSpace, .midFileTempUnreadable:
                return false
            }
        }
        return isSparseContainerOpenFailure(error)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", Double(bytes) / 1_073_741_824.0)
        }
        if bytes >= 1024 * 1024 {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
        }
        return "\(bytes) B"
    }
}
