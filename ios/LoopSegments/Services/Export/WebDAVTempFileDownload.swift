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
    private var downloadTask: Task<Void, Error>?
    private var writeHandle: FileHandle?
    private var downloadCursor: Int64 = 0
    private let throughput = DownloadThroughput()

    init(
        remoteURL: URL,
        rangeCache: WebDAVRangeCache,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        isCancelled: @escaping () -> Bool,
        log: @escaping (String) -> Void
    ) throws {
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

        try? FileManager.default.removeItem(at: fileURL)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw SegmentExporterError.writerSetupFailed
        }
        writeHandle = try FileHandle(forWritingTo: fileURL)
        try applyCachedSpans(rangeCache)
        try finalizeSparseLayout()
    }

    /// Position download at seek (or 0) and start background range fetches.
    func beginExport(seekSeconds: Double, durationSeconds: Double) {
        throughput.reset()
        applyInitialPosition(seekSeconds: seekSeconds, durationSeconds: durationSeconds)
        startBackgroundDownload()
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

    func ensureIndexTailOnDisk() async throws {
        lock.lock()
        let hasTail = tailOnDisk
        lock.unlock()
        guard !hasTail else { return }

        let tailLen = min(2 * 1024 * 1024, totalLength)
        let tailStart = max(0, totalLength - tailLen)
        log("Fetching MP4 index tail from pCloud (\(formatBytes(totalLength - tailStart)))…")
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
    }

    deinit {
        downloadTask?.cancel()
        try? writeHandle?.close()
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        try? writeHandle?.close()
        writeHandle = nil
        ExportPaths.removeWorkingSourceCopy()
    }

    func filledSpan() -> TimelineByteRange {
        lock.lock()
        defer { lock.unlock() }
        return filledSpanLocked()
    }

    func hasIndexTailOnDisk() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tailOnDisk
    }

    func logDownloadStarted() {
        log("Downloading to temp — \(formatBytes(totalLength)) (segments publish per 60s as data arrives)…")
    }

    /// File byte span that must be on disk for media `[timelineStartSeconds, timelineEndSeconds]`.
    func byteRangeForTimeline(
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
        let preroll = keyframePrerollBytes(timelineStartSeconds: startSec)
        let startByte = max(
            0,
            Int64((startSec / effectiveDuration) * Double(totalLength)) - preroll
        )
        var endByte = min(
            totalLength,
            Int64((endSec / effectiveDuration) * Double(totalLength)) + Self.timelineSlackBytes
        )
        let windowSeconds = endSec - startSec
        if totalLength > 900_000_000, windowSeconds <= 60.5, startSec <= 0.5 {
            endByte = max(endByte, min(Int64(300 * 1024 * 1024) + Self.timelineSlackBytes, totalLength))
        } else if totalLength > 500_000_000, windowSeconds <= 60.5, startSec <= 0.5 {
            endByte = max(endByte, min(Int64(180 * 1024 * 1024) + Self.timelineSlackBytes, totalLength))
        }
        if endByte <= startByte {
            endByte = min(totalLength, startByte + Self.downloadChunkBytes)
        }
        return TimelineByteRange(start: startByte, end: endByte)
    }

    func isRangeFilled(_ range: TimelineByteRange) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return regionStart <= range.start && regionFilledEnd >= range.end
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

        while true {
            if isCancelled() { throw SegmentExporterError.cancelled }
            if isRangeFilled(range) || filledSpanLocked().end >= totalLength { return }

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

    func waitUntilLocalExportReady(
        timelineStartSeconds: Double,
        timelineEndSeconds: Double,
        durationSeconds: Double
    ) async throws {
        guard durationSeconds > 0, tailOnDisk else { return }
        let range = byteRangeForTimeline(
            timelineStartSeconds: timelineStartSeconds,
            timelineEndSeconds: timelineEndSeconds,
            durationSeconds: durationSeconds
        )
        while !isRangeFilled(range) {
            if isCancelled() { throw SegmentExporterError.cancelled }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let endMin = Int(timelineEndSeconds) / 60
        let endSec = Int(timelineEndSeconds) % 60
        let span = filledSpan()
        log(
            "Local temp ready for \(endMin):\(String(format: "%02d", endSec)) — \(formatBytes(span.start))–\(formatBytes(span.end)) on disk"
        )
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
            regionStart = 0
            downloadCursor = regionFilledEnd
            lock.unlock()
            log("Download from file start — need ~\(formatBytes(range.end)) for first minute")
        } else {
            regionStart = range.start
            regionFilledEnd = range.start
            downloadCursor = range.start
            lock.unlock()
            let seekMin = Int(seekSeconds) / 60
            let seekSec = Int(seekSeconds) % 60
            log(
                "Seek \(seekMin):\(String(format: "%02d", seekSec)) — download from ~\(formatBytes(range.start)) (skipping earlier bytes, like ffmpeg -ss)"
            )
            log("First segment needs ~\(formatBytes(range.length)) at \(formatBytes(range.start))–\(formatBytes(range.end))")
        }
    }

    private func keyframePrerollBytes(timelineStartSeconds: Double) -> Int64 {
        guard timelineStartSeconds > 0.5 else { return 0 }
        let fromDuration = Int64(min(48 * 1024 * 1024, (timelineStartSeconds / 120.0) * Double(totalLength)))
        let fromSize = min(32 * 1024 * 1024, totalLength / 40)
        return max(fromDuration, fromSize)
    }

    private func applyCachedSpans(_ cache: WebDAVRangeCache) throws {
        let tailThreshold = max(0, totalLength - 3 * 1024 * 1024)
        for span in cache.storedSpans() {
            try write(span.data, at: span.start)
            if span.start >= tailThreshold {
                lock.lock()
                tailOnDisk = true
                lock.unlock()
            }
        }
        try writeHandle?.synchronize()
    }

    private func noteWrite(offset: Int64, length: Int) {
        let end = offset + Int64(length)
        if length <= 0 { return }
        if regionFilledEnd == 0, regionStart == 0, offset == 0 {
            regionStart = 0
            regionFilledEnd = end
            return
        }
        if offset == regionFilledEnd {
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
    }

    private func write(_ data: Data, at offset: Int64) throws {
        guard let writeHandle else { return }
        try writeHandle.seek(toOffset: UInt64(offset))
        try writeHandle.write(contentsOf: data)
        lock.lock()
        noteWrite(offset: offset, length: data.count)
        lock.unlock()
    }

    private func startBackgroundDownload() {
        downloadTask?.cancel()
        downloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try await self.runDownloadLoop()
            } catch is CancellationError {
                return
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

            let end = min(start + Self.downloadChunkBytes - 1, totalLength - 1)
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

    private static func effectiveDurationSeconds(reported: Double, totalBytes: Int64) -> Double {
        guard reported > 0, totalBytes > 0 else { return reported }
        let floorMbps = 2.0
        let minFromSize = Double(totalBytes) * 8.0 / (floorMbps * 1_000_000.0)
        return max(reported, minFromSize)
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
