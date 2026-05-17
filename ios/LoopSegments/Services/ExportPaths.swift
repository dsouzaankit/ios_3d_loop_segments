import Foundation

enum ExportPaths {
    static let segmentPattern = "3d_op_%02d.mp4"
    static let segmentDurationSeconds = 60
    static let segmentFileCount = 2

    static func segmentURL(index: Int) -> URL {
        let name = String(format: segmentPattern, index % segmentFileCount)
        return exportsDirectory.appendingPathComponent(name)
    }

    static var exportsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var segmentOutputPath: String {
        exportsDirectory.appendingPathComponent(segmentPattern).path
    }

    /// Under `Exports/` so USB / Apple Devices on Windows can see logs (sibling `Documents/Logs` is often hidden).
    static var logsDirectory: URL {
        let dir = exportsDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var latestLogURL: URL {
        exportsDirectory.appendingPathComponent("export_latest.log")
    }

    /// Duplicate as `.txt` — Windows USB / Apple Devices often lists `.txt` in `Exports` but not `.log`.
    static var latestLogTextURL: URL {
        exportsDirectory.appendingPathComponent("export_latest.txt")
    }

    /// Last log line only — useful when PC caches `export_latest.txt`.
    static var exportProgressURL: URL {
        exportsDirectory.appendingPathComponent("export_progress.txt")
    }

    /// Full remote MP4 copied here before `AVAssetReader` (deleted after export).
    static var workingSourceURL: URL {
        exportsDirectory.appendingPathComponent("_export_source_working.mp4")
    }

    /// Call at launch so `Exports/` exists; writes a tiny probe file (non-zero in Files if sharing works).
    static func ensureExportDirectories() {
        _ = exportsDirectory
        _ = logsDirectory
        let probe = exportsDirectory.appendingPathComponent("loop_segments_ok.txt")
        let text = "Loop Segments \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") \(ISO8601DateFormatter().string(from: Date()))\n"
        if let data = text.data(using: .utf8) {
            try? data.write(to: probe, options: .atomic)
        }
    }
}
