import Foundation

enum ExportPaths {
    static let segmentPattern = "op_%02d.mp4"
    static let segmentDurationSeconds = 60
    static let loopDirectoryName = "loop"
    /// Two slots under `Exports/loop/` — PC sees both via rclone mount (`Mount-LoopSegmentsRclone.ps1`).
    static let segmentFileCount = 2

    static var loopDirectory: URL {
        let dir = exportsDirectory.appendingPathComponent(loopDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func segmentRelativePath(index: Int) -> String {
        let name = String(format: segmentPattern, index % segmentFileCount)
        return "\(loopDirectoryName)/\(name)"
    }

    static func segmentURL(index: Int) -> URL {
        let name = String(format: segmentPattern, index % segmentFileCount)
        return loopDirectory.appendingPathComponent(name)
    }

    /// Finished segment before wall-clock publish to `loop/op_*.mp4` (LAN must not list staging files).
    static func segmentStagingURL(index: Int) -> URL {
        let finalName = String(format: segmentPattern, index % segmentFileCount)
        let stagingName = finalName.replacingOccurrences(of: ".mp4", with: ".staging.mp4")
        return loopDirectory.appendingPathComponent(stagingName)
    }

    /// Replace DLNA slot atomically after staging + wall-clock schedule (one update per ~60s).
    static func publishSegmentToDLNA(slot: Int, log: ((String) -> Void)? = nil) throws {
        let staging = segmentStagingURL(index: slot)
        let final = segmentURL(index: slot)
        let fm = FileManager.default
        guard fm.fileExists(atPath: staging.path) else {
            throw SegmentExporterError.writerSetupFailed
        }
        if fm.fileExists(atPath: final.path) {
            _ = try fm.replaceItemAt(final, withItemAt: staging, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: staging, to: final)
        }
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

    /// Sparse full-source temp at Exports root; replaced when a new export starts (kept until next export).
    static var workingSourceURL: URL {
        exportsDirectory.appendingPathComponent("_working.mp4")
    }

    static var workingSourceManifestURL: URL {
        exportsDirectory.appendingPathComponent("_working.sparse.json")
    }

    /// Rename legacy export filenames from older builds (idempotent).
    static func migrateLegacyExportFilenames(log: ((String) -> Void)? = nil) {
        let fm = FileManager.default
        _ = loopDirectory
        let legacyPairs: [(String, URL)] = [
            ("_export_source_working.mp4", workingSourceURL),
            ("_export_source_working.sparse.json", workingSourceManifestURL),
            ("op_00.mp4", segmentURL(index: 0)),
            ("op_01.mp4", segmentURL(index: 1)),
            ("op_00.staging.mp4", segmentStagingURL(index: 0)),
            ("op_01.staging.mp4", segmentStagingURL(index: 1)),
        ]
        for (legacyName, destination) in legacyPairs {
            let legacy = exportsDirectory.appendingPathComponent(legacyName)
            guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.moveItem(at: legacy, to: destination)
                log?("Migrated \(legacyName) → \(destination.path.replacingOccurrences(of: exportsDirectory.path + "/", with: ""))")
            } catch {
                log?("Could not migrate \(legacyName): \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    static func removeWorkingSourceCopy(log: ((String) -> Void)? = nil) -> Bool {
        let fm = FileManager.default
        var removed = false
        for url in [workingSourceURL, workingSourceManifestURL] {
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                removed = true
                log?("Removed \(url.lastPathComponent) from Exports")
            } catch {
                log?("Could not remove \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return removed
    }

    /// Export + search logs under `Exports/` (keeps `loop_segments_ok.txt`).
    @discardableResult
    static func clearExportLogs(log: ((String) -> Void)? = nil) -> Int {
        _ = exportsDirectory
        _ = logsDirectory
        let fm = FileManager.default
        var removed = 0

        for url in [latestLogTextURL, latestLogURL, exportProgressURL] {
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                removed += 1
                log?("Cleared \(url.lastPathComponent)")
            } catch {
                log?("Could not clear \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let searchDebug = exportsDirectory.appendingPathComponent("search_debug.txt")
        if fm.fileExists(atPath: searchDebug.path) {
            do {
                try fm.removeItem(at: searchDebug)
                removed += 1
                log?("Cleared \(searchDebug.lastPathComponent)")
            } catch {
                log?("Could not clear \(searchDebug.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if let names = try? fm.contentsOfDirectory(atPath: exportsDirectory.path) {
            for name in names where name.hasPrefix("export_session_") {
                let url = exportsDirectory.appendingPathComponent(name)
                do {
                    try fm.removeItem(at: url)
                    removed += 1
                    log?("Cleared \(name)")
                } catch {
                    log?("Could not clear \(name): \(error.localizedDescription)")
                }
            }
        }

        if let names = try? fm.contentsOfDirectory(atPath: logsDirectory.path) {
            for name in names where name.hasPrefix("export_") {
                let url = logsDirectory.appendingPathComponent(name)
                do {
                    try fm.removeItem(at: url)
                    removed += 1
                    log?("Cleared logs/\(name)")
                } catch {
                    log?("Could not clear logs/\(name): \(error.localizedDescription)")
                }
            }
        }
        return removed
    }

    /// Remove prior export log snapshots so `export_latest.txt` / `export_progress.txt` only reflect this run.
    static func clearLogsForNewExport(log: ((String) -> Void)? = nil) {
        _ = clearExportLogs(log: log)
    }

    /// Names and sizes of segment / working-source files for post-export logs and troubleshooting Files visibility.
    static func describeExportMediaOnDisk() -> String {
        let fm = FileManager.default
        let dir = exportsDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            return "Exports/: could not list directory"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        var parts: [String] = []
        func appendMP4(at url: URL, label: String) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            parts.append("\(label) \(formatter.string(fromByteCount: size))")
        }
        for name in names.sorted() where name.hasSuffix(".mp4") {
            appendMP4(at: dir.appendingPathComponent(name), label: name)
        }
        let loopDir = dir.appendingPathComponent(loopDirectoryName)
        if let loopNames = try? fm.contentsOfDirectory(atPath: loopDir.path) {
            for name in loopNames.sorted() where name.hasSuffix(".mp4") {
                appendMP4(at: loopDir.appendingPathComponent(name), label: "\(loopDirectoryName)/\(name)")
            }
        }
        if parts.isEmpty {
            return "Exports/: no .mp4 on disk — Files → On My iPhone → Loop Segments → Exports"
        }
        return "Exports on disk: " + parts.joined(separator: "; ")
    }

    /// Call at launch so `Exports/` exists; writes a tiny probe file (non-zero in Files if sharing works).
    static func ensureExportDirectories() {
        _ = exportsDirectory
        _ = loopDirectory
        _ = logsDirectory
        migrateLegacyExportFilenames()
        SearchDebugLog.ensureReady()
        let probe = exportsDirectory.appendingPathComponent("loop_segments_ok.txt")
        let text = "Loop Segments \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") \(ISO8601DateFormatter().string(from: Date()))\n"
        if let data = text.data(using: .utf8) {
            try? data.write(to: probe, options: .atomic)
        }
    }
}
