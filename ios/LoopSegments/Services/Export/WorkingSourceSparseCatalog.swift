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
        /// Resume / seek start for LAN `#t=` links (seconds).
        var playbackStartSeconds: Double?
        var durationSeconds: Double?
        var exportCursorSeconds: Double?

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
        tailOnDisk: Bool,
        playbackStartSeconds: Double? = nil,
        durationSeconds: Double? = nil,
        exportCursorSeconds: Double? = nil
    ) {
        let manifest = Manifest(
            fileKey: fileKey,
            totalLength: totalLength,
            href: href,
            spans: filledRanges.map { Manifest.Span(lower: $0.lowerBound, upper: $0.upperBound) },
            headOnDisk: headOnDisk,
            tailOnDisk: tailOnDisk,
            playbackStartSeconds: playbackStartSeconds,
            durationSeconds: durationSeconds,
            exportCursorSeconds: exportCursorSeconds
        )
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: manifestURL)
    }

    /// Reload dense spans from disk into `ExportPlaybackState` (LAN playback when export is idle).
    static func refreshPlaybackState(for fileURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path),
              let sizeNum = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber,
              sizeNum.int64Value > 0 else {
            return
        }
        let total = sizeNum.int64Value
        let probed = probeLayoutOnDisk(fileURL: fileURL, totalLength: total)
        if let manifest = loadManifest(totalLength: total),
           let manifestLayout = layout(from: manifest, fileURL: fileURL, totalLength: total) {
            let merged = AdoptedLayout(
                filledRanges: manifestLayout.filledRanges,
                headOnDisk: manifestLayout.headOnDisk || probed.headOnDisk,
                tailOnDisk: manifestLayout.tailOnDisk || probed.tailOnDisk
            )
            applyLayout(
                merged,
                totalLength: total,
                playbackStartSeconds: manifest.playbackStartSeconds,
                durationSeconds: manifest.durationSeconds,
                exportCursorSeconds: manifest.exportCursorSeconds
            )
            return
        }
        applyLayout(probed, totalLength: total, playbackStartSeconds: nil, durationSeconds: nil, exportCursorSeconds: nil)
    }

    private static func applyLayout(
        _ layout: AdoptedLayout,
        totalLength: Int64,
        playbackStartSeconds: Double?,
        durationSeconds: Double?,
        exportCursorSeconds: Double?
    ) {
        ExportPlaybackState.shared.restoreLANPlayback(
            totalBytes: totalLength,
            filledSpans: layout.filledRanges,
            headOnDisk: layout.headOnDisk,
            tailOnDisk: layout.tailOnDisk,
            playbackStartSeconds: playbackStartSeconds,
            durationSeconds: durationSeconds,
            exportCursorSeconds: exportCursorSeconds
        )
    }

    private static func loadManifest(totalLength: Int64) -> Manifest? {
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.totalLength == totalLength else {
            return nil
        }
        return manifest
    }

    private static func layout(from manifest: Manifest, fileURL: URL, totalLength: Int64) -> AdoptedLayout? {
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard onDisk == totalLength else { return nil }
        let ranges = manifest.spans.map { $0.lower ... $0.upper }
        return AdoptedLayout(
            filledRanges: ranges,
            headOnDisk: manifest.headOnDisk,
            tailOnDisk: manifest.tailOnDisk
        )
    }

    /// When the JSON manifest is missing, still expose head/tail if bytes are present on disk.
    static func probeLayoutOnDisk(fileURL: URL, totalLength: Int64) -> AdoptedLayout {
        AdoptedLayout(
            filledRanges: [],
            headOnDisk: probeFileHeadOnDisk(fileURL: fileURL),
            tailOnDisk: probeIndexTailOnDisk(fileURL: fileURL, totalLength: totalLength)
        )
    }

    private static func probeFileHeadOnDisk(fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 12), data.count >= 8 else { return false }
        return data[4 ..< 8] == Data("ftyp".utf8)
    }

    private static func probeIndexTailOnDisk(fileURL: URL, totalLength: Int64) -> Bool {
        let tailLen = WebDAVTempFileDownload.indexTailFetchBytes(totalLength: totalLength)
        let tailStart = max(0, totalLength - tailLen)
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(tailStart))
            let data = handle.readDataToEndOfFile()
            return data.range(of: Data("moov".utf8)) != nil
        } catch {
            return false
        }
    }

    static func tryAdoptFromDisk(fileURL: URL, totalLength: Int64) -> AdoptedLayout? {
        guard let manifest = loadManifest(totalLength: totalLength) else { return nil }
        return layout(from: manifest, fileURL: fileURL, totalLength: totalLength)
    }

    private static var manifestURL: URL {
        ExportPaths.workingSourceManifestURL
    }
}
