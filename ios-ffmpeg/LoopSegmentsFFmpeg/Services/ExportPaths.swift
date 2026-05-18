import Foundation

enum ExportPaths {
    static let segmentPattern = "3d_op_%02d.mp4"
    static let segmentDurationSeconds = 60
    static let segmentFileCount = 2

    static func segmentURL(index: Int) -> URL {
        let name = String(format: segmentPattern, index % segmentFileCount)
        return exportsDirectory.appendingPathComponent(name)
    }

    static func segmentStagingURL(index: Int) -> URL {
        let name = String(format: "3d_op_%02d.staging.mp4", index % segmentFileCount)
        return exportsDirectory.appendingPathComponent(name)
    }

    static func publishSegmentToDLNA(slot: Int, log: ((String) -> Void)? = nil) throws {
        let staging = segmentStagingURL(index: slot)
        let final = segmentURL(index: slot)
        guard FileManager.default.fileExists(atPath: staging.path) else {
            throw ExportPathsError.missingStagingFile
        }
        if FileManager.default.fileExists(atPath: final.path) {
            try FileManager.default.removeItem(at: final)
        }
        try FileManager.default.moveItem(at: staging, to: final)
        log?("DLNA slot \(final.lastPathComponent) published")
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

    static var logsDirectory: URL {
        let dir = exportsDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var latestLogURL: URL {
        exportsDirectory.appendingPathComponent("export_latest.log")
    }

    static var latestLogTextURL: URL {
        exportsDirectory.appendingPathComponent("export_latest.txt")
    }

    static var exportProgressURL: URL {
        exportsDirectory.appendingPathComponent("export_progress.txt")
    }

    static var workingSourceURL: URL {
        exportsDirectory.appendingPathComponent("_export_source_working.mp4")
    }

    @discardableResult
    static func removeWorkingSourceCopy(log: ((String) -> Void)? = nil) -> Bool {
        let url = workingSourceURL
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            log?("Removed \(url.lastPathComponent) from Exports")
            return true
        } catch {
            log?("Could not remove \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    static func ensureExportDirectories() {
        _ = exportsDirectory
        _ = logsDirectory
        _ = removeWorkingSourceCopy()
        let probe = exportsDirectory.appendingPathComponent("loop_segments_ok.txt")
        let text = "Loop Segments FFmpeg \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") \(ISO8601DateFormatter().string(from: Date()))\n"
        if let data = text.data(using: .utf8) {
            try? data.write(to: probe, options: .atomic)
        }
    }
}

enum ExportPathsError: Error {
    case missingStagingFile
}
