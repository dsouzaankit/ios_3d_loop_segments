import Foundation

enum ExportPaths {
    static let segmentPattern = "op_%02d.mp4"
    static let segmentDurationSeconds = 60
    /// Anchor folder for DLNA navigation (`L:\…\pcld_ios_media\`). Holds `_working.mp4`; segments live in `loop/`.
    static let mediaExportFolderName = "pcld_ios_media"
    /// Alternating segment slots for DLNA looping — `pcld_ios_media/loop/` (on disk under Application Support).
    static let segmentLoopFolderName = "loop"
    /// Export logs (live + history) — `pcld_ios_media/logs/` (private; LAN `/pcld_ios_media/logs/…` and legacy `/export_latest.txt`).
    static let exportLogsFolderName = "logs"
    /// Two slots rotating under `pcld_ios_media/loop/` — PC sees both via rclone mount (`Mount-LoopSegmentsRclone.ps1`).
    static let segmentFileCount = 2

    /// Shared logs + USB-visible files (`UIFileSharingEnabled`).
    static var exportsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Large export media — `Library/Application Support/pcld_ios_media/` (not in Files / USB; same LAN URLs).
    static var mediaExportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(mediaExportFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Volume used for free-space checks (media lives here).
    static var exportDiskSpaceCheckDirectory: URL { mediaExportDirectory }

    /// Creates `pcld_ios_media/loop/` under Application Support.
    static var segmentLoopDirectory: URL {
        let dir = mediaExportDirectory.appendingPathComponent(segmentLoopFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// LAN export triggers and PC scripts — `pcld_ios_media/scripts/`.
    static var lanExportScriptsDirectory: URL {
        let dir = mediaExportDirectory.appendingPathComponent("scripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// LAN / log label for a file URL (`pcld_ios_media/...` or `export_latest.txt`, etc.).
    static func pathRelativeToExports(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let mediaBase = mediaExportDirectory.standardizedFileURL.path
        if path == mediaBase {
            return mediaExportFolderName
        }
        if path.hasPrefix(mediaBase + "/") {
            var suffix = String(path.dropFirst(mediaBase.count))
            while suffix.hasPrefix("/") { suffix = String(suffix.dropFirst()) }
            return suffix.isEmpty ? mediaExportFolderName : "\(mediaExportFolderName)/\(suffix)"
        }
        let exportBase = exportsDirectory.standardizedFileURL.path
        guard path.hasPrefix(exportBase) else { return url.lastPathComponent }
        var rel = String(path.dropFirst(exportBase.count))
        while rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
        return rel.isEmpty ? url.lastPathComponent : rel
    }

    /// `pcld_ios_media/logs` — LAN prefix for export log files.
    static var exportLogsLANPrefix: String { "\(mediaExportFolderName)/\(exportLogsFolderName)" }

    /// Resolve LAN/log relative path to on-disk URL (media + logs → Application Support; probe → Documents/Exports).
    static func urlUnderExports(relativePath: String) -> URL {
        var trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let canonical = canonicalLANLogRelativePath(trimmed) {
            trimmed = canonical
        }
        guard !trimmed.isEmpty else { return exportsDirectory }
        if trimmed == mediaExportFolderName {
            return mediaExportDirectory
        }
        if trimmed.hasPrefix("\(mediaExportFolderName)/") {
            let suffix = String(trimmed.dropFirst(mediaExportFolderName.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var url = mediaExportDirectory
            for segment in suffix.split(separator: "/") {
                url = url.appendingPathComponent(String(segment))
            }
            return url
        }
        var url = exportsDirectory
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

    static var segmentOutputPath: String {
        exportsDirectory.appendingPathComponent(segmentPattern).path
    }

    /// How many `logs/export_<unix>.txt` files to keep (oldest removed after each new export).
    static let exportLogRetentionCount = 40

    /// `Application Support/pcld_ios_media/logs/` (not in Files; served on LAN).
    static var logsDirectory: URL {
        let dir = mediaExportDirectory.appendingPathComponent(exportLogsFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Legacy duplicate of `export_latest.txt` (removed on launch / clear; do not write).
    static var legacyLatestLogURL: URL {
        logsDirectory.appendingPathComponent("export_latest.log")
    }

    /// Live export log for the current run (LAN; not in Files app).
    static var latestLogTextURL: URL {
        logsDirectory.appendingPathComponent("export_latest.txt")
    }

    /// Last log line only — useful when PC caches `export_latest.txt`.
    static var exportProgressURL: URL {
        logsDirectory.appendingPathComponent("export_progress.txt")
    }

    /// Browse/search trace (private; optional LAN via `pcld_ios_media/logs/search_debug.txt`).
    static var searchDebugLogURL: URL {
        logsDirectory.appendingPathComponent("search_debug.txt")
    }

    /// Launch health probe (private; LAN `pcld_ios_media/logs/loop_segments_ok.txt`, legacy `/loop_segments_ok.txt`).
    static var loopSegmentsOkProbeURL: URL {
        logsDirectory.appendingPathComponent("loop_segments_ok.txt")
    }

    /// Map legacy LAN paths (`export_latest.txt`, `logs/export_*.txt`) → `pcld_ios_media/logs/…`.
    static func canonicalLANLogRelativePath(_ relativePath: String) -> String? {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, !trimmed.contains("..") else { return nil }
        switch trimmed {
        case "export_latest.txt", "export_latest.log":
            return pathRelativeToExports(latestLogTextURL)
        case "export_progress.txt":
            return pathRelativeToExports(exportProgressURL)
        case "search_debug.txt":
            return pathRelativeToExports(searchDebugLogURL)
        case "loop_segments_ok.txt":
            return pathRelativeToExports(loopSegmentsOkProbeURL)
        default:
            break
        }
        if trimmed.hasPrefix("logs/") {
            let name = String(trimmed.dropFirst("logs/".count))
            guard !name.isEmpty, !name.contains("/") else { return nil }
            return "\(exportLogsLANPrefix)/\(name)"
        }
        if isLANExportLogRelativePath(trimmed) { return trimmed }
        return nil
    }

    static func isLANExportLogRelativePath(_ relativePath: String) -> Bool {
        let prefix = "\(exportLogsLANPrefix)/"
        guard relativePath.hasPrefix(prefix), relativePath.hasSuffix(".txt") else { return false }
        let name = String(relativePath.dropFirst(prefix.count))
        if name == "export_latest.txt" || name == "export_progress.txt" { return true }
        if name == "search_debug.txt" || name == "loop_segments_ok.txt" { return true }
        return name.hasPrefix("export_")
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

    static let vanillaDownloadManifestFileName = "_vanilla_download.meta.json"

    /// `_vanilla_download.<ext>` media bytes — not the resume manifest (`_vanilla_download.meta.json`).
    static func isVanillaDownloadMediaCopy(fileName: String) -> Bool {
        let lower = fileName.lowercased()
        guard lower.hasPrefix("_vanilla_download.") else { return false }
        return lower != vanillaDownloadManifestFileName.lowercased()
    }

    /// Full WebDAV copy with original extension (`_vanilla_download.wmv`, etc.).
    static func vanillaDownloadURL(preservingExtensionFrom filename: String) -> URL {
        let ext = (filename as NSString).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = ext.isEmpty ? "bin" : ext.lowercased()
        return mediaExportDirectory.appendingPathComponent("_vanilla_download.\(suffix)")
    }

    static func fileByteSize(at url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path),
              let number = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return 0
        }
        return number.int64Value
    }

    /// `URL !=` can treat the same on-disk file as different; use for prune keep comparisons.
    static func vanillaDownloadPathsEqual(_ a: URL, _ b: URL) -> Bool {
        a.path.caseInsensitiveCompare(b.path) == .orderedSame
    }

    static func listVanillaDownloadMediaURLs() -> [URL] {
        guard let listed = try? FileManager.default.contentsOfDirectory(
            at: mediaExportDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return listed.filter { isVanillaDownloadMediaCopy(fileName: $0.lastPathComponent) }
    }

    /// Move a lone partial `_vanilla_download.<ext>` onto the preferred path when extensions differ.
    @discardableResult
    static func reconcileVanillaPartialToPreferredDestination(
        preferred: URL,
        log: ((String) -> Void)? = nil
    ) -> Int64 {
        let fm = FileManager.default
        var onDisk = fileByteSize(at: preferred)
        if onDisk > 0 { return onDisk }
        let partials = listVanillaDownloadMediaURLs().filter { fileByteSize(at: $0) > 0 }
        guard partials.count == 1, let partial = partials.first else { return onDisk }
        guard !vanillaDownloadPathsEqual(partial, preferred) else { return fileByteSize(at: preferred) }
        do {
            if fm.fileExists(atPath: preferred.path) {
                try fm.removeItem(at: preferred)
            }
            try fm.moveItem(at: partial, to: preferred)
            onDisk = fileByteSize(at: preferred)
            log?(
                "Vanilla resume — moved \(pathRelativeToExports(partial)) → " +
                    "\(pathRelativeToExports(preferred)) (\(onDisk) bytes on disk)"
            )
        } catch {
            log?(
                "Could not move vanilla partial \(partial.lastPathComponent) → \(preferred.lastPathComponent): " +
                    "\(error.localizedDescription)"
            )
            onDisk = fileByteSize(at: partial)
        }
        return onDisk
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
        if lower == "_export_retention_source.json" { return true }
        if lower.hasPrefix(".faststart-") { return true }
        if lower.hasPrefix("_working_pcloud_transcode.staging") { return true }
        return false
    }

    static func vanillaDownloadCopyExistsOnDisk() -> Bool {
        vanillaPrimaryMediaExistsOnDisk()
    }

    /// Dense vanilla download and/or faststart sidecar (after moov-at-end remux replaces the download file).
    static func vanillaPrimaryMediaExistsOnDisk() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: vanillaFastStartURL.path) { return true }
        guard let names = try? fm.contentsOfDirectory(atPath: mediaExportDirectory.path) else { return false }
        return names.contains { isVanillaDownloadMediaCopy(fileName: $0) }
    }

    /// Paused export can resume WebDAV byte offset via `_vanilla_download.meta.json` (even when media checkpoint is 0:00).
    static func hasResumableVanillaDownload(for item: WebDAVItem) -> Bool {
        let destination = vanillaDownloadURL(preservingExtensionFrom: item.name)
        var totalLength = item.contentLength ?? 0
        if totalLength <= 0, let manifest = VanillaDownloadResumeCatalog.readManifest() {
            if manifest.fileKey == item.fileKey
                || VanillaDownloadResumeCatalog.matchesAfterRename(item: item, totalLength: manifest.totalLength) {
                totalLength = manifest.totalLength
            }
        }
        guard totalLength > 0 else { return false }
        switch VanillaDownloadResumeCatalog.resumePlan(
            fileKey: item.fileKey,
            totalLength: totalLength,
            destinationURL: destination
        ) {
        case .startFresh:
            return false
        case .resume, .alreadyComplete:
            return true
        }
    }

    /// Prefer growing `_vanilla_download.*` while downloading; otherwise completed `_vanilla_faststart.mp4`.
    static func vanillaPrimaryLocalURL(for item: WebDAVItem) -> URL {
        let download = vanillaDownloadURL(preservingExtensionFrom: item.name)
        if FileManager.default.fileExists(atPath: download.path) {
            return download
        }
        return vanillaFastStartURL
    }

    /// After moov-at-end remux, drop `_vanilla_download.*` and point LAN at `_vanilla_faststart.mp4`.
    static func replaceVanillaDownloadWithFaststartSidecar(log: ((String) -> Void)? = nil) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: vanillaFastStartURL.path) else { return }
        VanillaDownloadResumeCatalog.remove()
        if let listed = try? fm.contentsOfDirectory(at: mediaExportDirectory, includingPropertiesForKeys: nil) {
            for url in listed {
                guard isVanillaDownloadMediaCopy(fileName: url.lastPathComponent) else { continue }
                do {
                    try fm.removeItem(at: url)
                    log?("Removed \(pathRelativeToExports(url)) — using faststart sidecar on LAN")
                } catch {
                    log?("Could not remove \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        ExportPlaybackState.shared.promoteVanillaLANToFaststart()
        ExportRetentionSourceCatalog.markAppFaststartRemuxCompleted()
    }

    /// Hide stale sparse `_working.mp4` on LAN while vanilla (or transcode) is the active source.
    static func shouldHideSparseWorkingFromLAN() -> Bool {
        if ExportPlaybackState.shared.usesVanillaDownloadForLAN() { return true }
        if ExportPlaybackState.shared.usesPCloudTranscodedWorkingForLAN() { return true }
        if vanillaPrimaryMediaExistsOnDisk(), ExportPlaybackState.shared.isLANExportActive { return true }
        return false
    }

    static func isLANBrowsableMediaFile(fileName: String) -> Bool {
        if fileName == "_working.mp4", shouldHideSparseWorkingFromLAN() { return false }
        guard !isExcludedFromLANMediaServe(fileName: fileName) else { return false }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return lanBrowsableMediaExtensions.contains(ext)
    }

    /// Max `archive/` rows on the LAN index (avoids scanning the full media tree every poll).
    static let lanPlaybackArchiveIndexLimit = 32

    /// Recent `archive/` rows while export runs (click-to-open; keeps monitor list small).
    static let lanPlaybackArchiveIndexLimitDuringExport = 8

    /// Active + recent archive paths for the LAN HTML index (non-recursive; cheap for `status.json` polling).
    static func listLANPlaybackIndexRelativePaths(
        maxArchiveEntries: Int = lanPlaybackArchiveIndexLimit
    ) -> [String] {
        let fm = FileManager.default
        var paths: [String] = []

        func appendFileIfPresent(_ url: URL) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return }
            paths.append(pathRelativeToExports(url))
        }

        for index in 0 ..< segmentFileCount {
            appendFileIfPresent(segmentURL(index: index))
        }
        appendFileIfPresent(workingSourceURL)
        appendFileIfPresent(workingTranscodedURL)
        appendFileIfPresent(vanillaFastStartURL)

        if let names = try? fm.contentsOfDirectory(atPath: mediaExportDirectory.path) {
            for name in names.sorted() where isVanillaDownloadMediaCopy(fileName: name) {
                guard isLANBrowsableMediaFile(fileName: name) else { continue }
                appendFileIfPresent(mediaExportDirectory.appendingPathComponent(name))
            }
        }

        if maxArchiveEntries > 0 {
            let archiveDir = mediaExportDirectory.appendingPathComponent("archive", isDirectory: true)
            if fm.fileExists(atPath: archiveDir.path),
               let names = try? fm.contentsOfDirectory(atPath: archiveDir.path) {
                let videos = names.filter { isLANBrowsableMediaFile(fileName: $0) }
                let capped = cappedNewestArchiveFileNames(
                    in: archiveDir,
                    names: videos,
                    limit: maxArchiveEntries
                )
                for name in capped {
                    appendFileIfPresent(archiveDir.appendingPathComponent(name))
                }
            }
        }
        return paths
    }

    /// Optional LAN logs (not `export_*` history) — included in index when present on disk.
    static func listLANAuxiliaryLogRelativePaths() -> [String] {
        let fm = FileManager.default
        var paths: [String] = []
        for url in [searchDebugLogURL, loopSegmentsOkProbeURL] {
            guard fm.fileExists(atPath: url.path) else { continue }
            paths.append(pathRelativeToExports(url))
        }
        return paths
    }

    /// Live + history log paths for the LAN index (`pcld_ios_media/logs/` only).
    static func listLANLogIndexRelativePaths(maxHistoryEntries: Int? = nil) -> [String] {
        var paths = [
            pathRelativeToExports(latestLogTextURL),
            pathRelativeToExports(exportProgressURL),
        ]
        var history = listExportHistoryLogRelativePaths()
        if let maxHistoryEntries, maxHistoryEntries >= 0, history.count > maxHistoryEntries {
            history = Array(history.prefix(maxHistoryEntries))
        }
        paths.append(contentsOf: history)
        paths = dedupeLANLogIndexPaths(paths)
        for aux in listLANAuxiliaryLogRelativePaths() where !paths.contains(aux) {
            let insertAt = min(2, paths.count)
            paths.insert(aux, at: insertAt)
        }
        return paths
    }

    /// Drop history rows that duplicate `export_latest.txt` (common after pause: finalized `*_paused.txt` + live copy).
    private static func dedupeLANLogIndexPaths(_ paths: [String]) -> [String] {
        guard !ExportPlaybackState.shared.isLANExportActive else { return paths }
        let fm = FileManager.default
        let latestRel = pathRelativeToExports(latestLogTextURL)
        guard paths.contains(latestRel) else { return paths }
        let latestURL = latestLogTextURL
        guard fm.fileExists(atPath: latestURL.path),
              let latestSize = try? latestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              latestSize > 512 else {
            return paths
        }
        return paths.filter { rel in
            if rel == latestRel || rel.hasSuffix("/export_progress.txt") { return true }
            guard rel.hasPrefix("\(exportLogsLANPrefix)/export_"), rel.hasSuffix(".txt") else { return true }
            let name = (rel as NSString).lastPathComponent
            guard isFinalizedExportHistoryLogFileName(name) else { return true }
            let url = urlUnderExports(relativePath: rel)
            guard fm.fileExists(atPath: url.path),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return true
            }
            return size != latestSize
        }
    }

    private static func isFinalizedExportHistoryLogFileName(_ name: String) -> Bool {
        guard name.hasPrefix("export_"), name.hasSuffix(".txt") else { return false }
        if name == "export_latest.txt" || name == "export_progress.txt" { return false }
        if exportLogUnixTimestamp(fromFileName: name) != nil { return false }
        return exportLogStampedDate(fromFileName: name) != nil
            || name.contains("_paused")
            || name.contains("_interrupted")
            || name.contains("_completed")
            || name.contains("_cancelled")
            || name.contains("_stopped")
            || name.contains("_failed")
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

    /// Any regular file under `pcld_ios_media/` (scripts, nested folders) except staging/hidden artifacts.
    static func isLANMediaTreeServableRelativePath(_ relativePath: String) -> Bool {
        guard isUnderMediaExportLANPath(relativePath) else { return false }
        let name = (relativePath as NSString).lastPathComponent
        if isExcludedFromLANMediaServe(fileName: name) { return false }
        if name == "_working.mp4", shouldHideSparseWorkingFromLAN() { return false }
        let url = urlUnderExports(relativePath: relativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return true
    }

    static func isUnderMediaExportLANPath(_ relativePath: String) -> Bool {
        guard !relativePath.contains("..") else { return false }
        let normalized = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized.isEmpty { return false }
        return normalized == mediaExportFolderName || normalized.hasPrefix("\(mediaExportFolderName)/")
    }

    /// Export pipeline files — read-only over LAN WebDAV (PC scripts go elsewhere under `pcld_ios_media/`).
    static func isLANProtectedFromWebDAVWrite(relativePath: String) -> Bool {
        guard isUnderMediaExportLANPath(relativePath) else { return true }
        let normalized = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized == mediaExportFolderName { return true }
        if normalized == "\(mediaExportFolderName)/\(segmentLoopFolderName)" { return true }
        if normalized.hasPrefix("\(mediaExportFolderName)/\(exportLogsFolderName)/") { return true }
        let lower = relativePath.lowercased()
        let name = (relativePath as NSString).lastPathComponent.lowercased()
        if isExcludedFromLANMediaServe(fileName: name) { return true }
        if name == "_working.mp4" { return true }
        if name == "_working.sparse.json" { return true }
        if name.hasPrefix("_vanilla_download.") { return true }
        if name == "_vanilla_faststart.mp4" { return true }
        if name.hasPrefix("_working_pcloud_transcode") { return true }
        let loopPrefix = "\(mediaExportFolderName)/\(segmentLoopFolderName)/".lowercased()
        if lower.hasPrefix(loopPrefix) { return true }
        return false
    }

    static func isLANWritableMediaRelativePath(_ relativePath: String) -> Bool {
        guard isUnderMediaExportLANPath(relativePath), !relativePath.contains("..") else { return false }
        let name = (relativePath as NSString).lastPathComponent
        guard !name.isEmpty else { return false }
        return !isLANProtectedFromWebDAVWrite(relativePath: relativePath)
    }

    static func urlForLANWritableMedia(relativePath: String) -> URL? {
        guard isLANWritableMediaRelativePath(relativePath) else { return nil }
        return urlUnderExports(relativePath: relativePath)
    }

    struct LANMediaTreeEntry {
        let relativePath: String
        let isDirectory: Bool
    }

    /// Immediate children of a directory under `pcld_ios_media/` (`relativeDir` = `pcld_ios_media` or `pcld_ios_media/scripts`, …).
    static func listLANMediaDirectory(relativeDir: String) -> [LANMediaTreeEntry] {
        let fm = FileManager.default
        var normalized = relativeDir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized.isEmpty { normalized = mediaExportFolderName }
        guard normalized == mediaExportFolderName || normalized.hasPrefix("\(mediaExportFolderName)/") else {
            return []
        }
        var dirURL = mediaExportDirectory
        if normalized != mediaExportFolderName {
            let suffix = String(normalized.dropFirst(mediaExportFolderName.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !suffix.isEmpty {
                dirURL = mediaExportDirectory.appendingPathComponent(suffix, isDirectory: true)
            }
        }
        guard fm.fileExists(atPath: dirURL.path) else { return [] }
        guard let names = try? fm.contentsOfDirectory(atPath: dirURL.path) else { return [] }
        var result: [LANMediaTreeEntry] = []
        for name in names.sorted() {
            if isExcludedFromLANMediaServe(fileName: name) { continue }
            if name == "_working.mp4", shouldHideSparseWorkingFromLAN() { continue }
            let childURL = dirURL.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: childURL.path, isDirectory: &isDir) else { continue }
            result.append(
                LANMediaTreeEntry(
                    relativePath: pathRelativeToExports(childURL),
                    isDirectory: isDir.boolValue
                )
            )
        }
        return result
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

    private static func vanillaManifestMatchesItem(_ item: WebDAVItem, totalLength: Int64) -> Bool {
        VanillaDownloadResumeCatalog.matches(fileKey: item.fileKey, totalLength: totalLength)
            || VanillaDownloadResumeCatalog.matchesAfterRename(item: item, totalLength: totalLength)
    }

    /// Drop stale vanilla files when the export item changed; keep partial/complete copy for the same `fileKey` + size.
    static func syncVanillaDownloadWithExportItem(
        item: WebDAVItem,
        totalLength: Int64,
        log: ((String) -> Void)? = nil
    ) {
        let destination = vanillaDownloadURL(preservingExtensionFrom: item.name)

        if totalLength > 0, vanillaManifestMatchesItem(item, totalLength: totalLength) {
            _ = reconcileVanillaPartialToPreferredDestination(preferred: destination, log: log)
        }

        var onDisk = fileByteSize(at: destination)

        if totalLength > 0, onDisk > 0 {
            if vanillaManifestMatchesItem(item, totalLength: totalLength) {
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
            } else if VanillaDownloadResumeCatalog.readManifest() == nil {
                VanillaDownloadResumeCatalog.save(
                    fileKey: item.fileKey,
                    totalLength: totalLength,
                    href: item.href
                )
                log?(
                    "Vanilla resume — restored manifest for partial " +
                        "\(pathRelativeToExports(destination))"
                )
            }
        }

        if totalLength > 0, onDisk > 0, vanillaManifestMatchesItem(item, totalLength: totalLength) {
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
            let name = url.lastPathComponent
            guard isVanillaDownloadMediaCopy(fileName: name),
                  !vanillaDownloadPathsEqual(url, keep) else { continue }
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
                guard isVanillaDownloadMediaCopy(fileName: url.lastPathComponent) else { continue }
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
        if !vanillaPrimaryMediaExistsOnDisk() {
            ExportPlaybackState.shared.setVanillaDownloadActive(false)
        }
        return removed
    }

    private static var applicationSupportMediaDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(mediaExportFolderName, isDirectory: true)
    }

    /// Move `Documents/Exports/pcld_ios_media/` → `Application Support/pcld_ios_media/` (hidden from Files; LAN paths unchanged).
    static func migrateMediaFromDocumentsExports(log: ((String) -> Void)? = nil) {
        let fm = FileManager.default
        let legacy = exportsDirectory.appendingPathComponent(mediaExportFolderName, isDirectory: true)
        guard fm.fileExists(atPath: legacy.path) else { return }

        let target = applicationSupportMediaDirectoryURL
        if !fm.fileExists(atPath: target.path) {
            do {
                try fm.moveItem(at: legacy, to: target)
                log?(
                    "Moved \(mediaExportFolderName)/ to Application Support — hidden from Files/USB; " +
                        "LAN/rclone still use /\(mediaExportFolderName)/ on :8765"
                )
            } catch {
                log?("Could not move \(mediaExportFolderName)/ to Application Support: \(error.localizedDescription)")
            }
            return
        }

        guard let names = try? fm.contentsOfDirectory(atPath: legacy.path) else { return }
        var merged = 0
        for name in names {
            let src = legacy.appendingPathComponent(name)
            let dst = target.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { continue }
            if fm.fileExists(atPath: dst.path) { continue }
            do {
                try fm.moveItem(at: src, to: dst)
                merged += 1
            } catch {
                log?("Could not merge legacy \(name): \(error.localizedDescription)")
            }
        }
        if merged > 0 {
            log?("Merged \(merged) item(s) from Documents/Exports/\(mediaExportFolderName)/ into Application Support")
        }
        if let left = try? fm.contentsOfDirectory(atPath: legacy.path), left.isEmpty {
            try? fm.removeItem(at: legacy)
        }
    }

    /// Move `Documents/Exports/` log files → `Application Support/pcld_ios_media/logs/` (hidden from Files; LAN aliases unchanged).
    static func migrateExportLogsFromDocumentsExports(log: ((String) -> Void)? = nil) {
        let fm = FileManager.default
        _ = logsDirectory

        func moveFile(from src: URL, to dst: URL, label: String) {
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { return }
            do {
                try fm.moveItem(at: src, to: dst)
                log?("Moved \(label) → \(pathRelativeToExports(dst))")
            } catch {
                log?("Could not move \(label): \(error.localizedDescription)")
            }
        }

        for name in [
            "export_latest.txt", "export_progress.txt", "export_latest.log", "search_debug.txt",
            "loop_segments_ok.txt",
        ] {
            let src = exportsDirectory.appendingPathComponent(name)
            let dst = logsDirectory.appendingPathComponent(name)
            moveFile(from: src, to: dst, label: name)
        }

        let legacyLogsDir = exportsDirectory.appendingPathComponent(exportLogsFolderName, isDirectory: true)
        if fm.fileExists(atPath: legacyLogsDir.path),
           let names = try? fm.contentsOfDirectory(atPath: legacyLogsDir.path) {
            for name in names {
                let src = legacyLogsDir.appendingPathComponent(name)
                let dst = logsDirectory.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                if fm.fileExists(atPath: dst.path) {
                    try? fm.removeItem(at: src)
                    continue
                }
                moveFile(from: src, to: dst, label: "logs/\(name)")
            }
            if let left = try? fm.contentsOfDirectory(atPath: legacyLogsDir.path), left.isEmpty {
                try? fm.removeItem(at: legacyLogsDir)
            }
        }

        migrateLegacyExportSessionLogs(log: log)
        migrateLegacyExportLogDuplicates(log: log)
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

    /// Relative paths for retained per-run logs (`pcld_ios_media/logs/export_<unix>.txt`), newest first.
    static func listExportHistoryLogRelativePaths() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: logsDirectory.path) else { return [] }
        let filtered = names.filter { $0.hasPrefix("export_") && $0.hasSuffix(".txt") }
        return sortedExportHistoryLogFileNames(filtered).map { "\(exportLogsLANPrefix)/\($0)" }
    }

    /// Avoid O(n log n) on huge `logs/` directories — sort at most ~80 names for the LAN index.
    private static func sortedExportHistoryLogFileNames(_ names: [String]) -> [String] {
        let cap = exportLogRetentionCount + 40
        guard names.count > cap else {
            return names.sorted { exportLogFileSortDate(fileName: $0) > exportLogFileSortDate(fileName: $1) }
        }
        let ranked = names.map { name -> (String, Date) in
            let url = logsDirectory.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate)
            let stamped = exportLogFileSortDate(fileName: name)
            return (name, stamped ?? modified ?? .distantPast)
        }
        return ranked.sorted { $0.1 > $1.1 }.prefix(cap).map(\.0)
    }

    private static func cappedNewestArchiveFileNames(
        in archiveDir: URL,
        names: [String],
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        guard names.count > limit else {
            return names.sorted { lhs, rhs in
                let l = ExportMediaArchive.archivedMediaSortDate(fileName: lhs) ?? .distantPast
                let r = ExportMediaArchive.archivedMediaSortDate(fileName: rhs) ?? .distantPast
                return l > r
            }
        }
        let ranked = names.map { name -> (String, Date) in
            let url = archiveDir.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate)
            let stamped = ExportMediaArchive.archivedMediaSortDate(fileName: name)
            return (name, stamped ?? modified ?? .distantPast)
        }
        return ranked.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Newest-first sort key for `logs/export_*.txt` (stamped name, unix infix, else file mtime).
    static func exportLogFileSortDate(fileName: String) -> Date {
        if let stamped = exportLogStampedDate(fromFileName: fileName) {
            return stamped
        }
        if let unix = exportLogUnixTimestamp(fromFileName: fileName) {
            return Date(timeIntervalSince1970: TimeInterval(unix))
        }
        let url = logsDirectory.appendingPathComponent(fileName)
        if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            return modified
        }
        return .distantPast
    }

    private static func exportLogUnixTimestamp(fromFileName name: String) -> Int? {
        guard name.hasPrefix("export_"), name.hasSuffix(".txt") else { return nil }
        let stem = (name as NSString).deletingPathExtension
        let rest = stem.dropFirst("export_".count)
        guard let underscore = rest.firstIndex(of: "_") else {
            return Int(rest)
        }
        let prefix = rest[..<underscore]
        guard prefix.allSatisfy(\.isNumber), let unix = Int(prefix) else { return nil }
        return unix
    }

    private static func exportLogStampedDate(fromFileName name: String) -> Date? {
        let stem = (name as NSString).deletingPathExtension
        let pattern = #"_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$"#
        guard let range = stem.range(of: pattern, options: .regularExpression) else { return nil }
        let token = String(stem[range]).dropFirst()
        return ExportMediaArchive.archivedMediaSortDate(fileName: "x\(token).txt")
    }

    static func isLANExportHistoryLogRelativePath(_ relativePath: String) -> Bool {
        let prefix = "\(exportLogsLANPrefix)/export_"
        guard relativePath.hasPrefix(prefix), relativePath.hasSuffix(".txt") else { return false }
        let name = (relativePath as NSString).lastPathComponent
        return name != "export_latest.txt" && name != "export_progress.txt"
    }

    static func sanitizedExportLogStem(_ fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        var out = ""
        for scalar in stem.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if scalar == "_" || scalar == "-" {
                out.append(String(scalar))
            } else {
                out.append("_")
            }
        }
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let capped = String(trimmed.prefix(72))
        return capped.isEmpty ? "export" : capped
    }

    static func exportLogStatusSlug(from status: String) -> String {
        let s = status.lowercased()
        if s.contains("completed") || s.contains("end of file") { return "completed" }
        if s.contains("paused") { return "paused" }
        if s.contains("interrupt") { return "interrupted" }
        if s.contains("cancel") { return "cancelled" }
        if s.contains("fail") { return "failed" }
        return "stopped"
    }

    /// Rename `logs/export_<unix>.txt` → `logs/export_<basename>_<local-time>_<status>.txt` when a run ends.
    @discardableResult
    static func finalizeExportHistoryLog(
        historyURL: URL,
        sourceFileName: String,
        status: String,
        log: ((String) -> Void)? = nil
    ) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: historyURL.path) else { return historyURL }
        let stamp = ExportMediaArchive.newRetentionTimestamp()
        let safe = sanitizedExportLogStem(sourceFileName)
        let slug = exportLogStatusSlug(from: status)
        var dest = logsDirectory.appendingPathComponent("export_\(safe)_\(stamp)_\(slug).txt")
        var attempt = 0
        while fm.fileExists(atPath: dest.path), attempt < 5 {
            attempt += 1
            dest = logsDirectory.appendingPathComponent(
                "export_\(safe)_\(stamp)_\(slug)_\(attempt).txt"
            )
        }
        do {
            try fm.moveItem(at: historyURL, to: dest)
            log?("Saved export history → logs/\(dest.lastPathComponent)")
            return dest
        } catch {
            log?("Could not rename history log: \(error.localizedDescription)")
            return historyURL
        }
    }

    /// If the previous run only left `export_latest.txt`, move it into `logs/` before clearing live files.
    static func archiveOrphanedLiveExportLog(log: ((String) -> Void)? = nil) {
        let fm = FileManager.default
        let latest = latestLogTextURL
        guard fm.fileExists(atPath: latest.path),
              let text = try? String(contentsOf: latest, encoding: .utf8),
              text.contains("--- ")
        else { return }
        guard let statusLine = text.split(separator: "\n", omittingEmptySubsequences: true)
            .last(where: { $0.contains("--- ") })
        else { return }
        let status = String(statusLine)
            .replacingOccurrences(of: "---", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let itemName: String
        if let fileLine = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first(where: { $0.hasPrefix("File: ") }) {
            itemName = String(fileLine.dropFirst("File: ".count))
        } else {
            itemName = "unknown"
        }
        let stamp = ExportMediaArchive.newRetentionTimestamp()
        let safe = sanitizedExportLogStem(itemName)
        let slug = exportLogStatusSlug(from: status)
        let dest = logsDirectory.appendingPathComponent("export_\(safe)_\(stamp)_\(slug).txt")
        guard !fm.fileExists(atPath: dest.path) else { return }
        do {
            try fm.moveItem(at: latest, to: dest)
            log?("Archived prior live log → logs/\(dest.lastPathComponent)")
        } catch {
            log?("Could not archive export_latest.txt: \(error.localizedDescription)")
        }
    }

    /// Remove legacy `.log` duplicates and `export_session_*` at Exports root.
    static func migrateLegacyExportLogDuplicates(log: ((String) -> Void)? = nil) {
        let fm = FileManager.default
        for name in ["export_latest.log"] {
            let legacy = exportsDirectory.appendingPathComponent(name)
            guard fm.fileExists(atPath: legacy.path) else { continue }
            do {
                try fm.removeItem(at: legacy)
                log?("Removed legacy Exports/\(name)")
            } catch {
                log?("Could not remove Exports/\(name): \(error.localizedDescription)")
            }
        }
        if fm.fileExists(atPath: legacyLatestLogURL.path) {
            do {
                try fm.removeItem(at: legacyLatestLogURL)
                log?("Removed legacy \(legacyLatestLogURL.lastPathComponent)")
            } catch {
                log?("Could not remove \(legacyLatestLogURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        guard let names = try? fm.contentsOfDirectory(atPath: logsDirectory.path) else { return }
        for name in names where name.hasSuffix(".log") {
            let url = logsDirectory.appendingPathComponent(name)
            do {
                try fm.removeItem(at: url)
                log?("Removed legacy logs/\(name)")
            } catch {
                log?("Could not remove logs/\(name): \(error.localizedDescription)")
            }
        }
    }

    /// Move legacy duplicate `export_session_*.txt` into `logs/` once (same content as history).
    static func migrateLegacyExportSessionLogs(log: ((String) -> Void)? = nil) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: exportsDirectory.path) else { return }
        for name in names where name.hasPrefix("export_session_") && name.hasSuffix(".txt") {
            let legacy = exportsDirectory.appendingPathComponent(name)
            let stamp = name.dropFirst("export_session_".count).dropLast(".txt".count)
            let dest = logsDirectory.appendingPathComponent("export_\(stamp).txt")
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: legacy)
                log?("Removed legacy duplicate \(name) (history already in logs/)")
                continue
            }
            do {
                try fm.moveItem(at: legacy, to: dest)
                log?("Moved legacy \(name) → logs/\(dest.lastPathComponent)")
            } catch {
                log?("Could not migrate \(name): \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    static func pruneExportLogHistory(log: ((String) -> Void)? = nil) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: logsDirectory.path) else { return 0 }
        let sorted = names
            .filter { $0.hasPrefix("export_") && $0.hasSuffix(".txt") }
            .sorted(by: >)
        var removed = 0
        guard sorted.count > exportLogRetentionCount else { return 0 }
        for name in sorted.dropFirst(exportLogRetentionCount) {
            let url = logsDirectory.appendingPathComponent(name)
            do {
                try fm.removeItem(at: url)
                removed += 1
                log?("Pruned old log logs/\(name)")
            } catch {
                log?("Could not prune logs/\(name): \(error.localizedDescription)")
            }
        }
        return removed
    }

    /// Clears live pointers only (`export_latest*`, `export_progress.txt`) — keeps `logs/export_*.txt` history.
    @discardableResult
    static func clearCurrentExportLogPointers(log: ((String) -> Void)? = nil) -> Int {
        let fm = FileManager.default
        var removed = 0
        for url in [latestLogTextURL, legacyLatestLogURL, exportProgressURL] {
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                removed += 1
                log?("Cleared \(url.lastPathComponent)")
            } catch {
                log?("Could not clear \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return removed
    }

    /// Export + search logs under `pcld_ios_media/logs/` (not in Files).
    @discardableResult
    static func clearExportLogs(log: ((String) -> Void)? = nil) -> Int {
        _ = exportsDirectory
        _ = logsDirectory
        var removed = clearCurrentExportLogPointers(log: log)

        let searchDebug = searchDebugLogURL
        if FileManager.default.fileExists(atPath: searchDebug.path) {
            do {
                try FileManager.default.removeItem(at: searchDebug)
                removed += 1
                log?("Cleared \(searchDebug.lastPathComponent)")
            } catch {
                log?("Could not clear \(searchDebug.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if let names = try? FileManager.default.contentsOfDirectory(atPath: exportsDirectory.path) {
            for name in names where name.hasPrefix("export_session_") {
                let url = exportsDirectory.appendingPathComponent(name)
                do {
                    try FileManager.default.removeItem(at: url)
                    removed += 1
                    log?("Cleared \(name)")
                } catch {
                    log?("Could not clear \(name): \(error.localizedDescription)")
                }
            }
        }

        if let names = try? FileManager.default.contentsOfDirectory(atPath: logsDirectory.path) {
            for name in names where name.hasPrefix("export_") {
                let url = logsDirectory.appendingPathComponent(name)
                do {
                    try FileManager.default.removeItem(at: url)
                    removed += 1
                    log?("Cleared logs/\(name)")
                } catch {
                    log?("Could not clear logs/\(name): \(error.localizedDescription)")
                }
            }
        }
        return removed
    }

    /// New export: reset live log files only; retain and prune `logs/export_*.txt` history.
    static func clearLogsForNewExport(log: ((String) -> Void)? = nil) {
        migrateLegacyExportLogDuplicates(log: log)
        archiveOrphanedLiveExportLog(log: log)
        _ = clearCurrentExportLogPointers(log: log)
        _ = pruneExportLogHistory(log: log)
    }

    /// Names and sizes of media files for post-export logs (media + logs are private; LAN :8765).
    static func describeExportMediaOnDisk() -> String {
        let fm = FileManager.default
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        var parts: [String] = []
        func appendFile(at url: URL, label: String) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            parts.append("\(label) \(formatter.string(fromByteCount: size))")
        }
        for rel in listLANPlaybackIndexRelativePaths(maxArchiveEntries: 12) {
            let url = urlUnderExports(relativePath: rel)
            appendFile(at: url, label: rel)
        }
        if parts.isEmpty {
            return "Media: no playable files under \(mediaExportFolderName)/ (LAN :8765; not in Files app)"
        }
        return "Media on disk (private, LAN only): " + parts.joined(separator: "; ")
    }

    private static let heavySetupQueue = DispatchQueue(
        label: "com.loopsegments.export-paths-setup",
        qos: .utility
    )
    private static let heavySetupLock = NSLock()
    private static var heavySetupScheduled = false

    /// Creates export dirs synchronously; migrations + probe run once on a background queue.
    static func ensureExportDirectories() {
        _ = mediaExportDirectory
        _ = segmentLoopDirectory
        _ = lanExportScriptsDirectory
        _ = logsDirectory
        scheduleHeavyExportPathsSetupIfNeeded()
    }

    private static func scheduleHeavyExportPathsSetupIfNeeded() {
        heavySetupLock.lock()
        guard !heavySetupScheduled else {
            heavySetupLock.unlock()
            return
        }
        heavySetupScheduled = true
        heavySetupLock.unlock()
        heavySetupQueue.async {
            migrateMediaFromDocumentsExports()
            migrateExportLogsFromDocumentsExports()
            migrateLegacyExportFilenames()
            migrateLegacyExportLogDuplicates()
            SearchDebugLog.ensureReady()
            writeLoopSegmentsOkProbe()
        }
    }

    static func writeLoopSegmentsOkProbe() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let text =
            "Loop Segments \(version) build \(build) \(ISO8601DateFormatter().string(from: Date()))\n"
        if let data = text.data(using: .utf8) {
            try? data.write(to: loopSegmentsOkProbeURL, options: .atomic)
        }
    }
}
