import Foundation

/// pCloud source filename for the active export (used when archiving root media).
enum ExportRetentionSourceCatalog {
    struct Manifest: Codable {
        var sourceFileName: String
        var fileKey: String
        /// Set when moov-at-end remux produced `_vanilla_faststart.mp4` (archive name gets `_appFast_`).
        var appFaststartRemux: Bool?
        /// Root slot filenames already copied/moved to `archive/` this export (e.g. `_working.mp4`).
        var archivedRootSlotNames: [String]?
    }

    private static var manifestURL: URL {
        ExportPaths.mediaExportDirectory.appendingPathComponent("_export_retention_source.json")
    }

    static func save(sourceFileName: String, fileKey: String) {
        let manifest = Manifest(
            sourceFileName: sourceFileName,
            fileKey: fileKey,
            appFaststartRemux: nil,
            archivedRootSlotNames: []
        )
        write(manifest)
    }

    private static func write(_ manifest: Manifest) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? FileManager.default.createDirectory(
            at: ExportPaths.mediaExportDirectory,
            withIntermediateDirectories: true
        )
        try? data.write(to: manifestURL, options: .atomic)
    }

    static func read() -> Manifest? {
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return nil
        }
        return manifest
    }

    static func remove() {
        try? FileManager.default.removeItem(at: manifestURL)
    }

    static func markAppFaststartRemuxCompleted() {
        guard var manifest = read() else { return }
        manifest.appFaststartRemux = true
        write(manifest)
    }

    static func hadAppFaststartRemux() -> Bool {
        read()?.appFaststartRemux == true
    }

    static func isRootSlotAlreadyArchived(_ slotFileName: String) -> Bool {
        read()?.archivedRootSlotNames?.contains(slotFileName) == true
    }

    static func recordArchivedRootSlot(_ slotFileName: String) {
        guard var manifest = read() else { return }
        var slots = manifest.archivedRootSlotNames ?? []
        guard !slots.contains(slotFileName) else { return }
        slots.append(slotFileName)
        manifest.archivedRootSlotNames = slots
        write(manifest)
    }

    /// Safe stem for `archive/<stem>[_3D_*]_<time>.<ext>` (preserves pCloud basename, not pipeline slot names).
    static func sanitizedArchiveStem(from sourceFileName: String) -> String {
        let raw = (sourceFileName as NSString).lastPathComponent
        var stem = (raw as NSString).deletingPathExtension
        let illegal = CharacterSet(charactersIn: "/\\:\0")
        stem = stem.components(separatedBy: illegal).joined(separator: "_")
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty { stem = "export" }
        if stem.count > 180 {
            stem = String(stem.prefix(180))
        }
        return stem
    }
}
