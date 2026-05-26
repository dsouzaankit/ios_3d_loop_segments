import Foundation

/// Local media files to loop (muted) for Keep Alive — real MP4 audio tracks iOS accepts more reliably than synthetic silence.
enum KeepAliveMediaSource {
    struct Candidate: Equatable {
        let url: URL
        let label: String
    }

    /// The one and only allowed Keep Alive loop source.
    static func bundledSilence() -> Candidate? {
        guard let url = Bundle.main.url(forResource: "KeepAlive_silence", withExtension: "mp3") else {
            return nil
        }
        return Candidate(url: url, label: "KeepAlive_silence.mp3")
    }

    static func firstPlayable() -> Candidate? {
        guard let candidate = bundledSilence() else { return nil }
        return isPlayableLocalMedia(candidate.url) ? candidate : nil
    }

    static func isPlayableLocalMedia(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        guard fileByteCount(url) >= 4_096 else { return false }
        let ext = url.pathExtension.lowercased()
        guard ["mp4", "m4v", "mov", "m4a", "aac", "caf", "wav", "mp3"].contains(ext) else {
            return false
        }
        return true
    }

    private static func fileByteCount(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber else { return 0 }
        return n.int64Value
    }
}
