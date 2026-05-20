import Foundation

/// Byte span in the sparse temp file needed for a timeline window (ffmpeg `-ss` style, not from offset 0).
struct TimelineByteRange: Equatable {
    let start: Int64
    let end: Int64

    var length: Int64 { max(0, end - start) }
}

/// Downloads remote MP4 ranges into a sparse temp file for timed segment export.
final class WebDAVTempFileDownload: @unchecked Sendable {
    private static let downloadChunkBytes: Int64 = 2 * 1024 * 1024
    private static let progressStepPercent = 5
    private static let timelineSlackBytes: Int64 = 24 * 1024 * 1024
    /// Extra timeline before `startSec` when mapping to file bytes (linear estimate can lag real moov sample times).
    private static let timelineStartPrerollSeconds: Double = 45
    static let exportTimelineSlackBytes: Int64 = timelineSlackBytes

    let fileURL: URL
    let totalLength: Int64

    private let remoteURL: URL
    private let authorizationProvider: WebDAVAuthorizationProvider
    private let isCancelled: () -> Bool
    private let log: (String) -> Void

    private let lock = NSLock()
    /// Contiguous downloaded span `[regionStart, regionFilledEnd)`.
    private var regionStart: Int64 = 0
    private var regionFilledEnd: Int64 = 0
    private var tailOnDisk = false
    private var headOnDisk = false
    private var downloadTask: Task<Void, Error>?
    private var writeHandle: FileHandle?
    private var downloadCursor: Int64 = 0
    /// When set, background download stops at this byte (avoids pulling the rest of a multi‑GB file).
    private var downloadHighWaterMark: Int64 = 0
    private var backgroundPausedForStream = false
    /// Contiguous bytes downloaded from the active export window start (no holes — `regionFilledEnd` can lie).
    private var exportWindowStart: Int64 = 0
    private var exportWindowContiguousEnd: Int64 = 0
    /// Disjoint byte spans actually written (head, dense window, EOF index may be separate).
    private var filledRanges: [ClosedRange<Int64>] = []
    private let throughput = DownloadThroughput()
    private let sourceFileKey: String
    private let sourceHref: String?
    private var manifestSaveTask: Task<Void, Never>?

    init(
        fileKey: String,
        sourceHref: String?,
        remoteURL: URL,
        rangeCache: WebDAVRangeCache,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        isCancelled: @escaping () -> Bool,
        log: @escaping (String) -> Void
    ) throws {
        self.sourceFileKey = fileKey
        self.sourceHref = sourceHref
        guard let total = rangeCache.contentLengthValue(), total > 0 else {
            throw WebDAVResourceLoaderError.missingContentLength
        }
        try Self.ensureFreeDiskSpace(forBytes: total)

        self.remoteURL = remoteURL
        self.authorizationProvider = authorizationProvider
        self.isCancelled = isCancelled
        self.log = log
        self.totalLength = total
        self.fileURL = ExportPaths.workingSourceURL

        if let adopted = WorkingSourceSparseCatalog.tryAdopt(
            fileKey: fileKey,
            totalLength: total,
            fileURL: fileURL
        ) {
            writeHandle = try FileHandle(forWritingTo: fileURL)
            lock.lock()
            filledRanges = adopted.filledRanges
            headOnDisk = adopted.headOnDisk
            tailOnDisk = adopted.tailOnDisk
            restoreDownloadRegionFromFilledSpansLocked()
            lock.unlock()
            let denseBytes = adopted.filledRanges.reduce(Int64(0)) { sum, span in
                sum + span.upperBound - span.lowerBound + 1
            }
            log(
                "Reusing sparse temp for same source — \(adopted.filledRanges.count) dense region(s), " +
                    "~\(formatBytes(denseBytes)) kept from previous attempt(s)"
            )
            try applyCachedSpans(rangeCache, skipRangesAlreadyOnDisk: true)
            try finalizeSparseLayout()
        } else {
            WorkingSourceSparseCatalog.remove()
            try? FileManager.default.removeItem(at: fileURL)
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw SegmentExporterError.writerSetupFailed
            }
            writeHandle = try FileHandle(forWritingTo: fileURL)
            log("New sparse temp — prior working copy was another file or incompatible")
            try applyCachedSpans(rangeCache, skipRangesAlreadyOnDisk: false)
            try finalizeSparseLayout()
            scheduleManifestSave()
        }
    }

    /// Position download at seek (or 0). Optionally start background range fetches (off when using dense-only per minute).
    func beginExport(
        seekSeconds: Double,
        durationSeconds: Double,
        useBackgroundDownload: Bool = true
    ) {
        throughput.reset()
        applyInitialPosition(seekSeconds: seekSeconds, durationSeconds: durationSeconds)
        if useBackgroundDownload {
            startBackgroundDownload()
        } else {
            log("Dense-only temp — each minute downloaded once before passthrough (no background prefetch).")
        }
    }

    /// Sparse temp must report full remote size so AVFoundation can read `moov` at EOF.
    private func finalizeSparseLayout() throws {
        try writeHandle?.truncate(atOffset: UInt64(totalLength))
        try writeHandle?.synchronize()
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        lock.lock()
        let hasTail = tailOnDisk
        let span = filledSpanLocked()
        lock.unlock()
        log(
            "Temp sparse layout — file size \(formatBytes(onDisk)), contiguous \(formatBytes(span.start))–\(formatBytes(span.end)), index tail: \(hasTail ? "yes" : "no")"
        )
        if !hasTail {
            log("Warning: MP4 index not on disk yet — track probe may use pCloud")
        }
    }

    /// Bytes at EOF that must be on disk before AVFoundation can load tracks (moov is often multi‑MB on large HEVC).
    static func indexTailFetchBytes(totalLength: Int64) -> Int64 {
        guard totalLength > 0 else { return 4 * 1024 * 1024 }
        let scaled = totalLength / 80
        return min(48 * 1024 * 1024, max(4 * 1024 * 1024, scaled))
    }

    func ensureIndexTailOnDisk(force: Bool = false) async throws {
        try ensureWriteHandleForDownload()
        lock.lock()
        let hasTail = tailOnDisk
        lock.unlock()
        guard force || !hasTail else { return }

        let tailLen = Self.indexTailFetchBytes(totalLength: totalLength)
        let tailStart = max(0, totalLength - tailLen)
        log("Fetching MP4 index from pCloud (\(formatBytes(tailLen)) at EOF)…")
        let auth = authorizationProvider()
        let data = try await Self.fetchRange(
            remoteURL: remoteURL,
            authorization: auth,
            offset: tailStart,
            endInclusive: totalLength - 1
        )
        throughput.recordNetworkBytes(data.count)
        try write(data, at: tailStart)
        lock.lock()
        tailOnDisk = true
        lock.unlock()
        try writeHandle?.synchronize()
        publishLANPlaybackState()
    }

    func ensureFileHeadOnDisk() async throws {
        try ensureWriteHandleForDownload()
        lock.lock()
        let hasHead = headOnDisk
        lock.unlock()
        guard !hasHead else { return }
        let headLen = min(Int64(512 * 1024), totalLength)
        guard headLen > 0 else { return }
        log("Fetching MP4 file header from pCloud (\(formatBytes(headLen)) at start)…")
        let auth = authorizationProvider()
        let data = try await Self.fetchRange(
            remoteURL: remoteURL,
            authorization: auth,
            offset: 0,
            endInclusive: headLen - 1
        )
        throughput.recordNetworkBytes(data.count)
        try write(data, at: 0)
        lock.lock()
        headOnDisk = true
        lock.unlock()
        try writeHandle?.synchronize()
        publishLANPlaybackState()
    }

    deinit {
        manifestSaveTask?.cancel()
        persistManifestNow()
        downloadTask?.cancel()
        try? writeHandle?.close()
    }

    /// Stop background range fetches but keep the sparse temp file (e.g. before pCloud stream export).
    func pauseBackgroundDownload() {
        lock.lock()
        backgroundPausedForStream = true
        lock.unlock()
        downloadTask?.cancel()
        downloadTask = nil
    }

    func ensureWriteHandleForDownload() throws {
        lock.lock()
        let needsHandle = writeHandle == nil
        lock.unlock()
        guard needsHandle else { return }
        writeHandle = try FileHandle(forWritingTo: fileURL)
    }

    /// AVAssetReader and an open write `FileHandle` on the same path can race (-11847 Operation Interrupted).
    func closeWriteHandleForPassthroughRead(log: ((String) -> Void)? = nil) {
        lock.lock()
        let handle = writeHandle
        writeHandle = nil
        lock.unlock()
        try? handle?.synchronize()
        try? handle?.close()
        log?("Temp file write handle closed — passthrough read")
    }

    func cancel() {
        pauseBackgroundDownload()
        try? writeHandle?.close()
        writeHandle = nil
    }

    func filledSpan() -> TimelineByteRange {
        lock.lock()
        defer { lock.unlock() }
        return filledSpanLocked()
    }

    /// Byte spans present on disk (sparse holes are not included).
    func filledSpansOnDisk() -> [ClosedRange<Int64>] {
        lock.lock()
        defer { lock.unlock() }
        return filledRanges
    }

    /// Reads from the temp file when every byte in `[offset, offset+length)` is in `filledRanges`.
    func readLocalBytes(offset: Int64, length: Int) -> Data? {
        guard length > 0, offset >= 0, offset + Int64(length) <= totalLength else { return nil }
        lock.lock()
        let spans = filledRanges
        lock.unlock()
        guard Self.rangeFullyCovered(offset: offset, length: length, spans: spans) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: length)
        } catch {
            return nil
        }
    }

    func hasIndexTailOnDisk() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tailOnDisk
    }

    func hasHeadOnDisk() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return headOnDisk
    }

    func logDownloadStarted() {
        log("Sparse temp — \(formatBytes(totalLength)) on disk (one dense window per 60s segment)…")
    }

    /// Limit background range fetches to `[regionStart, highWaterMark)` (plus index tail).
    func setDownloadHighWaterMark(_ highWaterMark: Int64) {
        lock.lock()
        downloadHighWaterMark = min(max(0, highWaterMark), totalLength)
        lock.unlock()
    }

    /// Fill every byte in `range` from pCloud (dense on disk) so AVFoundation can open the sparse temp.
    func ensureContiguousRange(_ range: TimelineByteRange, force: Bool = false) async throws {
        guard range.length > 0 else { return }
        try ensureWriteHandleForDownload()
        let tailStart = max(0, totalLength - Self.indexTailFetchBytes(totalLength: totalLength))
        let rangeEnd = min(range.end, totalLength)
        let needLen = rangeEnd - range.start

        lock.lock()
        let contiguousMarked = exportWindowStart == range.start && exportWindowContiguousEnd >= rangeEnd
        let bytesOnDisk = Self.rangeFullyCovered(
            offset: range.start,
            length: Int(needLen),
            spans: filledRanges
        )
        lock.unlock()
        if !force, contiguousMarked, bytesOnDisk {
            lock.lock()
            exportWindowStart = range.start
            exportWindowContiguousEnd = max(exportWindowContiguousEnd, rangeEnd)
            lock.unlock()
            log(
                "Window \(formatBytes(range.start))–\(formatBytes(rangeEnd)) already dense on disk — skip re-download"
            )
            return
        }

        log(
            "Downloading window \(formatBytes(range.start))–\(formatBytes(rangeEnd)) from pCloud (\(formatBytes(needLen)), dense fill)…"
        )
        var offset = range.start
        var lastLoggedPercent = -Self.progressStepPercent
        var lastProgressLog = CFAbsoluteTimeGetCurrent()
        while offset < rangeEnd {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            let end = min(offset + Self.downloadChunkBytes - 1, rangeEnd - 1)
            let auth = authorizationProvider()
            let data = try await Self.fetchRange(
                remoteURL: remoteURL,
                authorization: auth,
                offset: offset,
                endInclusive: end
            )
            throughput.recordNetworkBytes(data.count)
            try write(data, at: offset)
            offset = end + 1
            let done = offset - range.start
            let now = CFAbsoluteTimeGetCurrent()
            let pct = needLen > 0 ? Int(done * 100 / needLen) : 100
            if pct >= lastLoggedPercent + Self.progressStepPercent || now - lastProgressLog >= 20 {
                lastProgressLog = now
                lastLoggedPercent = (pct / Self.progressStepPercent) * Self.progressStepPercent
                log(
                    "Downloading window \(pct)% — \(formatBytes(done)) / \(formatBytes(needLen)) (dense)\(speedLogSuffix())"
                )
            }
        }
        if tailStart < totalLength, !hasIndexTailOnDisk() {
            try await ensureIndexTailOnDisk()
        }
        try writeHandle?.synchronize()
        lock.lock()
        exportWindowStart = range.start
        exportWindowContiguousEnd = max(exportWindowContiguousEnd, rangeEnd)
        lock.unlock()
        log(
            "Window on disk — contiguous \(formatBytes(range.start))–\(formatBytes(exportWindowContiguousEnd))\(averageSpeedLogSuffix())"
        )
        persistManifestNow()
        publishLANPlaybackState()
    }

    /// Updates LAN range gating + playback start hint for `_export_source_working.mp4`.
    func publishLANPlaybackState(mediaCursorSeconds: Double? = nil) {
        let spans = filledSpansOnDisk()
        let head = hasHeadOnDisk()
        let tail = hasIndexTailOnDisk()
        ExportPlaybackState.shared.syncSparseLayout(
            totalBytes: totalLength,
            filledSpans: spans,
            headOnDisk: head,
            tailOnDisk: tail
        )
        if let mediaCursorSeconds {
            ExportPlaybackState.shared.updateCursor(seconds: mediaCursorSeconds)
        }
    }

    /// File byte span that must be on disk for media `[timelineStartSeconds, timelineEndSeconds]`.
    func byteRangeForTimeline(
        timelineStartSeconds: Double,
        timelineEndSeconds: Double,
        durationSeconds: Double
    ) -> TimelineByteRange {
        Self.byteRangeForTimeline(
            totalLength: totalLength,
            timelineStartSeconds: timelineStartSeconds,
            timelineEndSeconds: timelineEndSeconds,
            durationSeconds: durationSeconds
        )
    }

    static func byteRangeForTimeline(
        totalLength: Int64,
        timelineStartSeconds: Double,
        timelineEndSeconds: Double,
        durationSeconds: Double
    ) -> TimelineByteRange {
        guard durationSeconds > 0, totalLength > 0 else {
            return TimelineByteRange(start: 0, end: totalLength)
        }
        let startSec = min(max(0, timelineStartSeconds), durationSeconds)
        let endSec = min(max(startSec, timelineEndSeconds), durationSeconds)
        let effectiveDuration = Self.effectiveDurationSeconds(
            reported: durationSeconds,
            totalBytes: totalLength
        )
        let timePrerollSec = startSec > 0.5
            ? min(Self.timelineStartPrerollSeconds, startSec)
            : 0
        let byteStartSec = max(0, startSec - timePrerollSec)
        let preroll = Self.keyframePrerollBytes(timelineStartSeconds: byteStartSec, totalLength: totalLength)
        let startByte = max(
            0,
            Int64((byteStartSec / effectiveDuration) * Double(totalLength)) - preroll
        )
        var endByte = min(
            totalLength,
            Int64((endSec / effectiveDuration) * Double(totalLength)) + Self.timelineSlackBytes
        )
        let windowSeconds = endSec - startSec
        if windowSeconds <= 60.5, startSec <= 0.5 {
            let oneMinuteFromSize = Int64((60.0 / effectiveDuration) * Double(totalLength)) + Self.timelineSlackBytes
            var floor = oneMinuteFromSize
            if totalLength > 900_000_000 {
                floor = max(floor, Int64(300 * 1024 * 1024) + Self.timelineSlackBytes)
            } else if totalLength > 500_000_000 {
                floor = max(floor, Int64(180 * 1024 * 1024) + Self.timelineSlackBytes)
            }
            endByte = max(endByte, min(floor, totalLength))
        }
        if endByte <= startByte {
            endByte = min(totalLength, startByte + Self.downloadChunkBytes)
        }
        return TimelineByteRange(start: startByte, end: endByte)
    }

    func isRangeFilled(_ range: TimelineByteRange) -> Bool {
        if isByteRangeFullyOnDisk(range) { return true }
        lock.lock()
        defer { lock.unlock() }
        guard exportWindowStart == range.start else { return false }
        return exportWindowContiguousEnd >= range.end
    }

    /// True when every byte in `range` was written to the sparse temp (not just `exportWindowContiguousEnd`).
    func isByteRangeFullyOnDisk(_ range: TimelineByteRange) -> Bool {
        lock.lock()
        let spans = filledRanges
        lock.unlock()
        guard range.length > 0, range.length <= Int64.max else { return range.length == 0 }
        return Self.rangeFullyCovered(offset: range.start, length: Int(range.length), spans: spans)
    }

    private func beginTrackingExportWindow(_ range: TimelineByteRange) {
        exportWindowStart = range.start
        if regionStart <= range.start, regionFilledEnd > range.start {
            exportWindowContiguousEnd = regionFilledEnd
        } else if regionStart == range.start {
            exportWindowContiguousEnd = regionFilledEnd
        } else {
            exportWindowContiguousEnd = range.start
        }
    }

    func waitUntilWindowReady(
        timelineStartSeconds: Double,
        timelineEndSeconds: Double,
        durationSeconds: Double
    ) async throws {
        guard durationSeconds > 0 else { return }
        let range = byteRangeForTimeline(
            timelineStartSeconds: timelineStartSeconds,
            timelineEndSeconds: timelineEndSeconds,
            durationSeconds: durationSeconds
        )
        var lastLoggedPercent = -Self.progressStepPercent
        var lastStallLog = CFAbsoluteTimeGetCurrent()

        lock.lock()
        beginTrackingExportWindow(range)
        lock.unlock()

        while true {
            if isCancelled() { throw SegmentExporterError.cancelled }
            if isRangeFilled(range) {
                let endMin = Int(timelineEndSeconds) / 60
                let endSec = Int(timelineEndSeconds) % 60
                log(
                    "Download ready for \(endMin):\(String(format: "%02d", endSec)) — contiguous \(formatBytes(exportWindowStart))–\(formatBytes(exportWindowContiguousEnd)) on disk\(speedLogSuffix())"
                )
                return
            }

            let now = CFAbsoluteTimeGetCurrent()
            let span = filledSpanLocked()
            let filledInWindow = max(0, min(span.end, range.end) - max(span.start, range.start))
            let needLen = range.length
            let pct = needLen > 0 ? Int(filledInWindow * 100 / needLen) : 0
            if pct >= lastLoggedPercent + Self.progressStepPercent || now - lastStallLog >= 20 {
                lastStallLog = now
                lastLoggedPercent = (pct / Self.progressStepPercent) * Self.progressStepPercent
                let endMin = Int(timelineEndSeconds) / 60
                let endSec = Int(timelineEndSeconds) % 60
                log(
                    "Download window \(pct)% — \(formatBytes(filledInWindow)) / \(formatBytes(needLen)) for \(endMin):\(String(format: "%02d", endSec)) (file \(formatBytes(range.start))–\(formatBytes(range.end)))\(speedLogSuffix())"
                )
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func waitUntilComplete() async throws {
        while true {
            if isCancelled() { throw SegmentExporterError.cancelled }
            lock.lock()
            let atEOF = regionFilledEnd >= totalLength
            lock.unlock()
            if atEOF {
                log("Temp copy complete — \(formatBytes(totalLength))\(averageSpeedLogSuffix())")
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: - Private

    private func filledSpanLocked() -> TimelineByteRange {
        TimelineByteRange(start: regionStart, end: regionFilledEnd)
    }

    private func applyInitialPosition(seekSeconds: Double, durationSeconds: Double) {
        let firstWindowEnd = min(seekSeconds + 60, durationSeconds)
        let range = byteRangeForTimeline(
            timelineStartSeconds: seekSeconds,
            timelineEndSeconds: firstWindowEnd,
            durationSeconds: durationSeconds
        )
        lock.lock()
        if seekSeconds <= 0.5 {
            let tailStart = max(0, totalLength - Self.indexTailFetchBytes(totalLength: totalLength))
            let hadFalseSpan = regionStart >= tailStart || regionFilledEnd > range.end
            regionStart = 0
            if hadFalseSpan {
                regionFilledEnd = headOnDisk ? Int64(512 * 1024) : 0
            }
            downloadCursor = regionFilledEnd
            lock.unlock()
            log("Download from file start — need ~\(formatBytes(range.end)) for first minute")
        } else {
            regionStart = min(regionStart, range.start)
            if headOnDisk {
                regionStart = 0
            }
            exportWindowStart = range.start
            exportWindowContiguousEnd = range.start
            downloadCursor = range.start
            lock.unlock()
            let seekMin = Int(seekSeconds) / 60
            let seekSec = Int(seekSeconds) % 60
            log(
                "Seek \(seekMin):\(String(format: "%02d", seekSec)) — download from ~\(formatBytes(range.start)) (skipping earlier bytes, like ffmpeg -ss)"
            )
            log("First segment needs ~\(formatBytes(range.length)) at \(formatBytes(range.start))–\(formatBytes(range.end))")
        }
        publishLANPlaybackState(mediaCursorSeconds: seekSeconds)
    }

    private func recordFilledRange(offset: Int64, end: Int64) {
        guard end > offset else { return }
        filledRanges.append(offset ... (end - 1))
        filledRanges = Self.mergeFilledRanges(filledRanges)
        scheduleManifestSave()
    }

    private static func mergeFilledRanges(_ ranges: [ClosedRange<Int64>]) -> [ClosedRange<Int64>] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var out: [ClosedRange<Int64>] = []
        var current = sorted[0]
        for span in sorted.dropFirst() {
            if span.lowerBound <= current.upperBound + 1 {
                current = current.lowerBound ... max(current.upperBound, span.upperBound)
            } else {
                out.append(current)
                current = span
            }
        }
        out.append(current)
        return out
    }

    private static func rangeFullyCovered(offset: Int64, length: Int, spans: [ClosedRange<Int64>]) -> Bool {
        guard length > 0 else { return true }
        var cursor = offset
        let end = offset + Int64(length)
        for span in spans {
            if span.upperBound < cursor { continue }
            if span.lowerBound > cursor { return false }
            cursor = min(end, span.upperBound + 1)
            if cursor >= end { return true }
        }
        return false
    }

    private static func keyframePrerollBytes(timelineStartSeconds: Double, totalLength: Int64) -> Int64 {
        guard timelineStartSeconds > 0.5 else { return 0 }
        let fromDuration = Int64(min(48 * 1024 * 1024, (timelineStartSeconds / 120.0) * Double(totalLength)))
        let fromSize = min(32 * 1024 * 1024, totalLength / 40)
        return max(fromDuration, fromSize)
    }

    private func applyCachedSpans(_ cache: WebDAVRangeCache, skipRangesAlreadyOnDisk: Bool) throws {
        let tailThreshold = max(0, totalLength - 3 * 1024 * 1024)
        lock.lock()
        let existingSpans = filledRanges
        lock.unlock()
        for span in cache.storedSpans() {
            if skipRangesAlreadyOnDisk,
               Self.rangeFullyCovered(offset: span.start, length: span.data.count, spans: existingSpans) {
                continue
            }
            try write(span.data, at: span.start)
            if span.start == 0 {
                lock.lock()
                headOnDisk = true
                lock.unlock()
            }
            if span.start >= tailThreshold {
                lock.lock()
                tailOnDisk = true
                lock.unlock()
            }
        }
        try writeHandle?.synchronize()
        scheduleManifestSave()
    }

    private func restoreDownloadRegionFromFilledSpansLocked() {
        guard let first = filledRanges.min(by: { $0.lowerBound < $1.lowerBound }) else {
            regionStart = 0
            regionFilledEnd = 0
            downloadCursor = 0
            return
        }
        regionStart = first.lowerBound
        regionFilledEnd = first.lowerBound
        for span in filledRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if span.lowerBound <= regionFilledEnd + 1 {
                regionFilledEnd = max(regionFilledEnd, span.upperBound + 1)
            }
        }
        downloadCursor = regionFilledEnd
    }

    private func scheduleManifestSave() {
        manifestSaveTask?.cancel()
        manifestSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled, let self else { return }
            self.persistManifestNow()
        }
    }

    private func persistManifestNow() {
        lock.lock()
        let spans = filledRanges
        let head = headOnDisk
        let tail = tailOnDisk
        let key = sourceFileKey
        let href = sourceHref
        let length = totalLength
        lock.unlock()
        let playback = ExportPlaybackState.shared.frozenStatusPayload
        let playbackStart = (playback["playbackStartSeconds"] as? Double) ?? 0
        let duration = (playback["durationSeconds"] as? Double) ?? 0
        let cursor = (playback["exportCursorSeconds"] as? Double) ?? 0
        WorkingSourceSparseCatalog.save(
            fileKey: key,
            totalLength: length,
            href: href,
            filledRanges: spans,
            headOnDisk: head,
            tailOnDisk: tail,
            playbackStartSeconds: playbackStart > 0 ? playbackStart : nil,
            durationSeconds: duration > 0 ? duration : nil,
            exportCursorSeconds: cursor > 0 ? cursor : nil
        )
    }

    private func noteWrite(offset: Int64, length: Int) {
        let end = offset + Int64(length)
        if length <= 0 { return }
        recordFilledRange(offset: offset, end: end)
        let tailStart = max(0, totalLength - Self.indexTailFetchBytes(totalLength: totalLength))
        if offset >= tailStart {
            markIndexTailIfComplete(writeEnd: end)
            return
        }
        if regionFilledEnd == 0, regionStart == 0, offset == 0 {
            regionStart = 0
            regionFilledEnd = end
        } else if offset == regionFilledEnd {
            regionFilledEnd = end
        } else if end <= regionStart {
            regionStart = offset
            regionFilledEnd = max(regionFilledEnd, end)
        } else if offset >= regionStart, offset <= regionFilledEnd {
            if end > regionFilledEnd { regionFilledEnd = end }
        } else if offset > regionFilledEnd {
            regionStart = offset
            regionFilledEnd = end
        } else if offset < regionStart, end >= regionStart {
            regionStart = offset
            if end > regionFilledEnd { regionFilledEnd = end }
        }
        extendExportWindowContiguous(offset: offset, end: end)
        markIndexTailIfComplete(writeEnd: end)
    }

    private func extendExportWindowContiguous(offset: Int64, end: Int64) {
        if offset == exportWindowContiguousEnd {
            exportWindowContiguousEnd = max(exportWindowContiguousEnd, end)
            return
        }
        if offset >= exportWindowStart, offset <= exportWindowContiguousEnd {
            exportWindowContiguousEnd = max(exportWindowContiguousEnd, end)
            return
        }
        if offset >= exportWindowStart, exportWindowContiguousEnd <= exportWindowStart, offset == exportWindowStart {
            exportWindowContiguousEnd = end
        }
    }

    private func markIndexTailIfComplete(writeEnd: Int64) {
        let tailStart = max(0, totalLength - Self.indexTailFetchBytes(totalLength: totalLength))
        if writeEnd >= totalLength || (regionStart <= tailStart && regionFilledEnd >= totalLength) {
            tailOnDisk = true
        }
    }

    private func markHeadIfComplete(writeEnd: Int64) {
        if writeEnd >= min(totalLength, Int64(64 * 1024)) {
            headOnDisk = true
        }
    }

    private func write(_ data: Data, at offset: Int64) throws {
        guard let writeHandle else { return }
        try writeHandle.seek(toOffset: UInt64(offset))
        try writeHandle.write(contentsOf: data)
        lock.lock()
        noteWrite(offset: offset, length: data.count)
        markHeadIfComplete(writeEnd: offset + Int64(data.count))
        lock.unlock()
    }

    private func startBackgroundDownload() {
        downloadTask?.cancel()
        downloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try await self.runDownloadLoop()
            } catch is CancellationError {
                self.lock.lock()
                let paused = self.backgroundPausedForStream
                self.lock.unlock()
                if paused {
                    self.log("Background download paused — filling this segment’s window on temp")
                }
            } catch {
                if !self.isCancelled() {
                    self.log("Download stopped: \(error.localizedDescription) — export may continue via pCloud stream if enabled")
                }
            }
        }
    }

    private func runDownloadLoop() async throws {
        var lastLoggedPercent = -Self.progressStepPercent
        while true {
            if isCancelled() || Task.isCancelled { throw CancellationError() }

            lock.lock()
            var start = downloadCursor
            if start >= totalLength {
                lock.unlock()
                return
            }
            lock.unlock()

            lock.lock()
            let highWater = downloadHighWaterMark
            lock.unlock()
            let stopAt = (highWater > 0) ? min(highWater, totalLength) : totalLength
            if start >= stopAt {
                try await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            let end = min(start + Self.downloadChunkBytes - 1, stopAt - 1, totalLength - 1)
            let length = Int(end - start + 1)
            let auth = authorizationProvider()
            let data = try await Self.fetchRange(
                remoteURL: remoteURL,
                authorization: auth,
                offset: start,
                endInclusive: end
            )
            guard data.count == length else {
                throw WebDAVResourceLoaderError.invalidResponse
            }
            throughput.recordNetworkBytes(data.count)
            try write(data, at: start)

            lock.lock()
            downloadCursor = regionFilledEnd
            let cursor = downloadCursor
            lock.unlock()

            let pct = totalLength > 0 ? Int(cursor * 100 / totalLength) : 0
            if pct >= lastLoggedPercent + Self.progressStepPercent || cursor >= totalLength {
                lastLoggedPercent = (pct / Self.progressStepPercent) * Self.progressStepPercent
                log("Download \(pct)% — \(formatBytes(cursor)) / \(formatBytes(totalLength))\(speedLogSuffix())")
            }
            await Task.yield()
        }
    }

    /// Use reported duration from the MP4 index when bitrate is plausible; only inflate when metadata duration is impossibly short for file size.
    static func effectiveDurationSeconds(reported: Double, totalBytes: Int64) -> Double {
        guard reported > 0, totalBytes > 0 else { return reported }
        let impliedMbps = (Double(totalBytes) * 8.0) / (reported * 1_000_000.0)
        if impliedMbps <= 80 {
            return reported
        }
        let floorMbps = 2.0
        let minFromSize = Double(totalBytes) * 8.0 / (floorMbps * 1_000_000.0)
        return max(reported, minFromSize)
    }

    func exportWindowFilledBytes(for range: TimelineByteRange) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard exportWindowStart == range.start else { return 0 }
        return max(0, exportWindowContiguousEnd - range.start)
    }

    private static func ensureFreeDiskSpace(forBytes needed: Int64) throws {
        let path = ExportPaths.exportsDirectory.path
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let freeNumber = attrs[.systemFreeSize] as? NSNumber else {
            return
        }
        let free = freeNumber.int64Value
        let margin: Int64 = 128 * 1024 * 1024
        let reserveCap: Int64 = 900 * 1024 * 1024
        let reserve = min(needed, reserveCap) + margin
        if free < reserve {
            throw SegmentExporterError.insufficientDiskSpace(needed: reserve, available: max(0, free))
        }
    }

    private static func fetchRange(
        remoteURL: URL,
        authorization: String,
        offset: Int64,
        endInclusive: Int64
    ) async throws -> Data {
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("bytes=\(offset)-\(endInclusive)", forHTTPHeaderField: "Range")

        let (data, response) = try await WebDAVMediaSession.data(for: request, log: nil)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVResourceLoaderError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) || http.statusCode == 206 else {
            throw WebDAVResourceLoaderError.httpStatus(http.statusCode)
        }
        return data
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
        }
        if bytes >= 1024 * 1024 {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
        }
        return "\(bytes) B"
    }

    private func speedLogSuffix() -> String {
        guard let mbps = throughput.intervalMbps() else { return "" }
        return String(format: " @ %.1f Mbps", mbps)
    }

    private func averageSpeedLogSuffix() -> String {
        guard let mbps = throughput.averageMbps() else { return "" }
        return String(format: " — avg %.1f Mbps", mbps)
    }
}

/// Network throughput for pCloud range downloads (megabits per second).
private final class DownloadThroughput: @unchecked Sendable {
    private let lock = NSLock()
    private var totalBytes: Int64 = 0
    private var startedAt = CFAbsoluteTimeGetCurrent()
    private var lastSampleBytes: Int64 = 0
    private var lastSampleAt = CFAbsoluteTimeGetCurrent()

    func reset() {
        lock.lock()
        totalBytes = 0
        startedAt = CFAbsoluteTimeGetCurrent()
        lastSampleBytes = 0
        lastSampleAt = startedAt
        lock.unlock()
    }

    func recordNetworkBytes(_ bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        totalBytes += Int64(bytes)
        lock.unlock()
    }

    /// Mbps since the previous progress log sample.
    func intervalMbps() -> Double? {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastSampleAt
        let deltaBytes = totalBytes - lastSampleBytes
        lastSampleAt = now
        lastSampleBytes = totalBytes
        lock.unlock()
        guard elapsed >= 0.25, deltaBytes > 0 else { return nil }
        return Self.mbps(bytes: deltaBytes, seconds: elapsed)
    }

    func averageMbps() -> Double? {
        lock.lock()
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        let bytes = totalBytes
        lock.unlock()
        guard elapsed >= 0.5, bytes > 0 else { return nil }
        return Self.mbps(bytes: bytes, seconds: elapsed)
    }

    private static func mbps(bytes: Int64, seconds: Double) -> Double {
        (Double(bytes) * 8.0) / (seconds * 1_000_000.0)
    }
}
