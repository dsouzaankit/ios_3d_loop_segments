import Foundation

/// Background download to a growing local file; export starts after ~1 min buffer, reads use disk then pCloud.
final class WebDAVProgressiveBuffer: @unchecked Sendable {
    static let primeWallSeconds: TimeInterval = 60
    static let primeMinimumBytes: Int64 = 1024 * 1024
    private static let downloadChunkBytes: Int64 = 1024 * 1024

    let fileURL: URL
    let totalLength: Int64

    private let remoteURL: URL
    private let authorizationProvider: WebDAVAuthorizationProvider
    private let isCancelled: () -> Bool
    private let log: (String) -> Void

    private let lock = NSLock()
    private var contiguousEnd: Int64 = 0
    private var downloadTask: Task<Void, Error>?
    private var writeHandle: FileHandle?
    private var readHandle: FileHandle?

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
        readHandle = try FileHandle(forReadingFrom: fileURL)

        try applyCachedSpans(rangeCache)
        startBackgroundDownload()
    }

    deinit {
        downloadTask?.cancel()
        try? writeHandle?.close()
        try? readHandle?.close()
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    /// Wait ~60s and at least 1 MiB contiguous from start, then export may begin while download continues.
    func primeForPlayback() async throws {
        log("Buffering from pCloud — export starts after ~\(Int(Self.primeWallSeconds))s (download continues in background)…")
        let started = CFAbsoluteTimeGetCurrent()
        var lastLogSecond = -10

        while true {
            if isCancelled() { throw SegmentExporterError.cancelled }

            let contiguous = contiguousEndValue()
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            let elapsedInt = Int(elapsed)

            if elapsed >= Self.primeWallSeconds, contiguous >= Self.primeMinimumBytes {
                log("Buffer ready — \(formatBytes(contiguous)) after \(elapsedInt)s; starting stream export")
                return
            }

            if elapsedInt - lastLogSecond >= 10 {
                lastLogSecond = elapsedInt
                let pct = totalLength > 0 ? Int(contiguous * 100 / totalLength) : 0
                log("Buffering… \(formatBytes(contiguous)) (\(elapsedInt)s / \(Int(Self.primeWallSeconds))s, \(pct)% of file on disk)")
            }

            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func hasContiguousBytes(until endInclusive: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return contiguousEnd > endInclusive
    }

    func read(offset: Int64, length: Int) throws -> Data? {
        lock.lock()
        let endNeeded = offset + Int64(length)
        guard endNeeded <= contiguousEnd else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        guard let readHandle else { return nil }
        try readHandle.seek(toOffset: UInt64(offset))
        guard let data = try readHandle.read(upToCount: length), data.count == length else {
            return nil
        }
        return data
    }

    /// Brief wait for sequential download to reach `endInclusive` before hitting pCloud directly.
    func waitForContiguous(until endInclusive: Int64, timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while CFAbsoluteTimeGetCurrent() < deadline {
            if hasContiguousBytes(until: endInclusive) { return true }
            if isCancelled() { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return hasContiguousBytes(until: endInclusive)
    }

    func contiguousEndValue() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return contiguousEnd
    }

    private func applyCachedSpans(_ cache: WebDAVRangeCache) throws {
        for span in cache.storedSpans() {
            try write(span.data, at: span.start)
        }
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
        downloadTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                try await self.runDownloadLoop()
            } catch is CancellationError {
                return
            } catch {
                if !self.isCancelled() {
                    self.log("Background download stopped: \(error.localizedDescription)")
                }
            }
        }
    }

    private func runDownloadLoop() async throws {
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
            await Task.yield()
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
