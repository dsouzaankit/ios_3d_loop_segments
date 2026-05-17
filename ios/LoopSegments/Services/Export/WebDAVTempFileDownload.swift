import Foundation

/// Downloads the full remote MP4 to temp storage; exposes contiguous progress for timed segment export.
final class WebDAVTempFileDownload: @unchecked Sendable {
    private static let downloadChunkBytes: Int64 = 2 * 1024 * 1024
    private static let progressStepPercent = 5

    let fileURL: URL
    let totalLength: Int64

    private let remoteURL: URL
    private let authorizationProvider: WebDAVAuthorizationProvider
    private let isCancelled: () -> Bool
    private let log: (String) -> Void

    private let lock = NSLock()
    private var contiguousEnd: Int64 = 0
    private var tailOnDisk = false
    private var downloadTask: Task<Void, Error>?
    private var writeHandle: FileHandle?

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
        let contiguous = contiguousEnd
        lock.unlock()
        log(
            "Temp sparse layout — file size \(formatBytes(onDisk)), contiguous from 0: \(formatBytes(contiguous)), index tail: \(hasTail ? "yes" : "no")"
        )
        if !hasTail {
            log("Warning: MP4 index not on disk yet — track probe may use pCloud")
        }
    }

    /// Write index tail from pCloud when prefetch did not land on disk.
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

    func contiguousEndValue() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return contiguousEnd
    }

    /// True when prefetched/downloaded MP4 `moov` is at the end of the temp file (allows export before 100% download).
    func hasIndexTailOnDisk() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tailOnDisk
    }

    func logDownloadStarted() {
        log("Downloading to temp — \(formatBytes(totalLength)) (segments publish per 60s as data arrives)…")
    }

    /// Bytes that must be contiguous from offset 0 before exporting through `timelineEndSeconds`.
    func bytesRequiredThroughTimeline(
        timelineEndSeconds: Double,
        durationSeconds: Double
    ) -> Int64 {
        guard durationSeconds > 0, totalLength > 0 else { return totalLength }
        let endSeconds = min(max(0, timelineEndSeconds), durationSeconds)
        let slack: Int64 = 24 * 1024 * 1024

        let effectiveDuration = Self.effectiveDurationSeconds(
            reported: durationSeconds,
            totalBytes: totalLength
        )
        let avgFromSize = Double(totalLength) / effectiveDuration
        let linearFromSize = Int64(endSeconds * avgFromSize) + slack

        // 3D SBS can be high bitrate, but cap first-minute floor so export can start before hundreds of MB.
        let highBitrateFloorMbps = min(35.0, max(8.0, (Double(totalLength) * 8.0) / (effectiveDuration * 1_000_000.0)))
        let floorBytesPerSecond = highBitrateFloorMbps * 1_000_000.0 / 8.0
        let floorRequired = Int64(endSeconds * floorBytesPerSecond) + slack
        let capForFirstMinute = Int64(180 * 1024 * 1024)
        var required = max(linearFromSize, min(floorRequired, capForFirstMinute + slack))

        // Trust reported duration when it is plausible vs file size (avoid 100% trap on bad short probes).
        let sizeImpliedDuration = Double(totalLength) * 8.0 / (2.0 * 1_000_000.0)
        if durationSeconds >= sizeImpliedDuration * 0.35 {
            let fromReported = Int64((endSeconds / durationSeconds) * Double(totalLength)) + slack
            required = max(required, min(fromReported, capForFirstMinute + slack))
        }

        return min(required, totalLength)
    }

    /// Sequential bytes from file start through this point in the timeline (MP4 index tail is written at EOF at init).
    func isReadyForLocalExport(timelineEndSeconds: Double, durationSeconds: Double) -> Bool {
        guard durationSeconds > 0, tailOnDisk else { return false }
        let required = bytesRequiredThroughTimeline(
            timelineEndSeconds: timelineEndSeconds,
            durationSeconds: durationSeconds
        )
        return contiguousEndValue() >= required
    }

    /// After timeline bytes exist on disk, wait until local `AVAssetReader` can run (no pCloud stream fallback).
    func waitUntilLocalExportReady(
        timelineEndSeconds: Double,
        durationSeconds: Double
    ) async throws {
        guard durationSeconds > 0 else { return }
        let endSeconds = min(timelineEndSeconds, durationSeconds)
        while !isReadyForLocalExport(
            timelineEndSeconds: timelineEndSeconds,
            durationSeconds: durationSeconds
        ) {
            if isCancelled() { throw SegmentExporterError.cancelled }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let mediaMin = Int(endSeconds) / 60
        let mediaSec = Int(endSeconds) % 60
        log("Local temp ready through \(mediaMin):\(String(format: "%02d", mediaSec)) — \(formatBytes(contiguousEndValue())) contiguous from start")
    }

    /// Wait until sequential download likely covers media through `timelineEndSeconds` (seek 0 recommended).
    func waitUntilTimelineEnd(
        timelineEndSeconds: Double,
        durationSeconds: Double
    ) async throws {
        guard durationSeconds > 0 else { return }
        let endSeconds = min(timelineEndSeconds, durationSeconds)
        let required = bytesRequiredThroughTimeline(
            timelineEndSeconds: timelineEndSeconds,
            durationSeconds: durationSeconds
        )
        var lastLoggedPercent = -Self.progressStepPercent
        var lastStallLog = CFAbsoluteTimeGetCurrent()

        while true {
            if isCancelled() { throw SegmentExporterError.cancelled }
            let contiguous = contiguousEndValue()
            if contiguous >= required || contiguous >= totalLength { return }

            let now = CFAbsoluteTimeGetCurrent()
            let dlPct = totalLength > 0 ? Int(contiguous * 100 / totalLength) : 0
            let needPct = totalLength > 0 ? Int(required * 100 / totalLength) : 0
            if dlPct >= lastLoggedPercent + Self.progressStepPercent || now - lastStallLog >= 20 {
                lastStallLog = now
                lastLoggedPercent = (dlPct / Self.progressStepPercent) * Self.progressStepPercent
                let mediaMin = Int(endSeconds) / 60
                let mediaSec = Int(endSeconds) % 60
                log(
                    "Download \(dlPct)% (\(formatBytes(contiguous))) — need ~\(needPct)% (\(formatBytes(required))) for media through \(mediaMin):\(String(format: "%02d", mediaSec))"
                )
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func waitUntilComplete() async throws {
        while true {
            if isCancelled() { throw SegmentExporterError.cancelled }
            if contiguousEndValue() >= totalLength {
                log("Temp copy complete — \(formatBytes(totalLength))")
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
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

    private func write(_ data: Data, at offset: Int64) throws {
        guard let writeHandle else { return }
        try writeHandle.seek(toOffset: UInt64(offset))
        try writeHandle.write(contentsOf: data)
        lock.lock()
        if offset == contiguousEnd {
            contiguousEnd += Int64(data.count)
        }
        lock.unlock()
    }

    private func startBackgroundDownload() {
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

            let start = contiguousEndValue()
            if start >= totalLength { return }

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
            try write(data, at: start)

            let pct = Int((end + 1) * 100 / totalLength)
            if pct >= lastLoggedPercent + Self.progressStepPercent || end + 1 >= totalLength {
                lastLoggedPercent = (pct / Self.progressStepPercent) * Self.progressStepPercent
                log("Download \(pct)% — \(formatBytes(end + 1)) / \(formatBytes(totalLength))")
            }
            await Task.yield()
        }
    }

    /// Multi-GB files with a too-short probed duration used to require ~100% download before minute 0.
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
        // Sparse temp: we never require the full remote size on disk up front.
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
}
