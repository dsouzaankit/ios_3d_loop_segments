import Foundation

/// Moves finished root-level `pcld_ios_media/` files into `pcld_ios_media/archive/<pcloud-name>[_3D_<n>K]_<local-time>.<ext>`.
/// `pcld_ios_media/loop/` (`op_*.mp4`) is not retained — only siblings like `_working.mp4`, vanilla/transcode copies.
enum ExportMediaArchive {
    static let retentionCount = 10
    static let manualKeepCount = 2

    private static let archiveFolderName = "archive"

    private static let reservedTopLevelNames: Set<String> = [
        ExportPaths.segmentLoopFolderName,
        "scripts",
        archiveFolderName,
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
        let pattern = #"_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$"#
        guard let range = stem.range(of: pattern, options: .regularExpression) else { return nil }
        return String(stem[range.lowerBound ..< stem.endIndex])
    }

    private static func retentionSortDate(fromFileSuffix suffix: String) -> Date? {
        let token = String(suffix.dropFirst())
        if let date = retentionTimestampFormatter.date(from: token) {
            return date
        }
        guard let epoch = Int(token) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(epoch))
    }

    /// e.g. `MyMovie_3D_4K_2026-05-22_14-30-52.mp4` from pCloud `MyMovie.mp4` (falls back to on-disk slot name).
    static func suffixedFileName(
        forOnDiskFileName fileName: String,
        timestamp: String,
        threeDNKLabel: String?,
        sourceFileName: String?
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

    /// Unstamped root sidecars (manifests, meta JSON) — not suffixed; removed when media is relocated off root.
    private static func activeRootCompanionFiles() -> [URL] {
        unstampedRootFiles(where: { !isRetentionArchivableMediaFileName($0) })
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

    /// Retention applies only when handing off **finished** on-disk media to a **new** export — not while active or paused.
    static func shouldArchivePriorMediaBeforeNewExport(continueLANExport: Bool, item: WebDAVItem) -> Bool {
        if continueLANExport { return false }
        if ResumeStore.isExportInProgress(forFileKey: item.fileKey) { return false }
        if let manifest = WorkingSourceSparseCatalog.readManifest(),
           ResumeStore.isExportInProgress(forFileKey: manifest.fileKey) {
            return false
        }
        if let manifest = VanillaDownloadResumeCatalog.readManifest(),
           ResumeStore.isExportInProgress(forFileKey: manifest.fileKey) {
            return false
        }
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
            guard let suffix = retentionFileSuffix(fromFileName: name),
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
        log?("Retention: local timestamp \(timestamp) (\(TimeZone.current.identifier))")

        do {
            try fm.createDirectory(at: archiveDirectoryURL, withIntermediateDirectories: true)
        } catch {
            log?("Could not create archive/: \(error.localizedDescription)")
            return 0
        }

        var archived = 0
        for source in sources {
            let archivedName = suffixedFileName(
                forOnDiskFileName: source.lastPathComponent,
                timestamp: timestamp,
                threeDNKLabel: threeDNK,
                sourceFileName: retentionSource
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
                archived += 1
            } catch {
                log?("Could not archive \(source.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if relocate {
            if archived > 0 {
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
        for name in names where retentionFileSuffix(fromFileName: name) == suffix {
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
