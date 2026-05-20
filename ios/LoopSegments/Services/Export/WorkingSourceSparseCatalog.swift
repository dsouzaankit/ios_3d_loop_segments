import Foundation

/// Persists which byte ranges of `_working.mp4` are dense (survives export resume).
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
        if let manifest = loadManifest(forFileAt: fileURL),
           let manifestLayout = layout(from: manifest, fileURL: fileURL, totalLength: total) {
            let merged = AdoptedLayout(
                filledRanges: manifestLayout.filledRanges,
                headOnDisk: manifestLayout.headOnDisk || probed.headOnDisk,
                tailOnDisk: manifestLayout.tailOnDisk || probed.tailOnDisk
            )
            let resolved = resolvePlaybackFields(
                manifest: manifest,
                playbackStartSeconds: manifest.playbackStartSeconds,
                durationSeconds: manifest.durationSeconds,
                exportCursorSeconds: manifest.exportCursorSeconds
            )
            applyLayout(
                merged,
                totalLength: total,
                playbackStartSeconds: resolved.playbackStartSeconds,
                durationSeconds: resolved.durationSeconds,
                exportCursorSeconds: resolved.exportCursorSeconds
            )
            migrateManifestIfNeeded(
                manifest: manifest,
                layout: merged,
                playbackStartSeconds: resolved.playbackStartSeconds,
                durationSeconds: resolved.durationSeconds,
                exportCursorSeconds: resolved.exportCursorSeconds
            )
            return
        }
        let hints = ResumeStore.lanPlaybackHints(fileKey: nil, href: nil)
        applyLayout(
            probed,
            totalLength: total,
            playbackStartSeconds: hints?.playbackStartSeconds,
            durationSeconds: hints?.durationSeconds,
            exportCursorSeconds: hints?.exportCursorSeconds
        )
        if let hints {
            save(
                fileKey: hints.fileKey,
                totalLength: total,
                href: hints.href,
                filledRanges: probed.filledRanges,
                headOnDisk: probed.headOnDisk,
                tailOnDisk: probed.tailOnDisk,
                playbackStartSeconds: hints.playbackStartSeconds,
                durationSeconds: hints.durationSeconds > 0 ? hints.durationSeconds : nil,
                exportCursorSeconds: hints.exportCursorSeconds
            )
        }
    }

    private struct ResolvedPlaybackFields {
        let playbackStartSeconds: Double?
        let durationSeconds: Double?
        let exportCursorSeconds: Double?
    }

    private static func resolvePlaybackFields(
        manifest: Manifest,
        playbackStartSeconds: Double?,
        durationSeconds: Double?,
        exportCursorSeconds: Double?
    ) -> ResolvedPlaybackFields {
        var playback = playbackStartSeconds
        var duration = durationSeconds
        var cursor = exportCursorSeconds
        if let hints = ResumeStore.lanPlaybackHints(fileKey: manifest.fileKey, href: manifest.href) {
            if playback == nil || playback == 0 {
                playback = hints.playbackStartSeconds
            }
            if duration == nil || duration == 0 {
                duration = hints.durationSeconds > 0 ? hints.durationSeconds : nil
            }
            if cursor == nil || cursor == 0 {
                cursor = hints.exportCursorSeconds
            }
        }
        return ResolvedPlaybackFields(
            playbackStartSeconds: playback,
            durationSeconds: duration,
            exportCursorSeconds: cursor
        )
    }

    private static func migrateManifestIfNeeded(
        manifest: Manifest,
        layout: AdoptedLayout,
        playbackStartSeconds: Double?,
        durationSeconds: Double?,
        exportCursorSeconds: Double?
    ) {
        let needsPlayback = (manifest.playbackStartSeconds ?? 0) <= 0
            && (playbackStartSeconds ?? 0) > 0
        let needsDuration = (manifest.durationSeconds ?? 0) <= 0
            && (durationSeconds ?? 0) > 0
        let needsCursor = (manifest.exportCursorSeconds ?? 0) <= 0
            && (exportCursorSeconds ?? 0) > 0
        guard needsPlayback || needsDuration || needsCursor else { return }
        save(
            fileKey: manifest.fileKey,
            totalLength: manifest.totalLength,
            href: manifest.href,
            filledRanges: layout.filledRanges,
            headOnDisk: layout.headOnDisk,
            tailOnDisk: layout.tailOnDisk,
            playbackStartSeconds: needsPlayback ? playbackStartSeconds : manifest.playbackStartSeconds,
            durationSeconds: needsDuration ? durationSeconds : manifest.durationSeconds,
            exportCursorSeconds: needsCursor ? exportCursorSeconds : manifest.exportCursorSeconds
        )
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

    private static func loadManifest(forFileAt fileURL: URL) -> Manifest? {
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return nil
        }
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard onDisk > 0 else { return nil }
        if manifest.totalLength != onDisk {
            manifest.totalLength = onDisk
        }
        return manifest
    }

    private static func loadManifest(totalLength: Int64) -> Manifest? {
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return nil
        }
        if manifest.totalLength != totalLength {
            manifest.totalLength = totalLength
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
        guard let manifest = loadManifest(forFileAt: fileURL) else { return nil }
        return layout(from: manifest, fileURL: fileURL, totalLength: totalLength)
    }

    /// Latest on-disk manifest (if any).
    static func readManifest() -> Manifest? {
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return nil
        }
        return manifest
    }

    /// pCloud WebDAV path for a paused export when ResumeStore lost `href`.
    static func hrefForResumeEntry(_ entry: ResumeEntry, singlePausedExport: Bool) -> String? {
        guard let manifest = readManifest() else { return nil }
        let href = manifest.href?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !href.isEmpty else { return nil }
        if manifest.fileKey == entry.fileKey { return href }
        if singlePausedExport, entry.exportInProgress { return href }
        return nil
    }

    private static var manifestURL: URL {
        ExportPaths.workingSourceManifestURL
    }
}
