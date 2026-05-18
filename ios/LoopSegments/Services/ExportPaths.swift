import Foundation

enum ExportPaths {
    static let segmentPattern = "3d_op_%02d.mp4"
    static let segmentDurationSeconds = 60
    /// One rotating file on the phone; PC DLNA pair (`3d_op_00` / `3d_op_01`) is built by `Sync-FromIPhonePhotos.ps1`.
    static let segmentFileCount = 1

    static func segmentURL(index: Int) -> URL {
        let name = String(format: segmentPattern, index % segmentFileCount)
        return exportsDirectory.appendingPathComponent(name)
    }

    /// Finished segment before wall-clock publish to `3d_op_*.mp4` (DLNA must not see partial slot files).
    static func segmentStagingURL(index: Int) -> URL {
        let name = String(format: "3d_op_%02d.staging.mp4", index % segmentFileCount)
        return exportsDirectory.appendingPathComponent(name)
    }

    /// Replace DLNA slot atomically after staging + wall-clock schedule (one update per ~60s).
    static func publishSegmentToDLNA(slot: Int, log: ((String) -> Void)? = nil) throws {
        let staging = segmentStagingURL(index: slot)
        let final = segmentURL(index: slot)
        guard FileManager.default.fileExists(atPath: staging.path) else {
            throw SegmentExporterError.writerSetupFailed
        }
        if FileManager.default.fileExists(atPath: final.path) {
            try FileManager.default.removeItem(at: final)
        }
        try FileManager.default.moveItem(at: staging, to: final)
        log?("DLNA slot \(final.lastPathComponent) published (~60s wall-clock cadence)")
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

    /// Full remote MP4 while downloading; removed with segment cleanup (Stop / background / export end).
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

    /// Remove prior export log snapshots so `export_latest.txt` / `export_progress.txt` only reflect this run.
    static func clearLogsForNewExport(log: ((String) -> Void)? = nil) {
        _ = exportsDirectory
        _ = logsDirectory
        let fm = FileManager.default

        for url in [latestLogTextURL, latestLogURL, exportProgressURL] {
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                log?("Cleared \(url.lastPathComponent)")
            } catch {
                log?("Could not clear \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if let names = try? fm.contentsOfDirectory(atPath: exportsDirectory.path) {
            for name in names where name.hasPrefix("export_session_") {
                let url = exportsDirectory.appendingPathComponent(name)
                try? fm.removeItem(at: url)
                log?("Cleared \(name)")
            }
        }

        if let names = try? fm.contentsOfDirectory(atPath: logsDirectory.path) {
            for name in names where name.hasPrefix("export_") {
                let url = logsDirectory.appendingPathComponent(name)
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Call at launch so `Exports/` exists; writes a tiny probe file (non-zero in Files if sharing works).
    static func ensureExportDirectories() {
        _ = exportsDirectory
        _ = logsDirectory
        SearchDebugLog.ensureReady()
        _ = removeWorkingSourceCopy()
        let probe = exportsDirectory.appendingPathComponent("loop_segments_ok.txt")
        let text = "Loop Segments \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") \(ISO8601DateFormatter().string(from: Date()))\n"
        if let data = text.data(using: .utf8) {
            try? data.write(to: probe, options: .atomic)
        }
    }
}
