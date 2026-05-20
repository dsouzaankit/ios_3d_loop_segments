import Foundation

/// Persists which byte ranges of `_export_source_working.mp4` are dense (survives export resume).
enum WorkingSourceSparseCatalog {
    struct Manifest: Codable {
        var fileKey: String
        var totalLength: Int64
        var href: String?
        var spans: [Span]
        var headOnDisk: Bool
        var tailOnDisk: Bool

        struct Span: Codable {
            var lower: Int64
            var upper: Int64
        }
    }

    struct AdoptedLayout: Sendable {
        let filledRanges: [ClosedRange<Int64>]
        let headOnDisk: Bool
        let tailOnDisk: Bool
    }

    static func tryAdopt(fileKey: String, totalLength: Int64, fileURL: URL) -> AdoptedLayout? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path),
              fm.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.fileKey == fileKey,
              manifest.totalLength == totalLength else {
            return nil
        }
        let onDisk = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard onDisk == totalLength else { return nil }
        let ranges = manifest.spans.map { $0.lower ... $0.upper }
        return AdoptedLayout(
            filledRanges: ranges,
            headOnDisk: manifest.headOnDisk,
            tailOnDisk: manifest.tailOnDisk
        )
    }

    static func save(
        fileKey: String,
        totalLength: Int64,
        href: String?,
        filledRanges: [ClosedRange<Int64>],
        headOnDisk: Bool,
        tailOnDisk: Bool
    ) {
        let manifest = Manifest(
            fileKey: fileKey,
            totalLength: totalLength,
            href: href,
            spans: filledRanges.map { Manifest.Span(lower: $0.lowerBound, upper: $0.upperBound) },
            headOnDisk: headOnDisk,
            tailOnDisk: tailOnDisk
        )
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: manifestURL)
    }

    private static var manifestURL: URL {
        ExportPaths.workingSourceManifestURL
    }
}
