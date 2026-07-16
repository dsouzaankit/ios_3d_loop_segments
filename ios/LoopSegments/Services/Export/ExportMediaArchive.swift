import Foundation

/// Moves finished root-level `pcld_ios_media/` files into `pcld_ios_media/archive/<pcloud-name>[_3D_<nK>][_appFast_]<local-time>.<ext>`.
/// `pcld_ios_media/loop/` (`op_*.mp4`) is not retained — only siblings like `_working.mp4`, vanilla/transcode copies.
enum ExportMediaArchive {
    static let retentionCount = 10
    static let manualKeepCount = 2

    private static let archiveFolderName = "archive"
    /// In archive filenames when media came from in-app moov-at-end remux (`_vanilla_faststart.mp4`).
    static let appFastArchiveTag = "_appFast_"

    private static let reservedTopLevelNames: Set<String> = [
        ExportPaths.segmentLoopFolderName,
        "scripts",
        archiveFolderName,
        ExportParkedMedia.folderName,
        ExportPaths.downloadsFolderName,
        ExportPaths.exportLogsFolderName,
    ]

    private static let retentionTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    private static var archiveDirectoryURL: URL {
        ExportPaths.mediaExportDirectory.appendingPathComponent(archiveFolderName, isDirectory: true)
    }

    /// Local wall-clock stamp for new retains, e.g. `2026-05-22_14-30-52`.
    static func newRetentionTimestamp() -> String {
        retentionTimestampFormatter.string(from: Date())
    }

    /// Suffix token in the filename, including leading `_` (new local time or legacy unix).
    static func retentionFileSuffix(fromFileName name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        if let local = localRetentionSuffix(in: stem) {
            return local
        }
        guard let underscore = stem.lastIndex(of: "_") else { return nil }
        let token = stem[stem.index(after: underscore)...]
        guard token.count >= 10, token.allSatisfy({ $0.isNumber }), Int(token) != nil else { return nil }
        return "_\(token)"
    }

    static func isRetentionStampedFileName(_ name: String) -> Bool {
        retentionFileSuffix(fromFileName: name) != nil
    }

    private static func localRetentionSuffix(in stem: String) -> String? {
        let withAppFast = #"_appFast_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$"#
        if let range = stem.range(of: withAppFast, options: .regularExpression) {
            return String(stem[range.lowerBound ..< stem.endIndex])
        }
        let pattern = #"_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$"#
        guard let range = stem.range(of: pattern, options: .regularExpression) else { return nil }
        return String(stem[range.lowerBound ..< stem.endIndex])
    }

    /// Batch key for prune/trim (timestamp only — strips optional `_appFast_` from the stamped suffix).
    static func retentionBatchSuffix(fromFileName name: String) -> String? {
        guard let suffix = retentionFileSuffix(fromFileName: name) else { return nil }
        if suffix.hasPrefix(appFastArchiveTag) {
            return String(suffix.dropFirst(appFastArchiveTag.count))
        }
        return suffix
    }

    /// After full vanilla download + moov-at-end remux (`replaceVanillaDownloadWithFaststartSidecar`).
    static func usesAppFaststartArchiveTag(forOnDiskFileName fileName: String) -> Bool {
        fileName == ExportPaths.vanillaFastStartURL.lastPathComponent
            && ExportRetentionSourceCatalog.hadAppFaststartRemux()
    }

    private static func retentionSortDate(fromFileSuffix suffix: String) -> Date? {
        let token = String(suffix.dropFirst())
        if let date = retentionTimestampFormatter.date(from: token) {
            return date
        }
        guard let epoch = Int(token) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(epoch))
    }

    /// Archival time embedded in `archive/<name>_yyyy-MM-dd_HH-mm-ss.ext` (or legacy unix suffix).
    static func archivedMediaSortDate(fileName: String) -> Date? {
        guard let suffix = retentionFileSuffix(fromFileName: fileName) else { return nil }
        return retentionSortDate(fromFileSuffix: suffix)
    }

    /// Newest playable file under `pcld_ios_media/archive/` (Keep Alive muted loop fallback).
    static func newestArchivedPlayableMediaURL() -> URL? {
        migrateRetainedFilesIntoArchive(log: nil)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: archiveDirectoryURL.path) else {
            return nil
        }
        var best: (url: URL, date: Date)?
        for name in names {
            guard isRetentionArchivableMediaFileName(name) else { continue }
            let url = archiveDirectoryURL.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let date = archivedMediaSortDate(fileName: name)
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            if let current = best {
                if date > current.date { best = (url, date) }
            } else {
                best = (url, date)
            }
        }
        return best?.url
    }

    /// e.g. `MyMovie_3D_4K_appFast_2026-05-22_14-30-52.mp4` after in-app faststart remux.
    static func suffixedFileName(
        forOnDiskFileName fileName: String,
        timestamp: String,
        threeDNKLabel: String?,
        sourceFileName: String?,
        appFastRemux: Bool = false
    ) -> String {
        let ext = (fileName as NSString).pathExtension
        var stem: String
        if let sourceFileName, !sourceFileName.isEmpty {
            stem = ExportRetentionSourceCatalog.sanitizedArchiveStem(from: sourceFileName)
        } else {
            stem = (fileName as NSString).deletingPathExtension
        }
        if let nk = threeDNKLabel, let tag = ExportVideoDimensions.threeDSuffixSegment(nkLabel: nk) {
            stem += tag
        }
        if appFastRemux {
            stem += appFastArchiveTag
        }
        stem += "_\(timestamp)"
        if ext.isEmpty {
            return stem
        }
        return "\(stem).\(ext)"
    }

    /// Playable video files at `pcld_ios_media/` root eligible for `_3D_*` / `_<timestamp>` archive names.
    static func isRetentionArchivableMediaFileName(_ name: String) -> Bool {
        ExportPaths.isLANBrowsableMediaFile(fileName: name)
    }

    /// Unstamped root-level **media** only (`pcld_ios_media/`, not `loop/`, `archive/`, or sidecars like `.sparse.json`).
    static func activeRootMediaFiles() -> [URL] {
        unstampedRootFiles(where: { isRetentionArchivableMediaFileName($0) })
    }

    /// Unstamped root sidecars (manifests, meta JSON) — moved into `parked/<filename>/` on handoff.
    static func activeRootCompanionFilesForParking() -> [URL] {
        unstampedRootFiles(where: { !isRetentionArchivableMediaFileName($0) })
    }

    /// Unstamped root sidecars (manifests, meta JSON) — not suffixed; removed when media is relocated off root.
    private static func activeRootCompanionFiles() -> [URL] {
        activeRootCompanionFilesForParking()
    }

    @discardableResult
    static func removeLeftoverRootCompanionsAfterParking(log: ((String) -> Void)? = nil) -> Int {
        removeActiveRootCompanionFiles(log: log)
    }

    private static func unstampedRootFiles(where include: (String) -> Bool) -> [URL] {
        let fm = FileManager.default
        _ = ExportPaths.mediaExportDirectory
        guard let rootNames = try? fm.contentsOfDirectory(atPath: ExportPaths.mediaExportDirectory.path) else {
            return []
        }
        var files: [URL] = []
        for name in rootNames {
            guard !reservedTopLevelNames.contains(name) else { continue }
            guard !isRetentionStampedFileName(name) else { continue }
            guard include(name) else { continue }
            let url = ExportPaths.mediaExportDirectory.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            files.append(url)
        }
        return files
    }

    @discardableResult
    private static func removeActiveRootCompanionFiles(log: ((String) -> Void)? = nil) -> Int {
        let fm = FileManager.default
        var removed = 0
        for url in activeRootCompanionFiles() {
            do {
                try fm.removeItem(at: url)
                removed += 1
                log?("Removed companion \(ExportPaths.pathRelativeToExports(url)) (not retained media)")
            } catch {
                log?("Could not remove \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return removed
    }

    static func hasActiveExportMediaOnDisk() -> Bool {
        !activeRootMediaFiles().isEmpty
    }

    /// Archive root media before a **fresh** export start. Skip only when resuming the same on-disk session (`continueLANExport`).
    static func shouldArchivePriorMediaBeforeNewExport(continueLANExport: Bool, item: WebDAVItem) -> Bool {
        if continueLANExport { return false }
        _ = item
        return true
    }

    /// Newest retain batches first (by parsed local time or legacy unix) under `archive/` (media files only).
    static func collectRetentionStampSuffixes() -> [String] {
        migrateRetainedFilesIntoArchive(log: nil)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: archiveDirectoryURL.path) else {
            return []
        }
        var bySuffix: [String: Date] = [:]
        for name in names {
            guard isRetentionArchivableMediaFileName(name) else { continue }
            guard let suffix = retentionBatchSuffix(fromFileName: name),
                  let date = retentionSortDate(fromFileSuffix: suffix) else { continue }
            let url = archiveDirectoryURL.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            if let existing = bySuffix[suffix] {
                if date > existing { bySuffix[suffix] = date }
            } else {
                bySuffix[suffix] = date
            }
        }
        return bySuffix.keys.sorted {
            (bySuffix[$0] ?? .distantPast) > (bySuffix[$1] ?? .distantPast)
        }
    }

    /// Archive active root export files under `archive/`.
    /// - `relocate: true` — move off root (new-export handoff, Stop). Clears sparse/vanilla playback tied to root paths.
    /// - `relocate: false` — copy only (export finish); root paths stay for LAN/WebDAV clients still playing.
    @discardableResult
    static func archiveActiveMedia(
        timestamp: String,
        relocate: Bool = true,
        sourceFileName: String? = nil,
        log: ((String) -> Void)? = nil
    ) -> Int {
        migrateRetainedFilesIntoArchive(log: log)

        let fm = FileManager.default
        let sources = activeRootMediaFiles()
        guard !sources.isEmpty else { return 0 }

        let retentionSource = sourceFileName ?? ExportRetentionSourceCatalog.read()?.sourceFileName
        let threeDNK = ExportVideoDimensions.probeNKLabelForRetention(from: sources)
        if let threeDNK, ExportVideoDimensions.threeDSuffixSegment(nkLabel: threeDNK) != nil {
            log?("Retention: inferred \(threeDNK) — archive name includes _3D_\(threeDNK)")
        }
        if let retentionSource {
            log?("Retention: archive basename from pCloud — \(retentionSource)")
        }
        if sources.contains(where: { usesAppFaststartArchiveTag(forOnDiskFileName: $0.lastPathComponent) }) {
            log?("Retention: archive includes \(appFastArchiveTag) for in-app faststart remux")
        }
        log?("Retention: local timestamp \(timestamp) (\(TimeZone.current.identifier))")

        do {
            try fm.createDirectory(at: archiveDirectoryURL, withIntermediateDirectories: true)
        } catch {
            log?("Could not create archive/: \(error.localizedDescription)")
            return 0
        }

        var archived = 0
        var clearedAlreadyRetained = 0
        for source in sources {
            let slotName = source.lastPathComponent
            if ExportRetentionSourceCatalog.isRootSlotAlreadyArchived(slotName) {
                if relocate {
                    do {
                        try fm.removeItem(at: source)
                        clearedAlreadyRetained += 1
                        log?(
                            "Removed \(ExportPaths.pathRelativeToExports(source)) — " +
                                "already retained in archive/ (not duplicated)"
                        )
                    } catch {
                        log?("Could not remove \(slotName): \(error.localizedDescription)")
                    }
                } else {
                    log?(
                        "Skipped archive copy of \(ExportPaths.pathRelativeToExports(source)) — " +
                            "already in archive/"
                    )
                }
                continue
            }
            let appFast = usesAppFaststartArchiveTag(forOnDiskFileName: slotName)
            let archivedName = suffixedFileName(
                forOnDiskFileName: slotName,
                timestamp: timestamp,
                threeDNKLabel: threeDNK,
                sourceFileName: retentionSource,
                appFastRemux: appFast
            )
            let destination = archiveDirectoryURL.appendingPathComponent(archivedName)
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                if relocate {
                    try fm.moveItem(at: source, to: destination)
                    log?(
                        "Archived \(ExportPaths.pathRelativeToExports(source)) → " +
                            "\(ExportPaths.pathRelativeToExports(destination))"
                    )
                } else {
                    try fm.copyItem(at: source, to: destination)
                    log?(
                        "Archived copy \(ExportPaths.pathRelativeToExports(source)) → " +
                            "\(ExportPaths.pathRelativeToExports(destination)) " +
                            "(left \(source.lastPathComponent) on LAN)"
                    )
                }
                ExportRetentionSourceCatalog.recordArchivedRootSlot(slotName)
                archived += 1
            } catch {
                log?("Could not archive \(source.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if relocate {
            if archived > 0 || clearedAlreadyRetained > 0 {
                WorkingSourceSparseCatalog.remove()
                if !ExportPaths.vanillaPrimaryMediaExistsOnDisk() {
                    ExportPlaybackState.shared.setVanillaDownloadActive(false)
                }
                ExportPlaybackState.shared.clearSparseWorkingPlaybackHints()
            }
            _ = removeActiveRootCompanionFiles(log: log)
        }
        return archived
    }

    /// Copy a finished LAN URL download into `archive/<name>_<timestamp>.<ext>` (keeps `downloads/` for LAN).
    @discardableResult
    static func archiveURLDownload(
        source: URL,
        log: ((String) -> Void)? = nil
    ) -> URL? {
        migrateRetainedFilesIntoArchive(log: log)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            log?("URL archive skipped — missing \(source.lastPathComponent)")
            return nil
        }
        let size = (try? fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            log?("URL archive skipped — empty \(source.lastPathComponent)")
            return nil
        }

        do {
            try fm.createDirectory(at: archiveDirectoryURL, withIntermediateDirectories: true)
        } catch {
            log?("Could not create archive/: \(error.localizedDescription)")
            return nil
        }

        let timestamp = newRetentionTimestamp()
        let threeDNK = ExportVideoDimensions.probeNKLabelForRetention(from: [source])
        let archivedName = suffixedFileName(
            forOnDiskFileName: source.lastPathComponent,
            timestamp: timestamp,
            threeDNKLabel: threeDNK,
            sourceFileName: source.lastPathComponent,
            appFastRemux: false
        )
        let destination = archiveDirectoryURL.appendingPathComponent(archivedName)
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
            log?(
                "Archived URL download \(ExportPaths.pathRelativeToExports(source)) → " +
                    "\(ExportPaths.pathRelativeToExports(destination))"
            )
            _ = pruneRetainedMedia(keepCount: retentionCount, log: log)
            return destination
        } catch {
            log?("Could not archive URL download: \(error.localizedDescription)")
            return nil
        }
    }

    /// Root-level suffixed retains and `archive/export_*` batch folders → flat `archive/<file>…`.
    @discardableResult
    private static func migrateRetainedFilesIntoArchive(log: ((String) -> Void)?) -> Int {
        var migrated = 0
        migrated += migrateRootSuffixedFilesIntoArchive(log: log)
        migrated += flattenLegacyExportBatchSubfolders(log: log)
        return migrated
    }

    @discardableResult
    private static func migrateRootSuffixedFilesIntoArchive(log: ((String) -> Void)?) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: ExportPaths.mediaExportDirectory.path) else {
            return 0
        }
        let stamped = names.filter { isRetentionStampedFileName($0) && isRetentionArchivableMediaFileName($0) }
        guard !stamped.isEmpty else { return 0 }
        do {
            try fm.createDirectory(at: archiveDirectoryURL, withIntermediateDirectories: true)
        } catch {
            log?("Could not create archive/ for migration: \(error.localizedDescription)")
            return 0
        }
        var migrated = 0
        for name in stamped {
            let source = ExportPaths.mediaExportDirectory.appendingPathComponent(name)
            let destination = archiveDirectoryURL.appendingPathComponent(name)
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.moveItem(at: source, to: destination)
                migrated += 1
                log?("Migrated \(ExportPaths.pathRelativeToExports(source)) → archive/\(name)")
            } catch {
                log?("Could not migrate \(name) into archive/: \(error.localizedDescription)")
            }
        }
        return migrated
    }

    /// Older builds used `archive/export_<unix>/` subfolders.
    @discardableResult
    private static func flattenLegacyExportBatchSubfolders(log: ((String) -> Void)?) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: archiveDirectoryURL.path),
              let entries = try? fm.contentsOfDirectory(atPath: archiveDirectoryURL.path) else {
            return 0
        }
        var migrated = 0
        for entry in entries where entry.hasPrefix("export_") {
            let batchDir = archiveDirectoryURL.appendingPathComponent(entry, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: batchDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: batchDir.path) else { continue }
            for name in files {
                let source = batchDir.appendingPathComponent(name)
                var fileIsDir: ObjCBool = false
                guard fm.fileExists(atPath: source.path, isDirectory: &fileIsDir), !fileIsDir.boolValue else {
                    continue
                }
                let destination = archiveDirectoryURL.appendingPathComponent(name)
                do {
                    if fm.fileExists(atPath: destination.path) {
                        try fm.removeItem(at: destination)
                    }
                    try fm.moveItem(at: source, to: destination)
                    migrated += 1
                } catch {
                    log?("Could not flatten archive/\(entry)/\(name): \(error.localizedDescription)")
                }
            }
            try? fm.removeItem(at: batchDir)
            if !files.isEmpty {
                log?("Flattened legacy archive/\(entry)/ (\(files.count) file(s))")
            }
        }
        return migrated
    }

    @discardableResult
    static func removeFiles(forStampSuffix suffix: String, log: ((String) -> Void)? = nil) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: archiveDirectoryURL.path) else {
            return 0
        }
        var removed = 0
        for name in names where retentionBatchSuffix(fromFileName: name) == suffix {
            guard isRetentionArchivableMediaFileName(name) else { continue }
            let url = archiveDirectoryURL.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            do {
                try fm.removeItem(at: url)
                removed += 1
                log?("Removed \(ExportPaths.pathRelativeToExports(url))")
            } catch {
                log?("Could not remove archive/\(name): \(error.localizedDescription)")
            }
        }
        return removed
    }

    @discardableResult
    static func pruneRetainedMedia(keepCount: Int, log: ((String) -> Void)? = nil) -> Int {
        migrateRetainedFilesIntoArchive(log: log)
        let suffixes = collectRetentionStampSuffixes()
        guard suffixes.count > keepCount else { return 0 }
        var removed = 0
        for suffix in suffixes.dropFirst(keepCount) {
            removed += removeFiles(forStampSuffix: suffix, log: log)
        }
        return removed
    }

    @discardableResult
    static func removeAllRetainedMedia(log: ((String) -> Void)? = nil) -> Int {
        migrateRetainedFilesIntoArchive(log: log)
        var removed = 0
        for suffix in collectRetentionStampSuffixes() {
            removed += removeFiles(forStampSuffix: suffix, log: log)
        }
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: archiveDirectoryURL.path) {
            for name in names where !isRetentionArchivableMediaFileName(name) {
                let url = archiveDirectoryURL.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                do {
                    try fm.removeItem(at: url)
                    removed += 1
                    log?("Removed non-media archive/ \(name)")
                } catch {
                    log?("Could not remove archive/\(name): \(error.localizedDescription)")
                }
            }
        }
        return removed
    }
}
