import Foundation

/// Parks in-progress root export media under `pcld_ios_media/parked/<fileKey>/` during handoff
/// so another export can use the root slot. Restore before sparse `tryAdopt` on resume.
/// Playable partials are listed on LAN/WebDAV; prune follows the paused queue (not archive timestamps).
enum ExportParkedMedia {
    static let folderName = "parked"
    private static let metaFileName = "_parked_meta.json"

    struct Meta: Codable {
        var fileKey: String
        var displayName: String
        var parkedAt: Date
    }

    static var parkedRootURL: URL {
        ExportPaths.mediaExportDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    static func folderURL(forFileKey fileKey: String) -> URL {
        parkedRootURL.appendingPathComponent(sanitizedFolderName(forFileKey: fileKey), isDirectory: true)
    }

    static func sanitizedFolderName(forFileKey fileKey: String) -> String {
        let trimmed = fileKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/\\:\0")
        var name = trimmed.components(separatedBy: illegal).joined(separator: "_")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "unknown" }
        if name.count > 120 { name = String(name.prefix(120)) }
        return name
    }

    static func hasPark(forFileKey fileKey: String) -> Bool {
        let dir = folderURL(forFileKey: fileKey)
        let working = dir.appendingPathComponent(ExportPaths.workingSourceURL.lastPathComponent)
        return FileManager.default.fileExists(atPath: working.path)
            || FileManager.default.fileExists(atPath: dir.path)
                && ((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == false)
    }

    /// Move root media + companions into `parked/<fileKey>/` (replaces any prior park for that key).
    @discardableResult
    static func parkActiveRootMedia(
        fileKey: String,
        displayName: String?,
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

        let fm = FileManager.default
        let destDir = folderURL(forFileKey: key)
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

        let name = (displayName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? ExportRetentionSourceCatalog.read()?.sourceFileName
            ?? key
        let meta = Meta(fileKey: key, displayName: name, parkedAt: Date())
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: destDir.appendingPathComponent(metaFileName), options: .atomic)
        }

        WorkingSourceSparseCatalog.remove()
        if !ExportPaths.vanillaPrimaryMediaExistsOnDisk() {
            ExportPlaybackState.shared.setVanillaDownloadActive(false)
        }
        ExportPlaybackState.shared.clearSparseWorkingPlaybackHints()
        // Any leftover root companions (e.g. failed move) — drop so root is clear for the next export.
        _ = ExportMediaArchive.removeLeftoverRootCompanionsAfterParking(log: log)

        if moved > 0 {
            log?(
                "Export handoff: parked \(moved) file(s) under pcld_ios_media/\(folderName)/" +
                    "\(sanitizedFolderName(forFileKey: key))/ (LAN-playable partial; sparse keep)"
            )
        }
        return moved
    }

    /// Restore parked media to root when resuming the same `fileKey` (before sparse adopt).
    @discardableResult
    static func restoreToRootIfNeeded(
        fileKey: String,
        log: ((String) -> Void)? = nil
    ) -> Bool {
        let key = fileKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        let parkDir = folderURL(forFileKey: key)
        let fm = FileManager.default
        guard fm.fileExists(atPath: parkDir.path) else { return false }

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
        let dir = folderURL(forFileKey: fileKey)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return 0 }
        let count = ((try? fm.contentsOfDirectory(atPath: dir.path))?.count) ?? 1
        do {
            try fm.removeItem(at: dir)
            log?("Removed parked/\(sanitizedFolderName(forFileKey: fileKey))/ (\(count) item(s))")
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
        let keepFolders = Set(keep.map { sanitizedFolderName(forFileKey: $0) })
        for name in names {
            guard !keepFolders.contains(name) else { continue }
            let url = root.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
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
