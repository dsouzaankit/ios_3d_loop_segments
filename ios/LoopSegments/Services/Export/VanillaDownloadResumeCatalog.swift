import Foundation

/// Tracks which pCloud item `_vanilla_download.*` belongs to so export can resume after drops or retry.
enum VanillaDownloadResumeCatalog {
    struct Manifest: Codable {
        var fileKey: String
        var totalLength: Int64
        var href: String?
    }

    enum ResumePlan: Sendable {
        case startFresh
        case resume(offset: Int64)
        case alreadyComplete
    }

    static var manifestURL: URL {
        ExportPaths.mediaExportDirectory.appendingPathComponent("_vanilla_download.meta.json")
    }

    static func readManifest() -> Manifest? {
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return nil
        }
        return manifest
    }

    static func save(fileKey: String, totalLength: Int64, href: String?) {
        let manifest = Manifest(fileKey: fileKey, totalLength: totalLength, href: href)
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: manifestURL)
    }

    static func matches(fileKey: String, totalLength: Int64) -> Bool {
        guard let manifest = readManifest() else { return false }
        return manifest.fileKey == fileKey && manifest.totalLength == totalLength
    }

    static func resumePlan(
        fileKey: String,
        totalLength: Int64,
        destinationURL: URL
    ) -> ResumePlan {
        guard totalLength > 0 else { return .startFresh }
        let fm = FileManager.default
        guard let manifest = readManifest(),
              manifest.fileKey == fileKey,
              manifest.totalLength == totalLength else {
            return .startFresh
        }
        guard fm.fileExists(atPath: destinationURL.path) else {
            return .startFresh
        }
        let onDisk = (try? fm.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        if onDisk > totalLength {
            return .startFresh
        }
        if onDisk >= totalLength {
            return .alreadyComplete
        }
        if onDisk > 0 {
            return .resume(offset: onDisk)
        }
        return .startFresh
    }

    static func initialDownloadedBytes(
        fileKey: String,
        totalLength: Int64,
        destinationURL: URL
    ) -> Int64 {
        switch resumePlan(fileKey: fileKey, totalLength: totalLength, destinationURL: destinationURL) {
        case .startFresh:
            return 0
        case .resume(let offset):
            return offset
        case .alreadyComplete:
            return totalLength
        }
    }
}
