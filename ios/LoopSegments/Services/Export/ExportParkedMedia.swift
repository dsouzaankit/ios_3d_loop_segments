import Foundation

/// Parks in-progress root export media under `pcld_ios_media/parked/<filename>/` during handoff
/// so another export can use the root slot. Restore before sparse `tryAdopt` on resume.
/// Folder names use the source filename (WebDAV-friendly); `fileKey` stays in `_parked_meta.json`.
/// Playable partials are listed on LAN/WebDAV; prune follows the paused queue (not archive timestamps).
enum ExportParkedMedia {
    static let folderName = "parked"
    private static let metaFileName = "_parked_meta.json"

    struct Meta: Codable {
        var fileKey: String
        var displayName: String
        var parkedAt: Date
        var href: String?
        var folderPath: String?
        var seekMs: Int64?
    }

    static var parkedRootURL: URL {
        ExportPaths.mediaExportDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Existing park dir for `fileKey` (filename folder, collision suffix, or legacy fileKey folder).
    static func resolveParkDirectory(forFileKey fileKey: String) -> URL? {
        let key = fileKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let fm = FileManager.default
        let root = parkedRootURL
        guard fm.fileExists(atPath: root.path),
              let names = try? fm.contentsOfDirectory(atPath: root.path) else {
            return nil
        }
        for name in names {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let meta = readMeta(in: dir), meta.fileKey == key {
                return dir
            }
        }
        // Legacy builds used sanitized fileKey as the folder name (often a UUID).
        let legacy = root.appendingPathComponent(sanitizePathComponent(key), isDirectory: true)
        if fm.fileExists(atPath: legacy.path) {
            return legacy
        }
        return nil
    }

    static func folderURL(forFileKey fileKey: String) -> URL {
        resolveParkDirectory(forFileKey: fileKey)
            ?? parkedRootURL.appendingPathComponent(sanitizePathComponent(fileKey), isDirectory: true)
    }

    /// Sanitize a single path component for `parked/<name>/`.
    static func sanitizePathComponent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/\\:\0*?\"<>|")
        var name = trimmed.components(separatedBy: illegal).joined(separator: "_")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name = String(name.dropFirst()) }
        if name.isEmpty { return "unknown" }
        if name.count > 120 { name = String(name.prefix(120)) }
        return name
    }

    /// Stable short suffix for collision disambiguation (from fileKey).
    private static func shortStableSuffix(forFileKey fileKey: String) -> String {
        let alnum = fileKey.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let s = String(String.UnicodeScalarView(alnum))
        if s.count >= 8 { return String(s.suffix(8)) }
        if !s.isEmpty { return s }
        return String(format: "%08x", fileKey.utf8.reduce(into: UInt32(0)) { partial, byte in
            partial = partial &* 1_664_525 &+ UInt32(byte) &+ 1_013_904_223
        })
    }

    /// Prefer `MyClip.mp4`; on name collision with another fileKey use `MyClip.mp4__abcd1234`.
    private static func uniqueFolderName(displayName: String, fileKey: String) -> String {
        let base = sanitizePathComponent(displayName)
        let fm = FileManager.default
        let root = parkedRootURL
        let preferredURL = root.appendingPathComponent(base, isDirectory: true)
        if !fm.fileExists(atPath: preferredURL.path) {
            return base
        }
        if let meta = readMeta(in: preferredURL), meta.fileKey == fileKey {
            return base
        }
        return sanitizePathComponent("\(base)__\(shortStableSuffix(forFileKey: fileKey))")
    }

    static func hasPark(forFileKey fileKey: String) -> Bool {
        guard let dir = resolveParkDirectory(forFileKey: fileKey) else { return false }
        let working = dir.appendingPathComponent(ExportPaths.workingSourceURL.lastPathComponent)
        return FileManager.default.fileExists(atPath: working.path)
            || ((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == false)
    }

    /// Move root media + companions into `parked/<filename>/` (replaces any prior park for that key).
    @discardableResult
    static func parkActiveRootMedia(
        fileKey: String,
        displayName: String?,
        href: String? = nil,
        folderPath: String? = nil,
        seekMs: Int64? = nil,
        log: ((String) -> Void)? = nil
    ) -> Int {
        let key = fileKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            log?("Park skipped — missing fileKey")
            return 0
        }
        let media = ExportMediaArchive.activeRootMediaFiles()
        let companions = ExportMediaArchive.activeRootCompanionFilesForParking()
        guard !media.isEmpty || !companions.isEmpty else {
            log?("Park skipped — no root media for \(displayName ?? key)")
            return 0
        }

        let name = (displayName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? ExportRetentionSourceCatalog.read()?.sourceFileName
            ?? key

        // Drop any prior park for this key (filename folder or legacy UUID folder).
        _ = removePark(forFileKey: key)

        let fm = FileManager.default
        let folderLeaf = uniqueFolderName(displayName: name, fileKey: key)
        let destDir = parkedRootURL.appendingPathComponent(folderLeaf, isDirectory: true)
        do {
            try fm.createDirectory(at: parkedRootURL, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destDir.path) {
                try fm.removeItem(at: destDir)
            }
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            log?("Could not create parked/: \(error.localizedDescription)")
            return 0
        }

        var moved = 0
        for source in media + companions {
            let dest = destDir.appendingPathComponent(source.lastPathComponent)
            do {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.moveItem(at: source, to: dest)
                moved += 1
                log?(
                    "Parked \(ExportPaths.pathRelativeToExports(source)) → " +
                        "\(ExportPaths.pathRelativeToExports(dest))"
                )
            } catch {
                log?("Could not park \(source.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let resolvedHref = href?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFolder: String? = {
            if let folderPath, !folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return WebDAVURLBuilder.directoryListingPath(folderPath)
            }
            if let resolvedHref, !resolvedHref.isEmpty,
               let parent = WebDAVRenameReconcile.parentBrowsePath(forFileHref: resolvedHref) {
                return parent
            }
            return nil
        }()
        let meta = Meta(
            fileKey: key,
            displayName: name,
            parkedAt: Date(),
            href: (resolvedHref?.isEmpty == false) ? resolvedHref : nil,
            folderPath: resolvedFolder,
            seekMs: seekMs.map { max(0, $0) }
        )
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: destDir.appendingPathComponent(metaFileName), options: .atomic)
        }

        WorkingSourceSparseCatalog.remove()
        if !ExportPaths.vanillaPrimaryMediaExistsOnDisk() {
            ExportPlaybackState.shared.setVanillaDownloadActive(false)
        }
        ExportPlaybackState.shared.clearSparseWorkingPlaybackHints()
        _ = ExportMediaArchive.removeLeftoverRootCompanionsAfterParking(log: log)

        if moved > 0 {
            log?(
                "Export handoff: parked \(moved) file(s) under pcld_ios_media/\(folderName)/" +
                    "\(folderLeaf)/ (LAN/WebDAV; sparse keep)"
            )
        }
        return moved
    }

    /// One playable parked path per `fileKey` (prefer `_working.mp4`, then any media).
    static func primaryPlaybackRelativePath(forFileKey fileKey: String) -> String? {
        let key = fileKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let dir = resolveParkDirectory(forFileKey: key) else { return nil }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        let preferred = ExportPaths.workingSourceURL.lastPathComponent
        let ordered = names.sorted { a, b in
            if a == preferred { return true }
            if b == preferred { return false }
            return a < b
        }
        for name in ordered {
            guard ExportPaths.isLANBrowsableMediaFile(fileName: name) else { continue }
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { continue }
            return ExportPaths.pathRelativeToExports(url)
        }
        return nil
    }

    /// Friendly LAN label (source filename from meta when present).
    static func lanPlaybackLabel(forRelativePath relativePath: String) -> String {
        let leaf = (relativePath as NSString).lastPathComponent
        guard isUnderParkedLANPath(relativePath) else { return relativePath }
        let metaName = (lanResumeTrigger(forRelativePath: relativePath)?.displayName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !metaName.isEmpty else { return relativePath }
        let pipelineLeaves: Set<String> = [
            ExportPaths.workingSourceURL.lastPathComponent,
            ExportPaths.vanillaFastStartURL.lastPathComponent,
            ExportPaths.workingTranscodedURL.lastPathComponent,
        ]
        let isPipelineLeaf = pipelineLeaves.contains(leaf)
            || leaf.hasPrefix("_vanilla_download.")
            || leaf.hasPrefix("_working_pcloud_transcode")
        if isPipelineLeaf {
            return metaName
        }
        if leaf == metaName { return metaName }
        return "\(metaName) (\(leaf))"
    }

    /// LAN Resume/Export button payload for a parked media relative path.
    static func lanResumeTrigger(forRelativePath relativePath: String) -> Meta? {
        guard isUnderParkedLANPath(relativePath) else { return nil }
        let url = ExportPaths.urlUnderExports(relativePath: relativePath)
        let dir = url.deletingLastPathComponent()
        return readMeta(in: dir)
    }

    /// Restore parked media to root when resuming the same `fileKey` (before sparse adopt).
    @discardableResult
    static func restoreToRootIfNeeded(
        fileKey: String,
        log: ((String) -> Void)? = nil
    ) -> Bool {
        let key = fileKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        guard let parkDir = resolveParkDirectory(forFileKey: key) else { return false }
        let fm = FileManager.default

        let parkedWorking = parkDir.appendingPathComponent(ExportPaths.workingSourceURL.lastPathComponent)
        let parkedSparse = parkDir.appendingPathComponent(ExportPaths.workingSourceManifestURL.lastPathComponent)
        let rootWorking = ExportPaths.workingSourceURL

        if let rootSize = (try? fm.attributesOfItem(atPath: rootWorking.path)[.size] as? NSNumber)?.int64Value,
           rootSize > 0,
           WorkingSourceSparseCatalog.tryAdopt(
            fileKey: key,
            totalLength: rootSize,
            fileURL: rootWorking
           ) != nil {
            return false
        }

        let parkNames = (try? fm.contentsOfDirectory(atPath: parkDir.path)) ?? []
        guard fm.fileExists(atPath: parkedWorking.path)
            || fm.fileExists(atPath: parkedSparse.path)
            || parkNames.contains(where: { $0 != metaFileName })
        else {
            return false
        }

        // Clear conflicting root media from another title before restoring.
        if ExportMediaArchive.hasActiveExportMediaOnDisk() {
            let timestamp = ExportMediaArchive.newRetentionTimestamp()
            let prior = ExportRetentionSourceCatalog.read()?.sourceFileName
            let archived = ExportMediaArchive.archiveActiveMedia(
                timestamp: timestamp,
                sourceFileName: prior,
                log: log
            )
            if archived > 0 {
                log?("Restore park: archived \(archived) conflicting root file(s) first")
            }
        }

        guard let names = try? fm.contentsOfDirectory(atPath: parkDir.path) else { return false }
        var restored = 0
        for name in names where name != metaFileName {
            let source = parkDir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let dest = ExportPaths.mediaExportDirectory.appendingPathComponent(name)
            do {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.moveItem(at: source, to: dest)
                restored += 1
                log?(
                    "Restored parked \(ExportPaths.pathRelativeToExports(source)) → " +
                        "\(ExportPaths.pathRelativeToExports(dest))"
                )
            } catch {
                log?("Could not restore \(name): \(error.localizedDescription)")
            }
        }
        try? fm.removeItem(at: parkDir)
        if restored > 0 {
            log?("Export resume: restored \(restored) parked file(s) to pcld_ios_media/ for sparse adopt")
        }
        return restored > 0
    }

    @discardableResult
    static func removePark(forFileKey fileKey: String, log: ((String) -> Void)? = nil) -> Int {
        guard let dir = resolveParkDirectory(forFileKey: fileKey) else { return 0 }
        let fm = FileManager.default
        let leaf = dir.lastPathComponent
        let count = ((try? fm.contentsOfDirectory(atPath: dir.path))?.count) ?? 1
        do {
            try fm.removeItem(at: dir)
            log?("Removed parked/\(leaf)/ (\(count) item(s))")
            return count
        } catch {
            log?("Could not remove parked folder: \(error.localizedDescription)")
            return 0
        }
    }

    @discardableResult
    static func removeAll(log: ((String) -> Void)? = nil) -> Int {
        let fm = FileManager.default
        let root = parkedRootURL
        guard fm.fileExists(atPath: root.path) else { return 0 }
        var removed = 0
        if let names = try? fm.contentsOfDirectory(atPath: root.path) {
            for name in names {
                let url = root.appendingPathComponent(name)
                do {
                    try fm.removeItem(at: url)
                    removed += 1
                    log?("Removed parked/\(name)")
                } catch {
                    log?("Could not remove parked/\(name): \(error.localizedDescription)")
                }
            }
        }
        try? fm.removeItem(at: root)
        return removed
    }

    /// Drop parks that are no longer in the paused / in-progress set (and not the live fileKey).
    static func pruneOrphans(
        keepingFileKeys keep: Set<String>,
        log: ((String) -> Void)? = nil
    ) {
        let fm = FileManager.default
        let root = parkedRootURL
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names {
            let url = root.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let parkKey: String
            if let meta = readMeta(in: url) {
                parkKey = meta.fileKey
            } else {
                // Legacy UUID folder with no/unreadable meta — treat folder name as key.
                parkKey = name
            }
            guard !keep.contains(parkKey) else { continue }
            do {
                try fm.removeItem(at: url)
                log?("Pruned orphan parked/\(name)/")
            } catch {
                log?("Could not prune parked/\(name): \(error.localizedDescription)")
            }
        }
    }

    /// LAN playback index paths for parked media (playable partials).
    static func listLANPlaybackRelativePaths(limit: Int = 32) -> [String] {
        let fm = FileManager.default
        let root = parkedRootURL
        guard fm.fileExists(atPath: root.path),
              let folders = try? fm.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        var scored: [(path: String, date: Date)] = []
        for folder in folders {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let metaDate = readMeta(in: dir)?.parkedAt
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names {
                guard ExportPaths.isLANBrowsableMediaFile(fileName: name) else { continue }
                let url = dir.appendingPathComponent(name)
                var isFileDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isFileDir), !isFileDir.boolValue else {
                    continue
                }
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 0 else { continue }
                let date = metaDate
                    ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                scored.append((ExportPaths.pathRelativeToExports(url), date))
            }
        }
        scored.sort { $0.date > $1.date }
        return scored.prefix(max(0, limit)).map(\.path)
    }

    static func isUnderParkedLANPath(_ relativePath: String) -> Bool {
        let normalized = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = "\(ExportPaths.mediaExportFolderName)/\(folderName)/"
        return normalized.hasPrefix(prefix)
    }

    private static func readMeta(in dir: URL) -> Meta? {
        let url = dir.appendingPathComponent(metaFileName)
        guard let data = try? Data(contentsOf: url),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else {
            return nil
        }
        return meta
    }
}
