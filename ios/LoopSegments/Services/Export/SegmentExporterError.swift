import AVFoundation
import CoreMedia
import Foundation

// MARK: - Codec support

enum CodecSupport {
    /// MP4 brands for HEVC; AVFoundation writer expects `hvc1`, sources often report `hev1`.
    private static let hev1Subtype: FourCharCode = fourCC("hev1")

    static func isHEVCVideo(_ codec: FourCharCode) -> Bool {
        codec == kCMVideoCodecType_HEVC || codec == hev1Subtype
    }

    /// Re-tag `hev1` → `hvc1` so `AVAssetWriter` accepts the same bitstream/hvcc extradata.
    static func normalizedForMP4Writer(_ format: CMFormatDescription) -> CMFormatDescription {
        let codec = CMFormatDescriptionGetMediaSubType(format)
        guard codec == hev1Subtype else { return format }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let extensions = CMFormatDescriptionGetExtensions(format) as CFDictionary?
        var out: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: dimensions.width,
            height: dimensions.height,
            extensions: extensions,
            formatDescriptionOut: &out
        )
        guard status == noErr, let out else { return format }
        return out
    }

    static func isAV1Video(_ codec: FourCharCode) -> Bool {
        if #available(iOS 16.0, *) {
            if codec == kCMVideoCodecType_AV1 {
                return true
            }
        }
        return codec == fourCC("av01") || codec == fourCC("dav1")
    }

    /// H.264 / HEVC only — AV1 probes as a track but passthrough export never yields samples on sparse WebDAV temp.
    static func canPassthroughToMP4(_ format: CMFormatDescription) -> Bool {
        let codec = CMFormatDescriptionGetMediaSubType(format)
        if isAV1Video(codec) {
            return false
        }
        return codec == kCMVideoCodecType_H264 || isHEVCVideo(codec)
    }

    static func canPassthroughAudio(_ format: CMFormatDescription) -> Bool {
        let codec = CMFormatDescriptionGetMediaSubType(format)
        return codec == kAudioFormatMPEG4AAC || codec == fourCC("mp4a")
    }

    static func fourCCString(_ format: CMFormatDescription) -> String {
        let codec = CMFormatDescriptionGetMediaSubType(format)
        let chars: [UInt8] = [
            UInt8((codec >> 24) & 0xff),
            UInt8((codec >> 16) & 0xff),
            UInt8((codec >> 8) & 0xff),
            UInt8(codec & 0xff),
        ]
        return String(bytes: chars, encoding: .ascii) ?? String(format: "0x%08x", codec)
    }

    static func fourCC(_ string: String) -> FourCharCode {
        var value: FourCharCode = 0
        for byte in string.utf8.prefix(4) {
            value = (value << 8) + FourCharCode(byte)
        }
        return value
    }
}

enum SegmentExporterError: LocalizedError {
    case cancelled
    case paused
    case readerInterrupted
    case seekPastEnd
    case noVideoTrack
    case containerProbeFailed(MediaContainerFormat)
    case unsupportedCodec(String)
    case missingFormatDescription
    case readerSetupFailed
    case readerFailed(Error)
    case writerSetupFailed
    case writerFailed(Error)
    case writerBackpressure
    case writerAudioStall
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case noKeyframeInWindow
    case timelineByteWindowMismatch(mediaTime: String)
    case segmentOutputTooSmall(Int64)
    case midFileTempUnreadable(mediaTime: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Export cancelled."
        case .paused:
            return "Export paused — tap Start export to continue from the checkpoint."
        case .readerInterrupted:
            return "pCloud read was interrupted (app did not stop). Try seek 0 min, keep app open, or use Wi‑Fi."
        case .seekPastEnd:
            return "Start position is at or past the end of the file."
        case .noVideoTrack:
            return "No video track found in this file."
        case .containerProbeFailed(let container):
            switch container {
            case .asf:
                return "Could not open this WMV/ASF file from pCloud on this device. Re-encode to MP4 or MKV with H.264 or HEVC (hvc1/hev1) and AAC."
            case .mpegTransportStream:
                return "Could not open this MPEG-TS (.ts) file from pCloud. Remux to MP4 or MKV with H.264 or HEVC and AAC, then export again."
            default:
                return "Could not open this \(container.displayName) file from pCloud. Use MP4/MKV with H.264 or HEVC (hvc1/hev1) and AAC for 60s segment export."
            }
        case .unsupportedCodec(let fourCC):
            switch fourCC.lowercased() {
            case "av01", "dav1":
                return "AV1 (\(fourCC)) is not supported for 60s MP4 segments. Re-encode the source to HEVC (hvc1/hev1) or H.264 with AAC."
            case "wmv3", "wvc1", "wmv2", "wmv1":
                return "WMV video (\(fourCC)) cannot be stream-copied to MP4 segments on iOS. Re-encode to H.264 or HEVC (hvc1/hev1) with AAC in MP4 or MKV."
            default:
                return "Codec ‘\(fourCC)’ cannot be stream-copied to MP4 on this device. Use H.264 or HEVC (hvc1/hev1) with AAC."
            }
        case .missingFormatDescription:
            return "Could not read track format from the file."
        case .readerSetupFailed:
            return "Could not read or export this minute from the temp copy. Keep the app open on Wi‑Fi until “Window on disk” appears, or try seek 0 min."
        case .readerFailed(let error):
            if isSparseContainerOpenFailure(error) {
                return """
                Could not read this minute from the temp copy (incomplete sparse MP4). \
                The app retries that minute from pCloud automatically; if this persists, try seek 0 min on Wi‑Fi.
                """
            }
            return "Read failed: \(error.localizedDescription)"
        case .writerSetupFailed:
            return "Could not start writing segment MP4."
        case .writerFailed(let error):
            let ns = error as NSError
            if ns.domain == AVFoundationErrorDomain {
                return "Write failed (AVFoundation \(ns.code)): \(error.localizedDescription)"
            }
            return "Write failed: \(error.localizedDescription)"
        case .writerBackpressure:
            return """
            Video writer not ready in time — dense-fill this minute and retry. Try seek 0 min if it keeps failing.
            """
        case .writerAudioStall:
            return "Audio writer stalled (internal — should fall back to video-only)."
        case .midFileTempUnreadable(let mediaTime, let underlying):
            return """
            Could not export the \(mediaTime) minute (\(underlying)). \
            Try seek 0 min for the first segment, or stay on cellular/Wi‑Fi until the minute is dense on disk.
            """
        case .insufficientDiskSpace(let needed, let available):
            let needMB = needed / (1024 * 1024)
            let haveMB = available / (1024 * 1024)
            return "Need ~\(needMB) MB free on iPhone storage; only ~\(haveMB) MB available. Free space in Settings → General → iPhone Storage."
        case .noKeyframeInWindow:
            return "Could not start segment on a keyframe — wait for more download or use seek 0 min."
        case .timelineByteWindowMismatch(let mediaTime):
            return """
            Dense bytes for \(mediaTime) did not contain that minute’s video (linear file offset estimate). \
            Try seek 0 min for the first segment, then later minutes, or wait for a larger dense download on Wi‑Fi/cellular.
            """
        case .segmentOutputTooSmall(let bytes):
            if bytes == 0 {
                return "Segment window was incomplete — wait for more temp download (or seek 0 min on Wi‑Fi)."
            }
            return "Segment file too small (\(bytes) B) — source window was incomplete; try again after more temp download."
        }
    }
}

func isSparseContainerOpenFailure(_ error: Error) -> Bool {
    let text = error.localizedDescription.lowercased()
    if text.contains("cannot open") { return true }
    if text.contains("operation could not be completed") { return true }
    if text.contains("file couldn't be opened") { return true }
    if text.contains("file could not be opened") { return true }
    let ns = error as NSError
    if ns.domain == AVFoundationErrorDomain, ns.code == -11828 { return true }
    if ns.domain == AVFoundationErrorDomain, ns.code == -11829 { return true }
    return false
}
