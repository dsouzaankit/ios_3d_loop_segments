import Foundation

/// Renames finished root-level `pcld_ios_media/` files with a local timestamp suffix before a new export overwrites them.
/// `pcld_ios_media/loop/` (`op_*.mp4`) is not retained — only siblings like `_working.mp4`, vanilla/transcode copies.
enum ExportMediaArchive {
    static let retentionCount = 10
    static let manualKeepCount = 2

    private static let reservedTopLevelNames: Set<String> = [
        ExportPaths.segmentLoopFolderName,
        "scripts",
        "archive",
    ]

    private static let retentionTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    /// Local wall-clock stamp for new retains, e.g. `2026-05-22_14-30-52`.
    static func newRetentionTimestamp() -> String {
        retentionTimestampFormatter.string(from: Date())
    }

    /// Suffix token in the filename, including leading `_` (new local time or legacy unix).
    static func retentionFileSuffix(fromFileName name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension.lastPathComponent
        if let local = localRetentionSuffix(in: stem) {
            return local
        }
        guard let underscore = stem.lastIndex(of: "_") else { return nil }
        let token = stem[stem.index(after: underscore)...]
        guard token.count >= 10, token.allSatisfy(\.isNumber), Int(token) != nil else { return nil }
        return "_\(token)"
    }

    static func isRetentionStampedFileName(_ name: String) -> Bool {
        retentionFileSuffix(fromFileName: name) != nil
    }

    private static func localRetentionSuffix(in stem: String) -> String? {
        // `_yyyy-MM-dd_HH-mm-ss` at end of stem (after optional `_3D_4K`, etc.).
        let pattern = #"_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$"#
        guard let range = stem.range(of: pattern, options: .regularExpression) else { return nil }
        return String(stem[range])
    }

    private static func retentionSortDate(fromFileSuffix suffix: String) -> Date? {
        let token = String(suffix.dropFirst())
        if let date = retentionTimestampFormatter.date(from: token) {
            return date
        }
        guard let epoch = Int(token) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(epoch))
    }

    /// e.g. `_working_3D_4K_2026-05-22_14-30-52.mp4` when tier is 3K+.
    static func suffixedFileName(for fileName: String, timestamp: String, threeDNKLabel: String?) -> String {
        let ns = fileName as NSString
        let ext = ns.pathExtension
        var stem = ns.deletingPathExtension.lastPathComponent
        if let nk = threeDNKLabel, let tag = ExportVideoDimensions.threeDSuffixSegment(nkLabel: nk) {
            stem += tag
        }
        stem += "_\(timestamp)"
        if ext.isEmpty {
            return stem
        }
        return "\(stem).\(ext)"
    }

    /// Unstamped root-level media files only (`pcld_ios_media/`, not `loop/`).
    static func activeRootMediaFiles() -> [URL] {
        let fm = FileManager.default
        _ = ExportPaths.mediaExportDirectory
        guard let rootNames = try? fm.contentsOfDirectory(atPath: ExportPaths.mediaExportDirectory.path) else {
            return []
        }
        var files: [URL] = []
        for name in rootNames {
            guard !reservedTopLevelNames.contains(name) else { continue }
            guard !isRetentionStampedFileName(name) else { continue }
            let url = ExportPaths.mediaExportDirectory.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            files.append(url)
        }
        return files
    }

    static func hasActiveExportMediaOnDisk() -> Bool {
        !activeRootMediaFiles().isEmpty
    }

    /// Newest retain batches first (by parsed local time or legacy unix).
    static func collectRetentionStampSuffixes() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: ExportPaths.mediaExportDirectory.path) else {
            return []
        }
        var bySuffix: [String: Date] = [:]
        for name in names {
            guard let suffix = retentionFileSuffix(fromFileName: name),
                  let date = retentionSortDate(fromFileSuffix: suffix) else { continue }
            let url = ExportPaths.mediaExportDirectory.appendingPathComponent(name)
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

    @discardableResult
    static func archiveActiveMedia(timestamp: String, log: ((String) -> Void)? = nil) -> Int {
        let fm = FileManager.default
        let sources = activeRootMediaFiles()
        guard !sources.isEmpty else { return 0 }

        let threeDNK = ExportVideoDimensions.probeNKLabelForRetention(from: sources)
        if let threeDNK, ExportVideoDimensions.threeDSuffixSegment(nkLabel: threeDNK) != nil {
            log?("Retention: inferred \(threeDNK) — suffix _3D_\(threeDNK)")
        }
        log?("Retention: local timestamp \(timestamp) (\(TimeZone.current.identifier))")

        var renamed = 0
        for source in sources {
            let newName = suffixedFileName(
                for: source.lastPathComponent,
                timestamp: timestamp,
                threeDNKLabel: threeDNK
            )
            let destination = ExportPaths.mediaExportDirectory.appendingPathComponent(newName)
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.moveItem(at: source, to: destination)
                renamed += 1
                log?(
                    "Retained \(ExportPaths.pathRelativeToExports(source)) → " +
                        "\(ExportPaths.pathRelativeToExports(destination))"
                )
            } catch {
                log?("Could not retain \(source.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if renamed > 0 {
            WorkingSourceSparseCatalog.remove()
            if !ExportPaths.vanillaDownloadCopyExistsOnDisk() {
                ExportPlaybackState.shared.setVanillaDownloadActive(false)
            }
            ExportPlaybackState.shared.clearSparseWorkingPlaybackHints()
        }
        return renamed
    }

    @discardableResult
    static func removeFiles(forStampSuffix suffix: String, log: ((String) -> Void)? = nil) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: ExportPaths.mediaExportDirectory.path) else {
            return 0
        }
        var removed = 0
        for name in names where retentionFileSuffix(fromFileName: name) == suffix {
            let url = ExportPaths.mediaExportDirectory.appendingPathComponent(name)
            do {
                try fm.removeItem(at: url)
                removed += 1
                log?("Removed \(ExportPaths.pathRelativeToExports(url))")
            } catch {
                log?("Could not remove \(name): \(error.localizedDescription)")
            }
        }
        return removed
    }

    @discardableResult
    static func pruneRetainedMedia(keepCount: Int, log: ((String) -> Void)? = nil) -> Int {
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
        var removed = 0
        for suffix in collectRetentionStampSuffixes() {
            removed += removeFiles(forStampSuffix: suffix, log: log)
        }
        removed += removeLegacyArchiveFolder(log: log)
        return removed
    }

    /// Older builds used `pcld_ios_media/archive/export_<unix>/`.
    @discardableResult
    private static func removeLegacyArchiveFolder(log: ((String) -> Void)? = nil) -> Int {
        let fm = FileManager.default
        let url = ExportPaths.mediaExportDirectory.appendingPathComponent("archive", isDirectory: true)
        guard fm.fileExists(atPath: url.path) else { return 0 }
        let count = (try? fm.subpathsOfDirectory(atPath: url.path).count) ?? 0
        do {
            try fm.removeItem(at: url)
            log?("Removed legacy pcld_ios_media/archive/ (\(count) path(s))")
            return max(count, 1)
        } catch {
            log?("Could not remove legacy archive/: \(error.localizedDescription)")
            return 0
        }
    }
}
