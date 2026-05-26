import AVFoundation
import Foundation

/// One-minute silent audio on disk (CAF); `AVPlayerLooper` repeats it for lock-screen keep-alive.
enum SilentKeepAliveAudioGenerator {
    static let cacheFileName = "KeepAlive_1min.caf"
    private static let sampleRate = 44_100.0
    private static let durationSeconds = 60.0

    enum GeneratorError: Error {
        case format
        case buffer
    }

    static func ensureFileURL() throws -> URL {
        let url = ExportPaths.keepAliveAudioDirectory.appendingPathComponent(cacheFileName)
        if FileManager.default.fileExists(atPath: url.path) {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
                .int64Value ?? 0
            if bytes > 1_000 { return url }
        }
        try writeSilentCAF(url: url)
        return url
    }

    private static func writeSilentCAF(url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw GeneratorError.format
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let framesTotal = AVAudioFrameCount(durationSeconds * sampleRate)
        let chunk: AVAudioFrameCount = 4_096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw GeneratorError.buffer
        }
        var written: AVAudioFrameCount = 0
        while written < framesTotal {
            let frameCount = min(chunk, framesTotal - written)
            buffer.frameLength = frameCount
            if let channel = buffer.int16ChannelData?[0] {
                memset(channel, 0, Int(frameCount) * MemoryLayout<Int16>.size)
            }
            try file.write(from: buffer)
            written += frameCount
        }
    }
}
