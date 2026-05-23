import Foundation

/// How to prefetch and probe a remote file before sparse `_working.mp4` export.
enum MediaContainerFormat: Equatable {
    case mp4
    case asf
    case avi
    case matroska
    case webm
    case mpegTransportStream
    case other(extension: String)

    static func from(filename: String, headBytes: Data? = nil) -> MediaContainerFormat {
        if let magic = detectFromMagic(headBytes) {
            return magic
        }
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "m4v", "mov":
            return .mp4
        case "wmv", "asf":
            return .asf
        case "avi":
            return .avi
        case "mkv":
            return .matroska
        case "webm":
            return .webm
        case "ts", "m2ts", "mts":
            return .mpegTransportStream
        default:
            return .other(extension: ext.isEmpty ? "unknown" : ext)
        }
    }

    private static func detectFromMagic(_ data: Data?) -> MediaContainerFormat? {
        guard let data, data.count >= 12 else { return nil }
        if data.starts(with: [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) {
            return .asf
        }
        if data.count >= 8 {
            let box = String(data: data.subdata(in: 4 ..< 8), encoding: .ascii)
            if box == "ftyp" || box == "moov" || box == "wide" {
                return .mp4
            }
        }
        if data.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            return .matroska
        }
        if data.starts(with: [0x47]) {
            return .mpegTransportStream
        }
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]), data.count >= 12 {
            let form = String(data: data.subdata(in: 8 ..< 12), encoding: .ascii)
            if form == "AVI " {
                return .avi
            }
        }
        return nil
    }

    var displayName: String {
        switch self {
        case .mp4: return "MP4"
        case .asf: return "WMV/ASF"
        case .avi: return "AVI"
        case .matroska: return "MKV"
        case .webm: return "WebM"
        case .mpegTransportStream: return "MPEG-TS"
        case .other(let ext): return ext.uppercased()
        }
    }

    /// Sparse `_working.mp4` is MP4-shaped; non-MP4 containers must probe over pCloud with the real filename.
    var probesSparseTempAsMP4: Bool {
        self == .mp4
    }

    /// AVFoundation segment export (`op_00`/`op_01`) — WMV/MKV/etc. stay vanilla-only on device.
    var supportsIOSegmentExport: Bool {
        self == .mp4
    }

    var needsMP4IndexAtEOF: Bool {
        switch self {
        case .mp4, .matroska:
            return true
        default:
            return false
        }
    }

    var prefetchHeadBytes: Int64 {
        switch self {
        case .mp4:
            return 512 * 1024
        case .asf, .avi:
            return 8 * 1024 * 1024
        case .matroska, .webm:
            return 4 * 1024 * 1024
        case .mpegTransportStream:
            return 4 * 1024 * 1024
        case .other:
            return 2 * 1024 * 1024
        }
    }

    var prefetchTailBytes: Int64? {
        needsMP4IndexAtEOF ? 2 * 1024 * 1024 : nil
    }
}
