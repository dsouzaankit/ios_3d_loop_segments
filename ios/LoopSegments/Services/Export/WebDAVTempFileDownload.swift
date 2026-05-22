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
    /// Concurrent range fetches inside the background prefetch loop (single Task; saturates cellular).
    private static let backgroundPrefetchParallelism = 4
    /// LAN preload-only (no segment export): more parallel chunks, no foreground pause contention.
    private static let lanPreloadOnlyParallelism = 8
    /// Retry backoff (seconds) after a transient background error before reopening the loop.
    private static let backgroundRetryDelaysSeconds: [UInt64] = [1, 2, 5, 10, 20]
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
    /// Fills `[0, seek)` from pCloud while segment export is idle (high bitrate); low bitrate fills in preload.
    private var prefixDownloadTask: Task<Void, Error>?
    private var writeHandle: FileHandle?
    private var downloadCursor: Int64 = 0
    /// When set, background download stops at this byte (avoids pulling the rest of a multi‑GB file).
    private var downloadHighWaterMark: Int64 = 0
    private var backgroundPausedForStream = false
    /// Nested `pauseBackgroundDownloadForForegroundFill` calls (segment + dense fill).
    private var foregroundFillPauseDepth = 0
    /// Background was running before the outermost foreground pause.
    private var backgroundWasRunningBeforeForegroundFill = false
    /// Contiguous bytes downloaded from the active export window start (no holes — `regionFilledEnd` can lie).
    private var exportWindowStart: Int64 = 0
    private var exportWindowContiguousEnd: Int64 = 0
    /// Disjoint byte spans actually written (head, dense window, EOF index may be separate).
    private var filledRanges: [ClosedRange<Int64>] = []
    /// Playback start (seconds) for the current export — anchor for contiguous frontier computation.
    /// Avoid reading `ExportPlaybackState.shared.playbackStartSeconds` (stale across runs).
    private var playbackStartSecondsForAnchor: Double = 0
    /// Duration (seconds) for the current export — used to map anchor seconds to file byte.
    private var anchorDurationSeconds: Double = 0
    /// Below-bitrate LAN preload: segment export off; background uses higher parallelism only.
    private var lanPreloadExclusive = false
    private let throughput = DownloadThroughput()
    private let sourceFileKey: String
    private let sourceHref: String?
    private let containerFormat: MediaContainerFormat
    private var manifestSaveTask: Task<Void, Never>?

    init(
        fileKey: String,
        sourceHref: String?,
        remoteURL: URL,
        rangeCache: WebDAVRangeCache,
        containerFormat: MediaContainerFormat,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        isCancelled: @escaping () -> Bool,
        log: @escaping (String) -> Void
    ) throws {
        self.containerFormat = containerFormat
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

    /// LAN bridge / playable-till anchor (call before preload `ensureContiguousRange` when seek &gt; 0).
    func setPlaybackAnchor(seekSeconds: Double, durationSeconds: Double) {
        lock.lock()
        playbackStartSecondsForAnchor = max(0, seekSeconds)
        anchorDurationSeconds = max(0, durationSeconds)
        lock.unlock()
    }

    /// Position download at seek (or 0) and start sequential LAN prefetch when enabled.
    func beginExport(
        seekSeconds: Double,
        durationSeconds: Double,
        sequentialLANPrefetch: Bool = true,
        lanPreloadExclusive: Bool = false
    ) {
        throughput.reset()
        lock.lock()
        playbackStartSecondsForAnchor = max(0, seekSeconds)
        anchorDurationSeconds = max(0, durationSeconds)
        self.lanPreloadExclusive = lanPreloadExclusive
        lock.unlock()
        applyInitialPosition(seekSeconds: seekSeconds, durationSeconds: durationSeconds)
        if sequentialLANPrefetch {
            if !lanPreloadExclusive, seekSeconds > 0.5 {
                startPrefixFillBeforeSeekIfNeeded()
            }
            startBackgroundDownload()
        } else {
            log("LAN off — each minute dense-filled on demand only (no sequential prefetch).")
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
        if containerFormat.needsMP4IndexAtEOF, !hasTail {
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
        guard containerFormat.needsMP4IndexAtEOF else {
            lock.lock()
            if headOnDisk { tailOnDisk = true }
            lock.unlock()
            return
        }
        try ensureWriteHandleForDownload()
        lock.lock()
        let covered = indexTailCoveredOnDiskLocked()
        if covered {
            if !tailOnDisk { tailOnDisk = true }
            lock.unlock()
            if force {
                log("MP4 index already at EOF on _working.mp4 — skip pCloud re-fetch")
            }
            return
        }
        lock.unlock()

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
        prefixDownloadTask?.cancel()
        try? writeHandle?.close()
    }

    /// Stop background range fetches but keep the sparse temp file (e.g. before pCloud stream export).
    func pauseBackgroundDownload() {
        lock.lock()
        backgroundPausedForStream = true
        foregroundFillPauseDepth = 0
        backgroundWasRunningBeforeForegroundFill = false
        lock.unlock()
        downloadTask?.cancel()
        downloadTask = nil
        prefixDownloadTask?.cancel()
        prefixDownloadTask = nil
    }

    /// Pause LAN background prefetch while a minute window is dense-filled from pCloud (avoids duplicate bytes).
    func pauseBackgroundDownloadForForegroundFill() {
        lock.lock()
        if foregroundFillPauseDepth == 0 {
            backgroundWasRunningBeforeForegroundFill = downloadTask != nil && !backgroundPausedForStream
        }
        foregroundFillPauseDepth += 1
        lock.unlock()
        downloadTask?.cancel()
        downloadTask = nil
        prefixDownloadTask?.cancel()
        prefixDownloadTask = nil
    }

    func resumeBackgroundDownloadAfterForegroundFill() {
        lock.lock()
        guard foregroundFillPauseDepth > 0 else {
            lock.unlock()
            return
        }
        foregroundFillPauseDepth -= 1
        let resume = foregroundFillPauseDepth == 0 && backgroundWasRunningBeforeForegroundFill
        if foregroundFillPauseDepth == 0 {
            backgroundWasRunningBeforeForegroundFill = false
        }
        lock.unlock()
        guard resume else { return }
        lock.lock()
        restoreDownloadRegionFromFilledSpansLocked()
        lock.unlock()
        startPrefixFillBeforeSeekIfNeeded()
        startBackgroundDownload()
    }

    func isBackgroundDownloadActive() -> Bool {
        lock.lock()
        let active = downloadTask != nil && !backgroundPausedForStream
        lock.unlock()
        return active
    }

    /// Contiguous fill from playback start through the prefetch horizon, as % of that span.
    func backgroundPrefetchPercent() -> Int {
        lock.lock()
        let spans = filledRanges
        let total = totalLength
        let horizon = downloadHighWaterMark > 0 ? downloadHighWaterMark : totalLength
        lock.unlock()
        guard total > 0 else { return 0 }
        let anchor = playbackAnchorByteLocked(total: total)
        let frontier = Self.contiguousDenseEndFromByte(anchor, spans: spans)
        let horizonByte = min(total, max(anchor, horizon))
        let filled = max(0, frontier - anchor)
        let range = max(1, horizonByte - anchor)
        return Int(min(100, filled * 100 / range))
    }

    /// Timeline position of the contiguous dense frontier from playback start.
    func backgroundTimelineSeconds(durationSeconds: Double) -> Double {
        lock.lock()
        let spans = filledRanges
        let total = totalLength
        lock.unlock()
        guard total > 0, durationSeconds > 0 else { return 0 }
        let anchor = playbackAnchorByteLocked(total: total)
        let frontier = Self.contiguousDenseEndFromByte(anchor, spans: spans)
        return Self.timelineSecondsForByteOffset(frontier, totalLength: total, durationSeconds: durationSeconds)
    }

    private func playbackAnchorByteLocked(total: Int64) -> Int64 {
        let startSec = playbackStartSecondsForAnchor
        guard startSec > 0.5 else { return 0 }
        let duration = anchorDurationSeconds > 0
            ? anchorDurationSeconds
            : Self.effectiveDurationSeconds(reported: 1, totalBytes: total)
        return Self.lanPlaybackDenseAnchorByte(
            playbackStartSeconds: startSec,
            totalLength: total,
            durationSeconds: duration
        )
    }

    /// Byte span `[0, seek preroll anchor)` — real media from pCloud for scrub/`#t=` before export seek.
    func lanPrefixBeforeSeekRange(seekSeconds: Double, durationSeconds: Double) -> TimelineByteRange? {
        guard seekSeconds > 0.5, totalLength > 0, durationSeconds > 0 else { return nil }
        let end = Self.lanPlaybackDenseAnchorByte(
            playbackStartSeconds: seekSeconds,
            totalLength: totalLength,
            durationSeconds: durationSeconds
        )
        guard end > 0 else { return nil }
        return TimelineByteRange(start: 0, end: end)
    }

    func isLANPrefixBeforeSeekOnDisk(seekSeconds: Double, durationSeconds: Double) -> Bool {
        guard let range = lanPrefixBeforeSeekRange(
            seekSeconds: seekSeconds,
            durationSeconds: durationSeconds
        ) else { return true }
        return isByteRangeFullyOnDisk(range)
    }

    /// Dense-fill 0:00 → seek (incl. preroll anchor) from pCloud. Low bitrate: call at preload start; high bitrate: background when idle.
    func ensureLANPrefixBeforeSeekFilled(seekSeconds: Double, durationSeconds: Double) async throws {
        guard let range = lanPrefixBeforeSeekRange(
            seekSeconds: seekSeconds,
            durationSeconds: durationSeconds
        ) else { return }
        guard !isByteRangeFullyOnDisk(range) else { return }
        log(
            "LAN prefix — dense fill \(formatBytes(range.start))–\(formatBytes(range.end)) " +
                "(0:00 → \(ExportTimelineLog.wallClock(seconds: seekSeconds)) from pCloud)…"
        )
        try await ensureContiguousRange(range, bridgeLANGapBeforeWindow: true)
        publishLANPlaybackState()
    }

    /// Fill ~45s preroll before wall-clock seek so `#t=` / browser decode has keyframe bytes on disk.
    func ensureLANPlaybackPrerollGapFilled(seekSeconds: Double, durationSeconds: Double) async throws {
        guard seekSeconds > 0.5 else { return }
        guard let gap = Self.lanPlaybackPrerollGapRange(
            playbackStartSeconds: seekSeconds,
            totalLength: totalLength,
            durationSeconds: durationSeconds
        ), gap.length > 0 else { return }
        if isRangeFilled(gap) { return }
        log(
            "LAN playback preroll — dense fill \(formatBytes(gap.start))–\(formatBytes(gap.end)) " +
                "(~\(Int(Self.timelineStartPrerollSeconds))s before \(ExportTimelineLog.wallClock(seconds: seekSeconds)) for decode)…"
        )
        try await ensureContiguousRange(gap)
    }

    private func contiguousDenseEndForLANPlaybackLocked(spans: [ClosedRange<Int64>], total: Int64) -> Int64 {
        let anchor = playbackAnchorByteLocked(total: total)
        return Self.contiguousDenseEndFromByte(anchor, spans: spans)
    }

    /// Furthest byte reachable from `startByte` without crossing a gap in `filledRanges`.
    private static func contiguousDenseEndFromByte(_ startByte: Int64, spans: [ClosedRange<Int64>]) -> Int64 {
        var frontier = startByte
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if span.upperBound < frontier { continue }
            if span.lowerBound > frontier { break }
            frontier = max(frontier, span.upperBound + 1)
        }
        return frontier
    }

    /// Sum of dense `filledRanges` as % of file size.
    func denseBytesOnDiskPercent() -> Int {
        lock.lock()
        let spans = filledRanges
        let total = totalLength
        lock.unlock()
        guard total > 0 else { return 0 }
        var sum: Int64 = 0
        for span in spans {
            sum += span.upperBound - span.lowerBound + 1
        }
        return Int(min(100, sum * 100 / total))
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
        if !containerFormat.needsMP4IndexAtEOF {
            lock.lock()
            defer { lock.unlock() }
            return headOnDisk
        }
        lock.lock()
        defer { lock.unlock() }
        return indexTailCoveredOnDiskLocked()
    }

    private func indexTailCoveredOnDiskLocked() -> Bool {
        if tailOnDisk { return true }
        let tailLen = Self.indexTailFetchBytes(totalLength: totalLength)
        let tailStart = max(0, totalLength - tailLen)
        let byteLen = totalLength - tailStart
        guard byteLen > 0 else { return false }
        return Self.rangeFullyCovered(
            offset: tailStart,
            length: Int(byteLen),
            spans: filledRanges
        )
    }

    func hasHeadOnDisk() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return headOnDisk
    }

    func logDownloadStarted() {
        log("Sparse temp — \(formatBytes(totalLength)) on disk (one dense window per 60s segment)…")
    }

    /// Limit sequential prefetch to `[playbackStart, horizonByte)` (index tail fetched separately).
    func setDownloadHighWaterMark(_ highWaterMark: Int64) {
        lock.lock()
        downloadHighWaterMark = min(max(0, highWaterMark), totalLength)
        lock.unlock()
    }

    /// Advance the sequential prefetch horizon as export progresses (EOF or exported+2 min).
    func updateLANSequentialPrefetchHorizon(
        playbackStartSeconds: Double,
        horizonTimelineSeconds: Double,
        durationSeconds: Double
    ) {
        let horizonSeconds = min(max(playbackStartSeconds, horizonTimelineSeconds), durationSeconds)
        let range = byteRangeForTimeline(
            timelineStartSeconds: playbackStartSeconds,
            timelineEndSeconds: horizonSeconds,
            durationSeconds: durationSeconds
        )
        setDownloadHighWaterMark(range.end)
    }

    /// Map a file byte offset to timeline seconds (for LAN / export logs).
    static func timelineSecondsForByteOffset(
        _ byteOffset: Int64,
        totalLength: Int64,
        durationSeconds: Double
    ) -> Double {
        guard totalLength > 0, durationSeconds > 0 else { return 0 }
        let effective = effectiveDurationSeconds(reported: durationSeconds, totalBytes: totalLength)
        let ratio = min(1, max(0, Double(max(0, byteOffset)) / Double(totalLength)))
        return min(effective, ratio * effective)
    }

    static func timelineByteOffsetForSeconds(
        _ seconds: Double,
        totalLength: Int64,
        durationSeconds: Double
    ) -> Int64 {
        guard totalLength > 0, durationSeconds > 0 else { return 0 }
        let effective = effectiveDurationSeconds(reported: durationSeconds, totalBytes: totalLength)
        let ratio = min(1, max(0, seconds / effective))
        return min(totalLength, Int64(ratio * Double(totalLength)))
    }

    /// First byte that must be dense for decode at `playbackStartSeconds` (includes ~45s preroll + keyframe slack).
    static func lanPlaybackDenseAnchorByte(
        playbackStartSeconds: Double,
        totalLength: Int64,
        durationSeconds: Double
    ) -> Int64 {
        guard playbackStartSeconds > 0.5, totalLength > 0, durationSeconds > 0 else { return 0 }
        let endSec = min(durationSeconds, playbackStartSeconds + 1)
        return byteRangeForTimeline(
            totalLength: totalLength,
            timelineStartSeconds: playbackStartSeconds,
            timelineEndSeconds: endSec,
            durationSeconds: durationSeconds
        ).start
    }

    /// Sparse bytes between preroll anchor and naive timeline offset (legacy fills that skipped preroll).
    static func lanPlaybackPrerollGapRange(
        playbackStartSeconds: Double,
        totalLength: Int64,
        durationSeconds: Double
    ) -> TimelineByteRange? {
        guard playbackStartSeconds > 0.5, totalLength > 0, durationSeconds > 0 else { return nil }
        let denseStart = lanPlaybackDenseAnchorByte(
            playbackStartSeconds: playbackStartSeconds,
            totalLength: totalLength,
            durationSeconds: durationSeconds
        )
        let timelineOnly = timelineByteOffsetForSeconds(
            playbackStartSeconds,
            totalLength: totalLength,
            durationSeconds: durationSeconds
        )
        guard denseStart < timelineOnly else { return nil }
        return TimelineByteRange(start: denseStart, end: timelineOnly)
    }

    func maxBrowserPlayableStatusLog(
        playbackStartSeconds: Double,
        durationSeconds: Double,
        exportCursorSeconds: Double
    ) -> String {
        publishLANPlaybackState(mediaCursorSeconds: exportCursorSeconds)
        return ExportPlaybackState.shared.lanPlayableStatusLine(
            playbackStartSeconds: playbackStartSeconds,
            exportCursorSeconds: exportCursorSeconds,
            durationSeconds: durationSeconds
        )
    }

    private func downloadDenseRangeFromCloud(
        rangeStart: Int64,
        rangeEnd: Int64,
        needLen: Int64,
        force: Bool,
        skippedOnDisk: inout Int64,
        fetchedFromCloud: inout Int64,
        lastLoggedPercent: inout Int,
        lastProgressLog: inout CFAbsoluteTime
    ) async throws {
        var offset = rangeStart
        let auth = authorizationProvider()
        while offset < rangeEnd {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            let end = min(offset + Self.downloadChunkBytes - 1, rangeEnd - 1)
            let chunkLen = Int(end - offset + 1)
            lock.lock()
            let spans = filledRanges
            lock.unlock()
            if !force,
               Self.rangeFullyCovered(offset: offset, length: chunkLen, spans: spans) {
                skippedOnDisk += Int64(chunkLen)
                offset = end + 1
                logDenseFillProgressIfNeeded(
                    done: offset - rangeStart,
                    needLen: needLen,
                    onDisk: true,
                    lastLoggedPercent: &lastLoggedPercent,
                    lastProgressLog: &lastProgressLog
                )
                continue
            }
            let data = try await Self.fetchRange(
                remoteURL: remoteURL,
                authorization: auth,
                offset: offset,
                endInclusive: end
            )
            guard data.count == chunkLen else {
                throw WebDAVResourceLoaderError.invalidResponse
            }
            throughput.recordNetworkBytes(data.count)
            try write(data, at: offset)
            fetchedFromCloud += Int64(data.count)
            offset = end + 1
            logDenseFillProgressIfNeeded(
                done: offset - rangeStart,
                needLen: needLen,
                onDisk: false,
                lastLoggedPercent: &lastLoggedPercent,
                lastProgressLog: &lastProgressLog
            )
        }
    }

    private func logDenseFillProgressIfNeeded(
        done: Int64,
        needLen: Int64,
        onDisk: Bool,
        lastLoggedPercent: inout Int,
        lastProgressLog: inout CFAbsoluteTime
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let pct = needLen > 0 ? Int(done * 100 / needLen) : 100
        guard pct >= lastLoggedPercent + Self.progressStepPercent || now - lastProgressLog >= 20 else { return }
        lastProgressLog = now
        lastLoggedPercent = (pct / Self.progressStepPercent) * Self.progressStepPercent
        let suffix = onDisk ? " (dense, on disk)" : " (dense)"
        log(
            "Downloading window \(pct)% — \(formatBytes(done)) / \(formatBytes(needLen))\(suffix)\(speedLogSuffix())"
        )
    }

    /// Fill every byte in `range` from pCloud (dense on disk) so AVFoundation can open the sparse temp.
    /// When `bridgeLANGapBeforeWindow` is true, also fills `[contiguous frontier, range.start)` so LAN playback grows from playback start.
    func ensureContiguousRange(
        _ range: TimelineByteRange,
        force: Bool = false,
        bridgeLANGapBeforeWindow: Bool = false
    ) async throws {
        guard range.length > 0 else { return }
        try ensureWriteHandleForDownload()
        let tailStart = max(0, totalLength - Self.indexTailFetchBytes(totalLength: totalLength))
        let rangeEnd = min(range.end, totalLength)

        var fillSpans: [(start: Int64, end: Int64)] = []
        if bridgeLANGapBeforeWindow {
            lock.lock()
            let spans = filledRanges
            let anchor = playbackAnchorByteLocked(total: totalLength)
            let frontier = Self.contiguousDenseEndFromByte(anchor, spans: spans)
            lock.unlock()
            if frontier < range.start {
                fillSpans.append((frontier, range.start))
            }
        }
        fillSpans.append((range.start, rangeEnd))

        lock.lock()
        let spansSnapshot = filledRanges
        lock.unlock()
        let allOnDisk = !force && fillSpans.allSatisfy { span in
            let len = span.end - span.start
            guard len > 0 else { return true }
            return Self.rangeFullyCovered(offset: span.start, length: Int(len), spans: spansSnapshot)
        }
        if allOnDisk {
            lock.lock()
            exportWindowStart = range.start
            exportWindowContiguousEnd = max(exportWindowContiguousEnd, rangeEnd)
            lock.unlock()
            log(
                "Window \(formatBytes(range.start))–\(formatBytes(rangeEnd)) already dense on _working.mp4 — skip pCloud re-download"
            )
            logContiguousWindowOnDisk(playbackAnchorOnly: bridgeLANGapBeforeWindow)
            publishLANPlaybackState()
            return
        }

        pauseBackgroundDownloadForForegroundFill()
        defer { resumeBackgroundDownloadAfterForegroundFill() }

        var skippedOnDisk: Int64 = 0
        var fetchedFromCloud: Int64 = 0
        var lastLoggedPercent = -Self.progressStepPercent
        var lastProgressLog = CFAbsoluteTimeGetCurrent()
        for (index, span) in fillSpans.enumerated() {
            let spanLen = span.end - span.start
            guard spanLen > 0 else { continue }
            if index == 0, span.start < range.start {
                log(
                    "LAN bridge — dense fill \(formatBytes(span.start))–\(formatBytes(span.end)) " +
                        "(\(formatBytes(spanLen)) gap before minute window)…"
                )
            } else {
                log(
                    "pCloud dense fill — window \(formatBytes(span.start))–\(formatBytes(span.end)) " +
                        "(\(formatBytes(spanLen)); LAN scrubber may show full duration before this span is local)…"
                )
            }
            try await downloadDenseRangeFromCloud(
                rangeStart: span.start,
                rangeEnd: span.end,
                needLen: spanLen,
                force: force,
                skippedOnDisk: &skippedOnDisk,
                fetchedFromCloud: &fetchedFromCloud,
                lastLoggedPercent: &lastLoggedPercent,
                lastProgressLog: &lastProgressLog
            )
        }
        if skippedOnDisk > 0 {
            log(
                "Dense fill — reused \(formatBytes(skippedOnDisk)) already on _working.mp4, fetched \(formatBytes(fetchedFromCloud)) from pCloud"
            )
        }
        if tailStart < totalLength, !hasIndexTailOnDisk() {
            try await ensureIndexTailOnDisk()
        }
        try writeHandle?.synchronize()
        lock.lock()
        exportWindowStart = range.start
        exportWindowContiguousEnd = max(exportWindowContiguousEnd, rangeEnd)
        lock.unlock()
        logContiguousWindowOnDisk(playbackAnchorOnly: bridgeLANGapBeforeWindow)
        persistManifestNow()
        publishLANPlaybackState()
    }

    private func logContiguousWindowOnDisk(playbackAnchorOnly: Bool) {
        lock.lock()
        let spans = filledRanges
        let anchor = playbackAnchorByteLocked(total: totalLength)
        let contiguousEnd = Self.contiguousDenseEndFromByte(anchor, spans: spans)
        let startLabel = playbackAnchorOnly ? anchor : exportWindowStart
        lock.unlock()
        log(
            "Window on disk — contiguous \(formatBytes(startLabel))–\(formatBytes(contiguousEnd))\(averageSpeedLogSuffix())"
        )
    }

    /// Updates LAN range gating + playback start hint for `_working.mp4`.
    func publishLANPlaybackState(mediaCursorSeconds: Double? = nil) {
        let spans = filledSpansOnDisk()
        let head = hasHeadOnDisk()
        let tail = hasIndexTailOnDisk()
        let playback = ExportPlaybackState.shared.playbackStartSeconds
        let playbackHint: Double? = ExportPlaybackState.shared.isLANExportActive
            ? playback
            : (playback > 0 ? playback : nil)
        ExportPlaybackState.shared.syncSparseLayout(
            totalBytes: totalLength,
            filledSpans: spans,
            headOnDisk: head,
            tailOnDisk: tail,
            playbackStartSeconds: playbackHint
        )
        let durationSeconds = ExportPlaybackState.shared.exportDurationSeconds
        ExportPlaybackState.shared.updateWanDownloadStats(
            averageActiveMbps: throughput.averageActiveMbps(),
            lastBurstMbps: throughput.lastBurstMbps(),
            backgroundActive: isBackgroundDownloadActive(),
            backgroundFillPercent: backgroundPrefetchPercent(),
            denseBytesOnDiskPercent: denseBytesOnDiskPercent(),
            backgroundTimelineSeconds: backgroundTimelineSeconds(durationSeconds: durationSeconds)
        )
        if let mediaCursorSeconds {
            ExportPlaybackState.shared.updateCursor(seconds: mediaCursorSeconds)
        }
    }

    /// Write manifest + sync LAN state after export ends (before temp downloader is torn down).
    func flushLANPlaybackManifestForExportEnd() {
        syncLANPlaybackManifestNow(mediaCursorSeconds: nil)
    }

    /// Publish dense spans + write manifest immediately (per-minute LAN status must not wait on debounced save).
    func syncLANPlaybackManifestNow(mediaCursorSeconds: Double?) {
        manifestSaveTask?.cancel()
        manifestSaveTask = nil
        publishLANPlaybackState(mediaCursorSeconds: mediaCursorSeconds)
        persistManifestNow()
    }

    /// When the sparse temp is already fully dense, ensure the LAN catalog spans the whole file (not just head/tail flags).
    func recordFullDenseFileForLANIfNeeded() {
        let full = TimelineByteRange(start: 0, end: totalLength)
        guard isByteRangeFullyOnDisk(full) else { return }
        lock.lock()
        recordFilledRange(offset: 0, end: totalLength)
        lock.unlock()
        publishLANPlaybackState()
        persistManifestNow()
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

    /// Wait for background prefetch at EOF, or return once background was paused (export uses disk per minute).
    func waitUntilComplete(
        durationSeconds: Double = 0,
        onProgress: ((Double) -> Void)? = nil
    ) async throws {
        var lastLoggedPercent = -Self.progressStepPercent
        while true {
            if isCancelled() { throw SegmentExporterError.cancelled }
            if isByteRangeFullyOnDisk(TimelineByteRange(start: 0, end: totalLength)) {
                log("Temp copy complete — \(formatBytes(totalLength))\(averageSpeedLogSuffix())")
                onProgress?(durationSeconds > 0 ? durationSeconds : 0)
                publishLANPlaybackState(mediaCursorSeconds: durationSeconds > 0 ? durationSeconds : nil)
                return
            }
            lock.lock()
            let spans = filledRanges
            let anchor = playbackAnchorByteLocked(total: totalLength)
            let contiguousEnd = Self.contiguousDenseEndFromByte(anchor, spans: spans)
            let backgroundActive = downloadTask != nil && !backgroundPausedForStream
            lock.unlock()
            if contiguousEnd >= totalLength {
                log("Temp copy complete — \(formatBytes(totalLength))\(averageSpeedLogSuffix())")
                onProgress?(durationSeconds > 0 ? durationSeconds : 0)
                publishLANPlaybackState(mediaCursorSeconds: durationSeconds > 0 ? durationSeconds : nil)
                return
            }
            if durationSeconds > 0 {
                let timelineSec = Self.timelineSecondsForByteOffset(
                    contiguousEnd,
                    totalLength: totalLength,
                    durationSeconds: durationSeconds
                )
                onProgress?(timelineSec)
                publishLANPlaybackState(mediaCursorSeconds: timelineSec)
                logBackgroundProgressIfNeeded(
                    cursor: contiguousEnd,
                    onDisk: !backgroundActive,
                    lastLoggedPercent: &lastLoggedPercent
                )
            }
            if !backgroundActive {
                log(
                    "Background prefetch finished (paused for segment export) — \(formatBytes(contiguousEnd)) contiguous on disk; export loop done"
                )
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
            if headOnDisk, !lanPreloadExclusive {
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
        let anchor = playbackAnchorByteLocked(total: totalLength)
        regionStart = anchor
        guard !filledRanges.isEmpty else {
            regionFilledEnd = anchor
            downloadCursor = anchor
            return
        }
        regionFilledEnd = Self.contiguousDenseEndFromByte(anchor, spans: filledRanges)
        downloadCursor = regionFilledEnd
    }

    /// Next byte background should fetch (never leap over an unfilled gap).
    private func nextBackgroundFetchOffsetLocked() -> Int64 {
        let anchor = playbackAnchorByteLocked(total: totalLength)
        regionStart = anchor
        let contiguousEnd = Self.contiguousDenseEndFromByte(anchor, spans: filledRanges)
        regionFilledEnd = contiguousEnd
        if downloadCursor > contiguousEnd {
            return contiguousEnd
        }
        return downloadCursor
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
        var playbackStart = (playback["playbackStartSeconds"] as? Double) ?? 0
        let duration = (playback["durationSeconds"] as? Double) ?? 0
        var cursor = (playback["exportCursorSeconds"] as? Double) ?? 0
        let exportActive = ExportPlaybackState.shared.isLANExportActive
        if exportActive {
            playbackStart = ExportPlaybackState.shared.playbackStartSeconds
            cursor = ExportPlaybackState.shared.exportCursorSeconds
        }
        if playbackStart > 0, cursor > 0, cursor < playbackStart {
            cursor = playbackStart
        }
        WorkingSourceSparseCatalog.save(
            fileKey: key,
            totalLength: length,
            href: href,
            filledRanges: spans,
            headOnDisk: head,
            tailOnDisk: tail,
            playbackStartSeconds: exportActive || playbackStart > 0 ? playbackStart : nil,
            durationSeconds: duration > 0 ? duration : nil,
            exportCursorSeconds: exportActive || cursor > 0 ? cursor : nil
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
        restoreDownloadRegionFromFilledSpansLocked()
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

    private func startPrefixFillBeforeSeekIfNeeded() {
        lock.lock()
        let seek = playbackStartSecondsForAnchor
        let duration = anchorDurationSeconds
        let exclusive = lanPreloadExclusive
        let already = prefixDownloadTask != nil
        lock.unlock()
        guard seek > 0.5, duration > 0, !exclusive, !already else { return }
        guard !isLANPrefixBeforeSeekOnDisk(seekSeconds: seek, durationSeconds: duration) else { return }
        log(
            "LAN prefix — filling 0:00 → \(ExportTimelineLog.wallClock(seconds: seek)) from pCloud " +
                "in background while segment export is idle…"
        )
        prefixDownloadTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.prefixDownloadTask = nil
                self.lock.unlock()
            }
            var attempt = 0
            while !self.isCancelled(), !Task.isCancelled {
                do {
                    try await self.runPrefixFillBeforeSeekLoop()
                    return
                } catch is CancellationError {
                    return
                } catch {
                    if self.isCancelled() { return }
                    let delaySec = Self.backgroundRetryDelaysSeconds[
                        min(attempt, Self.backgroundRetryDelaysSeconds.count - 1)
                    ]
                    self.log(
                        "LAN prefix fill — \(error.localizedDescription); retry in \(delaySec)s " +
                            "(attempt \(attempt + 1))…"
                    )
                    attempt += 1
                    try? await Task.sleep(nanoseconds: delaySec * 1_000_000_000)
                }
            }
        }
    }

    private func runPrefixFillBeforeSeekLoop() async throws {
        while !isCancelled(), !Task.isCancelled {
            lock.lock()
            let paused = foregroundFillPauseDepth > 0
            let seek = playbackStartSecondsForAnchor
            let duration = anchorDurationSeconds
            lock.unlock()
            if paused {
                try await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            guard seek > 0.5, duration > 0 else { return }
            if isLANPrefixBeforeSeekOnDisk(seekSeconds: seek, durationSeconds: duration) {
                log("LAN prefix — 0:00 → \(ExportTimelineLog.wallClock(seconds: seek)) dense on disk")
                return
            }
            try await ensureLANPrefixBeforeSeekFilled(seekSeconds: seek, durationSeconds: duration)
            return
        }
    }

    private func startBackgroundDownload() {
        downloadTask?.cancel()
        downloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !self.isCancelled(), !Task.isCancelled {
                do {
                    try await self.runDownloadLoop()
                    return
                } catch is CancellationError {
                    return
                } catch {
                    if self.isCancelled() { return }
                    let ns = error as NSError
                    if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
                    self.lock.lock()
                    let foregroundPaused = self.foregroundFillPauseDepth > 0
                    self.lock.unlock()
                    if foregroundPaused { return }
                    let delaySec = Self.backgroundRetryDelaysSeconds[
                        min(attempt, Self.backgroundRetryDelaysSeconds.count - 1)
                    ]
                    self.log(
                        "Background prefetch hit \(error.localizedDescription) — retrying in \(delaySec)s (attempt \(attempt + 1))"
                    )
                    attempt += 1
                    do {
                        try await Task.sleep(nanoseconds: delaySec * 1_000_000_000)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    private func runDownloadLoop() async throws {
        var lastLoggedPercent = -Self.progressStepPercent
        while true {
            if isCancelled() || Task.isCancelled { throw CancellationError() }

            lock.lock()
            var start = nextBackgroundFetchOffsetLocked()
            if start != downloadCursor {
                downloadCursor = start
            }
            if start >= totalLength {
                lock.unlock()
                if isByteRangeFullyOnDisk(TimelineByteRange(start: 0, end: totalLength)) {
                    recordFullDenseFileForLANIfNeeded()
                }
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
            lock.lock()
            let spans = filledRanges
            let contiguousEnd = contiguousDenseEndForLANPlaybackLocked(spans: spans, total: totalLength)
            lock.unlock()
            var batch: [(offset: Int64, end: Int64, length: Int)] = []
            var scan = start
            lock.lock()
            let parallelism = lanPreloadExclusive
                ? Self.lanPreloadOnlyParallelism
                : Self.backgroundPrefetchParallelism
            lock.unlock()
            while scan < stopAt, batch.count < parallelism {
                if isCancelled() || Task.isCancelled { throw CancellationError() }
                let end = min(scan + Self.downloadChunkBytes - 1, stopAt - 1, totalLength - 1)
                let length = Int(end - scan + 1)
                let chunkEnd = end + 1
                if Self.rangeFullyCovered(offset: scan, length: length, spans: spans),
                   chunkEnd <= contiguousEnd {
                    lock.lock()
                    if chunkEnd > downloadCursor { downloadCursor = chunkEnd }
                    regionFilledEnd = Self.contiguousDenseEndFromByte(regionStart, spans: filledRanges)
                    lock.unlock()
                    scan = chunkEnd
                    continue
                }
                batch.append((offset: scan, end: end, length: length))
                scan = chunkEnd
            }
            if batch.isEmpty {
                lock.lock()
                let cursor = regionFilledEnd
                lock.unlock()
                logBackgroundProgressIfNeeded(
                    cursor: cursor,
                    onDisk: true,
                    lastLoggedPercent: &lastLoggedPercent
                )
                await Task.yield()
                continue
            }
            let auth = authorizationProvider()
            let fetched = try await fetchBackgroundChunksParallel(authorization: auth, chunks: batch)
            for (offset, data) in fetched.sorted(by: { $0.0 < $1.0 }) {
                throughput.recordNetworkBytes(data.count)
                try write(data, at: offset)
            }
            lock.lock()
            restoreDownloadRegionFromFilledSpansLocked()
            let cursor = downloadCursor
            lock.unlock()
            logBackgroundProgressIfNeeded(
                cursor: cursor,
                onDisk: false,
                lastLoggedPercent: &lastLoggedPercent
            )
            if cursor >= totalLength {
                recordFullDenseFileForLANIfNeeded()
            }
            await Task.yield()
        }
    }

    private func logBackgroundProgressIfNeeded(
        cursor: Int64,
        onDisk: Bool,
        lastLoggedPercent: inout Int
    ) {
        let pct = totalLength > 0 ? Int(cursor * 100 / totalLength) : 0
        guard pct >= lastLoggedPercent + Self.progressStepPercent || cursor >= totalLength else { return }
        lastLoggedPercent = (pct / Self.progressStepPercent) * Self.progressStepPercent
        let suffix = onDisk ? " (on disk)" : ""
        log("Download \(pct)% — \(formatBytes(cursor)) / \(formatBytes(totalLength))\(suffix)\(speedLogSuffix())")
    }

    private func fetchBackgroundChunksParallel(
        authorization: String,
        chunks: [(offset: Int64, end: Int64, length: Int)]
    ) async throws -> [(Int64, Data)] {
        try await withThrowingTaskGroup(of: (Int64, Data).self) { group in
            for chunk in chunks {
                group.addTask {
                    let data = try await Self.fetchRange(
                        remoteURL: self.remoteURL,
                        authorization: authorization,
                        offset: chunk.offset,
                        endInclusive: chunk.end
                    )
                    guard data.count == chunk.length else {
                        throw WebDAVResourceLoaderError.invalidResponse
                    }
                    return (chunk.offset, data)
                }
            }
            var out: [(Int64, Data)] = []
            out.reserveCapacity(chunks.count)
            for try await item in group {
                out.append(item)
            }
            return out
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
    private var activeBytes: Int64 = 0
    private var activeStartedAt: CFAbsoluteTime?
    private var lastNetworkAt = CFAbsoluteTimeGetCurrent()
    private var peakBurstMbps: Double = 0
    private static let activeIdleGapSeconds = 3.0

    func reset() {
        lock.lock()
        totalBytes = 0
        startedAt = CFAbsoluteTimeGetCurrent()
        lastSampleBytes = 0
        lastSampleAt = startedAt
        activeBytes = 0
        activeStartedAt = nil
        lastNetworkAt = startedAt
        peakBurstMbps = 0
        lock.unlock()
    }

    func recordNetworkBytes(_ bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastNetworkAt > Self.activeIdleGapSeconds {
            activeBytes = 0
            activeStartedAt = now
        }
        lastNetworkAt = now
        totalBytes += Int64(bytes)
        if activeStartedAt == nil {
            activeStartedAt = now
        }
        activeBytes += Int64(bytes)
        lock.unlock()
        if let burst = intervalMbps() {
            lock.lock()
            peakBurstMbps = max(peakBurstMbps, burst)
            lock.unlock()
        }
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

    /// Average Mbps counting only intervals when pCloud bytes were actually received (excludes export/passthrough idle).
    func averageActiveMbps() -> Double? {
        lock.lock()
        let bytes = activeBytes
        let started = activeStartedAt
        lock.unlock()
        guard let started, bytes > 0 else { return nil }
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        guard elapsed >= 0.5 else { return nil }
        return Self.mbps(bytes: bytes, seconds: elapsed)
    }

    func lastBurstMbps() -> Double? {
        lock.lock()
        let burst = peakBurstMbps
        lock.unlock()
        return burst > 0 ? burst : nil
    }

    private static func mbps(bytes: Int64, seconds: Double) -> Double {
        (Double(bytes) * 8.0) / (seconds * 1_000_000.0)
    }
}
