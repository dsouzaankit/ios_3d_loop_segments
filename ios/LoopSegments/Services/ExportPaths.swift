import Foundation

enum ExportPaths {
    static let segmentPattern = "op_%02d.mp4"
    static let segmentDurationSeconds = 60
    /// Anchor folder for DLNA navigation (`L:\…\pcld_ios_media\`). Holds `_working.mp4`; segments live in `loop/`.
    static let mediaExportFolderName = "pcld_ios_media"
    /// Alternating segment slots for DLNA looping — `Exports/pcld_ios_media/loop/`.
    static let segmentLoopFolderName = "loop"
    /// Two slots rotating under `pcld_ios_media/loop/` — PC sees both via rclone mount (`Mount-LoopSegmentsRclone.ps1`).
    static let segmentFileCount = 2

    /// Creates `Exports/pcld_ios_media/`.
    static var mediaExportDirectory: URL {
        let dir = exportsDirectory.appendingPathComponent(mediaExportFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates `Exports/pcld_ios_media/loop/` (segment pair for players that loop a folder).
    static var segmentLoopDirectory: URL {
        let dir = mediaExportDirectory.appendingPathComponent(segmentLoopFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Path under `Exports/` for WebDAV and LAN ( POSIX, no leading slash).
    static func pathRelativeToExports(_ url: URL) -> String {
        let base = exportsDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return url.lastPathComponent }
        var rel = String(path.dropFirst(base.count))
        while rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
        return rel.isEmpty ? url.lastPathComponent : rel
    }

    /// Join `Exports/` + relative path segments (avoids `appendingPathComponent` with embedded `/`).
    static func urlUnderExports(relativePath: String) -> URL {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var url = exportsDirectory
        guard !trimmed.isEmpty else { return exportsDirectory }
        for segment in trimmed.split(separator: "/") {
            url = url.appendingPathComponent(String(segment))
        }
        return url
    }

    /// Legacy name: segment output directory (`pcld_ios_media/loop/`).
    static var loopDirectory: URL { segmentLoopDirectory }

    static func segmentRelativePath(index: Int) -> String {
        let name = String(format: segmentPattern, index % segmentFileCount)
        return "\(mediaExportFolderName)/\(segmentLoopFolderName)/\(name)"
    }

    static func segmentURL(index: Int) -> URL {
        let name = String(format: segmentPattern, index % segmentFileCount)
        return segmentLoopDirectory.appendingPathComponent(name)
    }

    /// Finished segment before wall-clock publish to `pcld_ios_media/loop/op_*.mp4` (LAN must not list staging files).
    static func segmentStagingURL(index: Int) -> URL {
        let finalName = String(format: segmentPattern, index % segmentFileCount)
        let stagingName = finalName.replacingOccurrences(of: ".mp4", with: ".staging.mp4")
        return segmentLoopDirectory.appendingPathComponent(stagingName)
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

    /// Sparse full-source temp under `pcld_ios_media/` (sibling of `loop/`); replaced when a new export starts.
    static var workingSourceURL: URL {
        mediaExportDirectory.appendingPathComponent("_working.mp4")
    }

    static var workingSourceManifestURL: URL {
        mediaExportDirectory.appendingPathComponent("_working.sparse.json")
    }

    /// Progressive pCloud HLS transcode (real MP4 on disk). Not sparse; separate from `_working.mp4`.
    static var workingTranscodedURL: URL {
        mediaExportDirectory.appendingPathComponent("_working_pcloud_transcode.mp4")
    }

    /// Full WebDAV copy with original extension (`_vanilla_download.wmv`, etc.).
    static func vanillaDownloadURL(preservingExtensionFrom filename: String) -> URL {
        let ext = (filename as NSString).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = ext.isEmpty ? "bin" : ext.lowercased()
        return mediaExportDirectory.appendingPathComponent("_vanilla_download.\(suffix)")
    }

    /// Faststart MP4 derived from vanilla download (separate file; vanilla bytes unchanged).
    static var vanillaFastStartURL: URL {
        mediaExportDirectory.appendingPathComponent("_vanilla_faststart.mp4")
    }

    private static let lanMediaPrefix = "\(mediaExportFolderName)/"

    /// Extensions served from `pcld_ios_media/` on home LAN (matches browser video list).
    static var lanBrowsableMediaExtensions: Set<String> {
        WebDAVItem.videoExtensions.union(["m2ts", "mts"])
    }

    /// Staging, sparse manifest, and temp remux files must not be served.
    static func isExcludedFromLANMediaServe(fileName: String) -> Bool {
        let lower = fileName.lowercased()
        if lower.hasPrefix(".") { return true }
        if lower.contains(".staging.") { return true }
        if lower.hasSuffix(".sparse.json") { return true }
        if lower.hasPrefix(".faststart-") { return true }
        if lower.hasPrefix("_working_pcloud_transcode.staging") { return true }
        return false
    }

    static func vanillaDownloadCopyExistsOnDisk() -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: mediaExportDirectory.path) else { return false }
        return names.contains { $0.lowercased().hasPrefix("_vanilla_download.") }
    }

    /// Hide stale sparse `_working.mp4` on LAN while vanilla (or transcode) is the active source.
    static func shouldHideSparseWorkingFromLAN() -> Bool {
        if ExportPlaybackState.shared.usesVanillaDownloadForLAN() { return true }
        if ExportPlaybackState.shared.usesPCloudTranscodedWorkingForLAN() { return true }
        if vanillaDownloadCopyExistsOnDisk(), ExportPlaybackState.shared.isLANExportActive { return true }
        return false
    }

    static func isLANBrowsableMediaFile(fileName: String) -> Bool {
        if fileName == "_working.mp4", shouldHideSparseWorkingFromLAN() { return false }
        guard !isExcludedFromLANMediaServe(fileName: fileName) else { return false }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return lanBrowsableMediaExtensions.contains(ext)
    }

    /// All playable media under `pcld_ios_media/` (recursive). New files appear on LAN without allowlist updates.
    static func lanBrowsableMediaRelativePaths() -> [String] {
        let fm = FileManager.default
        let root = mediaExportDirectory
        guard fm.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            let name = url.lastPathComponent
            guard isLANBrowsableMediaFile(fileName: name) else { continue }
            paths.append(pathRelativeToExports(url))
        }
        return paths.sorted()
    }

    static func isLANBrowsableMediaRelativePath(_ relativePath: String) -> Bool {
        guard relativePath.hasPrefix(lanMediaPrefix), !relativePath.contains("..") else { return false }
        let fileName = (relativePath as NSString).lastPathComponent
        return isLANBrowsableMediaFile(fileName: fileName)
    }

    /// LAN / index path while export uses pCloud transcode instead of sparse WebDAV mirror.
    static var lanInProgressWorkingRelativePath: String {
        if ExportPlaybackState.shared.usesVanillaDownloadForLAN() {
            return ExportPlaybackState.shared.vanillaLANRelativePath()
        }
        if ExportPlaybackState.shared.usesPCloudTranscodedWorkingForLAN() {
            return pathRelativeToExports(workingTranscodedURL)
        }
        return pathRelativeToExports(workingSourceURL)
    }

    /// Drop stale vanilla files when the export item changed; keep partial/complete copy for the same `fileKey` + size.
    static func syncVanillaDownloadWithExportItem(
        item: WebDAVItem,
        totalLength: Int64,
        log: ((String) -> Void)? = nil
    ) {
        let destination = vanillaDownloadURL(preservingExtensionFrom: item.name)
        if totalLength > 0,
           FileManager.default.fileExists(atPath: destination.path),
           VanillaDownloadResumeCatalog.matches(fileKey: item.fileKey, totalLength: totalLength)
               || VanillaDownloadResumeCatalog.matchesAfterRename(item: item, totalLength: totalLength) {
            if !VanillaDownloadResumeCatalog.matches(fileKey: item.fileKey, totalLength: totalLength) {
                VanillaDownloadResumeCatalog.save(
                    fileKey: item.fileKey,
                    totalLength: totalLength,
                    href: item.href
                )
                log?(
                    "Vanilla resume — same file after pCloud rename " +
                        "(updated manifest for \(item.name))"
                )
            }
            pruneVanillaDownloadCopies(keepingDestination: destination, log: log)
            return
        }
        removeVanillaDownloadCopies(log: log)
    }

    /// Remove other `_vanilla_download.<ext>` files; keep the destination for the current export.
    static func pruneVanillaDownloadCopies(keepingDestination keep: URL, log: ((String) -> Void)? = nil) {
        let fm = FileManager.default
        guard let listed = try? fm.contentsOfDirectory(at: mediaExportDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in listed {
            let name = url.lastPathComponent.lowercased()
            guard name.hasPrefix("_vanilla_download."), url != keep else { continue }
            do {
                try fm.removeItem(at: url)
                log?("Removed stale \(pathRelativeToExports(url))")
            } catch {
                log?("Could not remove \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    static func removeVanillaDownloadCopies(log: ((String) -> Void)? = nil) -> Bool {
        let fm = FileManager.default
        var removed = false
        VanillaDownloadResumeCatalog.remove()
        var urls: [URL] = [vanillaFastStartURL]
        if let listed = try? fm.contentsOfDirectory(at: mediaExportDirectory, includingPropertiesForKeys: nil) {
            for url in listed {
                let name = url.lastPathComponent.lowercased()
                guard name.hasPrefix("_vanilla_download.") else { continue }
                urls.append(url)
            }
        }
        for url in urls {
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                removed = true
                log?("Removed \(pathRelativeToExports(url))")
            } catch {
                log?("Could not remove \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !vanillaDownloadCopyExistsOnDisk() {
            ExportPlaybackState.shared.setVanillaDownloadActive(false)
        }
        return removed
    }

    /// Rename legacy export filenames from older builds (idempotent).
    static func migrateLegacyExportFilenames(log: ((String) -> Void)? = nil) {
        let fm = FileManager.default
        _ = segmentLoopDirectory

        // Legacy layout: Exports/_working.* → pcld_ios_media/; Exports/loop/* and flat pcld_ios_media/op_* → pcld_ios_media/loop/
        let rootWorking = exportsDirectory.appendingPathComponent("_working.mp4")
        let rootManifest = exportsDirectory.appendingPathComponent("_working.sparse.json")
        for (src, dst) in [(rootWorking, workingSourceURL), (rootManifest, workingSourceManifestURL)] {
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            do {
                try fm.moveItem(at: src, to: dst)
                log?("Migrated \(src.lastPathComponent) → \(pathRelativeToExports(dst))")
            } catch {
                log?("Could not migrate \(src.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let oldLoop = exportsDirectory.appendingPathComponent("loop", isDirectory: true)
        if fm.fileExists(atPath: oldLoop.path),
           let loopNames = try? fm.contentsOfDirectory(atPath: oldLoop.path) {
            for name in loopNames {
                let src = oldLoop.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                let dst = segmentLoopDirectory.appendingPathComponent(name)
                guard !fm.fileExists(atPath: dst.path) else { continue }
                do {
                    try fm.moveItem(at: src, to: dst)
                    log?("Migrated loop/\(name) → \(pathRelativeToExports(dst))")
                } catch {
                    log?("Could not migrate loop/\(name): \(error.localizedDescription)")
                }
            }
            if let left = try? fm.contentsOfDirectory(atPath: oldLoop.path), left.isEmpty {
                try? fm.removeItem(at: oldLoop)
            }
        }

        /// Flat segment files directly under `pcld_ios_media/` (older nested layout) → `pcld_ios_media/loop/`.
        if let flatNames = try? fm.contentsOfDirectory(atPath: mediaExportDirectory.path) {
            for name in flatNames where name != segmentLoopFolderName {
                let src = mediaExportDirectory.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                let isSegment =
                    name.hasPrefix("op_")
                    && (name.hasSuffix(".mp4") || name.contains(".staging"))
                guard isSegment else { continue }
                let dst = segmentLoopDirectory.appendingPathComponent(name)
                guard !fm.fileExists(atPath: dst.path) else { continue }
                do {
                    try fm.moveItem(at: src, to: dst)
                    log?("Migrated \(mediaExportFolderName)/\(name) → \(pathRelativeToExports(dst))")
                } catch {
                    log?("Could not migrate \(name): \(error.localizedDescription)")
                }
            }
        }

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
                log?("Migrated \(legacyName) → \(pathRelativeToExports(destination))")
            } catch {
                log?("Could not migrate \(legacyName): \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    static func removeTranscodedWorkingCopy(log: ((String) -> Void)? = nil) -> Bool {
        let fm = FileManager.default
        let url = workingTranscodedURL
        guard fm.fileExists(atPath: url.path) else { return false }
        do {
            try fm.removeItem(at: url)
            log?("Removed \(url.lastPathComponent) from Exports")
            return true
        } catch {
            log?("Could not remove \(url.lastPathComponent): \(error.localizedDescription)")
            return false
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
        func appendFile(at url: URL, label: String) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            parts.append("\(label) \(formatter.string(fromByteCount: size))")
        }
        func appendMP4(at url: URL, label: String) {
            appendFile(at: url, label: label)
        }
        for name in names.sorted() where name.hasSuffix(".mp4") {
            appendMP4(at: dir.appendingPathComponent(name), label: name)
        }
        let mediaDir = dir.appendingPathComponent(mediaExportFolderName)
        for rel in lanBrowsableMediaRelativePaths() {
            let url = urlUnderExports(relativePath: rel)
            appendFile(at: url, label: rel)
        }
        let transcoded = workingTranscodedURL
        if fm.fileExists(atPath: transcoded.path) {
            appendMP4(at: transcoded, label: pathRelativeToExports(transcoded))
        }
        let loopDir = dir.appendingPathComponent(mediaExportFolderName).appendingPathComponent(segmentLoopFolderName)
        if let loopNames = try? fm.contentsOfDirectory(atPath: loopDir.path) {
            for name in loopNames.sorted() where name.hasSuffix(".mp4") {
                appendMP4(
                    at: loopDir.appendingPathComponent(name),
                    label: "\(mediaExportFolderName)/\(segmentLoopFolderName)/\(name)"
                )
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
        _ = mediaExportDirectory
        _ = segmentLoopDirectory
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
