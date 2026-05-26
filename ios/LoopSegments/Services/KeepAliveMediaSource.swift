import Foundation

/// Local media files to loop (muted) for Keep Alive — real MP4 audio tracks iOS accepts more reliably than synthetic silence.
enum KeepAliveMediaSource {
    struct Candidate: Equatable {
        let url: URL
        let label: String
    }

    /// Prefer in-export segments, then active root media, then newest archive file.
    static func orderedCandidates() -> [Candidate] {
        var list: [Candidate] = []
        for index in 0 ..< ExportPaths.segmentFileCount {
            let url = ExportPaths.segmentURL(index: index)
            list.append(Candidate(url: url, label: url.lastPathComponent))
        }
        list.append(Candidate(url: ExportPaths.workingSourceURL, label: "_working.mp4"))
        list.append(
            Candidate(
                url: ExportPaths.workingTranscodedURL,
                label: "_working_pcloud_transcode.mp4"
            )
        )
        list.append(
            Candidate(
                url: ExportPaths.vanillaFastStartURL,
                label: "_vanilla_faststart.mp4"
            )
        )
        for url in ExportMediaArchive.activeRootMediaFiles() {
            let name = url.lastPathComponent
            if list.contains(where: { $0.url == url }) { continue }
            list.append(Candidate(url: url, label: name))
        }
        if let archive = ExportMediaArchive.newestArchivedPlayableMediaURL() {
            list.append(
                Candidate(
                    url: archive,
                    label: "archive/\(archive.lastPathComponent)"
                )
            )
        }
        // Bundled silence MP3 (https://github.com/anars/blank-audio — 1-minute-of-silence.mp3).
        if let bundled = Bundle.main.url(forResource: "KeepAlive_silence", withExtension: "mp3") {
            list.append(Candidate(url: bundled, label: "KeepAlive_silence.mp3"))
        }
        if let bundled = Bundle.main.url(forResource: "KeepAlive_tone", withExtension: "caf") {
            list.append(Candidate(url: bundled, label: "KeepAlive_tone.caf"))
        }
        return list
    }

    static func firstPlayable() -> Candidate? {
        orderedCandidates().first { isPlayableLocalMedia($0.url) }
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
