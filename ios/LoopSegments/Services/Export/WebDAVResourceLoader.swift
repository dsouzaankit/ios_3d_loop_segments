import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Caps AVFoundation “read to EOF” requests so a 12 GB remote MP4 is not pulled over the network.
struct StreamReadPolicy {
    let fileLength: Int64
    let indexTailStart: Int64
    let allowedSpans: [ClosedRange<Int64>]

    static func forExportWindow(
        fileLength: Int64,
        window: TimelineByteRange,
        indexTailBytes: Int64
    ) -> StreamReadPolicy {
        let tailStart = max(0, fileLength - indexTailBytes)
        var spans: [ClosedRange<Int64>] = []
        if fileLength > 0 {
            let headEnd = min(fileLength - 1, 4 * 1024 * 1024 - 1)
            spans.append(0 ... headEnd)
        }
        if window.end > window.start {
            spans.append(window.start ... min(window.end - 1, max(0, fileLength - 1)))
        }
        if tailStart < fileLength {
            spans.append(tailStart ... (fileLength - 1))
        }
        return StreamReadPolicy(
            fileLength: fileLength,
            indexTailStart: tailStart,
            allowedSpans: spans
        )
    }

    func cappedLength(
        offset: Int64,
        requested: Int64,
        requestsAllDataToEndOfResource: Bool
    ) -> Int64 {
        let remaining = fileLength - offset
        guard remaining > 0 else { return 0 }
        if requestsAllDataToEndOfResource {
            return min(remaining, maxAllDataToEnd(at: offset))
        }
        guard requested > 0 else { return 0 }
        return min(requested, remaining, maxPartialRead(at: offset, requested: requested))
    }

    private func maxAllDataToEnd(at offset: Int64) -> Int64 {
        let slack: Int64 = 8 * 1024 * 1024
        for span in allowedSpans where span.contains(offset) {
            let spanEnd = span.upperBound
            return min(fileLength - offset, spanEnd - offset + 1 + slack)
        }
        if offset >= indexTailStart {
            return fileLength - offset
        }
        return min(fileLength - offset, 8 * 1024 * 1024)
    }

    private func maxPartialRead(at offset: Int64, requested: Int64) -> Int64 {
        for span in allowedSpans where span.contains(offset) {
            let spanEnd = span.upperBound
            return min(requested, spanEnd - offset + 1)
        }
        return min(requested, 512 * 1024)
    }
}

/// Serves HTTPS WebDAV media to `AVURLAsset` with Basic auth and byte-range reads.
final class WebDAVResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let customScheme = "loopsegments-webdav"
    private static let maxRangeChunkBytes: Int64 = 2 * 1024 * 1024
    private static let hotCacheMaxBytes = 4 * 1024 * 1024

    let remoteURL: URL
    private let authorizationProvider: WebDAVAuthorizationProvider
    let queue = DispatchQueue(label: "com.loopsegments.webdav-resource-loader")

    private let session: URLSession
    private let rangeCache: WebDAVRangeCache?
    private let readPolicy: StreamReadPolicy?
    /// When set, serve dense spans from this sparse temp file and fetch holes from pCloud on demand.
    private let localTempURL: URL?
    private let readLocalBytes: ((Int64, Int) -> Data?)?
    private let logLine: ((String) -> Void)?
    private let throughput = LoaderThroughput()
    private let rangeFetchGate = RangeFetchGate(maxSlots: 3)

    private var cachedContentLength: Int64?
    private let trustedContentLength: Int64?
    private var lengthResolveTask: Task<Int64, Error>?
    /// AVFoundation often issues several loading requests at once (content info + ranges). Cancelling the previous request caused multi‑GB reads to abort and export failed with “Could not start reading”.
    private var activeFillTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var hotCacheStart: Int64 = -1
    private var hotCacheData = Data()
    private let stateLock = NSLock()

    convenience init(
        remoteURL: URL,
        authorization: String,
        session: URLSession = WebDAVMediaSession.shared,
        rangeCache: WebDAVRangeCache? = nil,
        log: ((String) -> Void)? = nil
    ) {
        self.init(
            remoteURL: remoteURL,
            authorizationProvider: { authorization },
            session: session,
            rangeCache: rangeCache,
            trustedContentLength: rangeCache?.contentLengthValue(),
            log: log
        )
    }

    init(
        remoteURL: URL,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        session: URLSession = WebDAVMediaSession.shared,
        rangeCache: WebDAVRangeCache? = nil,
        trustedContentLength: Int64? = nil,
        readPolicy: StreamReadPolicy? = nil,
        localTempURL: URL? = nil,
        readLocalBytes: ((Int64, Int) -> Data?)? = nil,
        log: ((String) -> Void)? = nil
    ) {
        self.remoteURL = remoteURL
        self.authorizationProvider = authorizationProvider
        self.session = session
        self.rangeCache = rangeCache
        self.trustedContentLength = trustedContentLength
        self.readPolicy = readPolicy
        self.localTempURL = localTempURL
        self.readLocalBytes = readLocalBytes
        self.logLine = log
        super.init()
    }

    /// Stop in-flight probe reads when switching to local temp export.
    func cancelOutstandingWork() {
        stateLock.lock()
        for task in activeFillTasks.values {
            task.cancel()
        }
        activeFillTasks.removeAll()
        lengthResolveTask?.cancel()
        lengthResolveTask = nil
        stateLock.unlock()
    }

    /// Stable host (`export`) — real WebDAV hostnames (e.g. `webdav.pcloud.com`) make `AVURLAsset.loadTracks` fail with “unsupported URL”.
    var customAssetURL: URL {
        let encodedPath = Self.percentEncodedWebDAVPath(remoteURL.path)
        guard let url = URL(string: "\(Self.customScheme)://export\(encodedPath)") else {
            return URL(string: "\(Self.customScheme)://export/")!
        }
        return url
    }

    /// Spaces and other characters in WebDAV paths break `URLComponents.url`; never fall back to `https://` for `AVURLAsset`.
    private static func percentEncodedWebDAVPath(_ path: String) -> String {
        let normalized = path.isEmpty ? "/" : (path.hasPrefix("/") ? path : "/\(path)")
        guard normalized != "/" else { return "/" }
        let segments = normalized.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return "/" }
        return "/" + segments.map { segment in
            segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? segment
        }.joined(separator: "/")
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let requestID = ObjectIdentifier(loadingRequest)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.fill(loadingRequest)
            self.stateLock.lock()
            self.activeFillTasks.removeValue(forKey: requestID)
            self.stateLock.unlock()
        }
        stateLock.lock()
        activeFillTasks[requestID] = task
        stateLock.unlock()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let requestID = ObjectIdentifier(loadingRequest)
        stateLock.lock()
        activeFillTasks.removeValue(forKey: requestID)?.cancel()
        stateLock.unlock()
    }

    private func onLoaderQueue<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    private func fill(_ loadingRequest: AVAssetResourceLoadingRequest) async {
        if await onLoaderQueue({ loadingRequest.isCancelled }) {
            return
        }

        do {
            if loadingRequest.contentInformationRequest != nil {
                let length = try await resolveContentLength()
                await onLoaderQueue {
                    if loadingRequest.isCancelled { return }
                    guard let info = loadingRequest.contentInformationRequest else { return }
                    info.contentLength = length
                    info.isByteRangeAccessSupported = true
                    info.contentType = self.mimeType(for: self.remoteURL)
                }
            }

            if let dataRequest = loadingRequest.dataRequest {
                try await fulfill(dataRequest, loadingRequest: loadingRequest)
            }

            await onLoaderQueue {
                if !loadingRequest.isCancelled {
                    loadingRequest.finishLoading()
                }
            }
        } catch is CancellationError {
            return
        } catch {
            let cancelled = await onLoaderQueue { loadingRequest.isCancelled }
            guard !cancelled else { return }
            let wrapped = NSError(
                domain: "WebDAVResourceLoader",
                code: 1,
                userInfo: [
                    NSUnderlyingErrorKey: error,
                    NSLocalizedDescriptionKey: WebDAVMediaSession.friendlyMessage(for: error),
                ]
            )
            await onLoaderQueue {
                loadingRequest.finishLoading(with: wrapped)
            }
        }
    }

    private func fulfill(
        _ dataRequest: AVAssetResourceLoadingDataRequest,
        loadingRequest: AVAssetResourceLoadingRequest
    ) async throws {
        let offset = dataRequest.requestedOffset
        let fileLength = try await resolveContentLength()
        guard fileLength > 0, offset < fileLength else { return }

        let bytesRemaining = fileLength - offset
        let requested = dataRequest.requestsAllDataToEndOfResource
            ? bytesRemaining
            : Int64(dataRequest.requestedLength)
        guard requested > 0 else { return }

        var totalLength: Int64
        if let readPolicy {
            totalLength = readPolicy.cappedLength(
                offset: offset,
                requested: requested,
                requestsAllDataToEndOfResource: dataRequest.requestsAllDataToEndOfResource
            )
            if dataRequest.requestsAllDataToEndOfResource, requested > totalLength {
                let via = localTempURL != nil ? "hybrid" : "pCloud"
                logLine?(
                    "\(via) read capped \(formatBytes(requested)) → \(formatBytes(totalLength)) at \(formatBytes(offset)) (AVFoundation asked for EOF)"
                )
            }
        } else if dataRequest.requestsAllDataToEndOfResource {
            totalLength = min(bytesRemaining, 16 * 1024 * 1024)
        } else {
            totalLength = min(requested, bytesRemaining)
        }
        guard totalLength > 0 else { return }

        throughput.resetIfIdle()
        var cursor = offset
        let end = offset + totalLength - 1
        let largeRequest = totalLength > Self.maxRangeChunkBytes
        let hybridSparse = localTempURL != nil
        if largeRequest {
            let via = hybridSparse ? "sparse temp" : "pCloud"
            logLine?(
                "\(via) read \(offset)-\(end) (\(formatBytes(totalLength)) of \(formatBytes(fileLength)), \(Self.maxRangeChunkBytes / 1024) KiB chunks)\(throughput.speedSuffix())"
            )
        } else if hybridSparse, readLocalBytes?(offset, Int(totalLength)) == nil {
            logLine?("Sparse temp gap — pCloud range \(offset)-\(end) (\(totalLength) bytes)\(throughput.speedSuffix())")
        } else if !hybridSparse {
            logLine?("pCloud range \(offset)-\(end) (\(totalLength) bytes)\(throughput.speedSuffix())")
        }

        var chunksDone = 0
        var lastProgressLog = 0
        while cursor <= end {
            if await onLoaderQueue({ loadingRequest.isCancelled }) || Task.isCancelled {
                return
            }
            let chunkEnd = min(cursor + Self.maxRangeChunkBytes - 1, end)
            let chunk = try await fetchRangeChunk(offset: cursor, endInclusive: chunkEnd)
            throughput.recordNetworkBytes(chunk.count)
            await onLoaderQueue {
                if loadingRequest.isCancelled { return }
                dataRequest.respond(with: chunk)
            }
            cursor = chunkEnd + 1
            chunksDone += 1
            let logProgressEvery = hybridSparse ? 16 : 128
            if (largeRequest || hybridSparse), chunksDone - lastProgressLog >= logProgressEvery {
                lastProgressLog = chunksDone
                let done = cursor - offset
                let pct = totalLength > 0 ? Int(done * 100 / totalLength) : 100
                let via = hybridSparse ? "sparse temp" : "pCloud"
                logLine?(
                    "\(via) read progress — \(pct)% (\(formatBytes(done)) / \(formatBytes(totalLength)))\(throughput.speedSuffix())"
                )
            }
            if chunksDone % 16 == 0 {
                await Task.yield()
            }
        }
    }

    /// Read prefetch cache, then a small hot cache for AVFoundation's sequential 64 KiB sample reads.
    private func fetchRangeChunk(offset: Int64, endInclusive: Int64) async throws -> Data {
        let length = Int(endInclusive - offset + 1)
        guard length > 0 else { return Data() }
        if let readLocalBytes, let local = readLocalBytes(offset, length), local.count == length {
            return local
        }
        if let cached = rangeCache?.dataForRequest(offset: offset, length: length) {
            return cached
        }
        if let slice = hotCacheSlice(offset: offset, length: length) {
            return slice
        }

        var lastError: Error?
        for attempt in 1 ... 4 {
            if Task.isCancelled { throw CancellationError() }
            do {
                let data = try await rangeFetchGate.withSlot {
                    try await performRangeGETOnce(offset: offset, endInclusive: endInclusive)
                }
                storeHotCache(offset: offset, data: data)
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard WebDAVMediaSession.isRetriable(error), attempt < 4 else { throw error }
                logLine?("pCloud range retry \(attempt + 1)/4: \(error.localizedDescription)")
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            }
        }
        throw lastError ?? WebDAVResourceLoaderError.invalidResponse
    }

    private func performRangeGETOnce(offset: Int64, endInclusive: Int64) async throws -> Data {
        let (data, response) = try await performRangeGET(offset: offset, endInclusive: endInclusive, retriedAuth: false)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVResourceLoaderError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) || http.statusCode == 206 else {
            throw WebDAVResourceLoaderError.httpStatus(http.statusCode)
        }
        return data
    }

    private func hotCacheSlice(offset: Int64, length: Int) -> Data? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard hotCacheStart >= 0, !hotCacheData.isEmpty else { return nil }
        let cacheEnd = hotCacheStart + Int64(hotCacheData.count)
        let reqEnd = offset + Int64(length)
        guard offset >= hotCacheStart, reqEnd <= cacheEnd else { return nil }
        let start = Int(offset - hotCacheStart)
        return hotCacheData.subdata(in: start ..< start + length)
    }

    private func storeHotCache(offset: Int64, data: Data) {
        guard !data.isEmpty else { return }
        stateLock.lock()
        if hotCacheStart >= 0,
           offset == hotCacheStart + Int64(hotCacheData.count) {
            hotCacheData.append(data)
        } else if hotCacheStart < 0 || offset < hotCacheStart {
            hotCacheStart = offset
            hotCacheData = data
        } else {
            hotCacheStart = offset
            hotCacheData = data
        }
        if hotCacheData.count > Self.hotCacheMaxBytes {
            let trim = hotCacheData.count - Int(Self.hotCacheMaxBytes)
            hotCacheStart += Int64(trim)
            hotCacheData = hotCacheData.subdata(in: trim ..< hotCacheData.count)
        }
        stateLock.unlock()
    }

    private func performRangeGET(
        offset: Int64,
        endInclusive: Int64,
        retriedAuth: Bool
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        request.setValue(authorizationProvider(), forHTTPHeaderField: "Authorization")
        request.setValue("bytes=\(offset)-\(endInclusive)", forHTTPHeaderField: "Range")

        let result = try await WebDAVMediaSession.data(for: request, log: logLine)
        if let http = result.1 as? HTTPURLResponse,
           http.statusCode == 401,
           !retriedAuth {
            logLine?("HTTP 401 on range read — retrying with fresh credentials")
            return try await performRangeGET(offset: offset, endInclusive: endInclusive, retriedAuth: true)
        }
        return result
    }

    private func resolveContentLength() async throws -> Int64 {
        if let trustedContentLength, trustedContentLength > 0 {
            storeLength(trustedContentLength)
            return trustedContentLength
        }
        if let preloaded = rangeCache?.contentLengthValue() {
            storeLength(preloaded)
            return preloaded
        }
        stateLock.lock()
        if let cachedContentLength {
            let value = cachedContentLength
            stateLock.unlock()
            return value
        }
        if let lengthResolveTask {
            stateLock.unlock()
            return try await lengthResolveTask.value
        }

        let task = Task<Int64, Error> {
            try await self.loadContentLengthFromServer()
        }
        lengthResolveTask = task
        stateLock.unlock()

        defer {
            stateLock.lock()
            lengthResolveTask = nil
            stateLock.unlock()
        }
        let length = try await task.value
        storeLength(length)
        return length
    }

    private func loadContentLengthFromServer() async throws -> Int64 {
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "HEAD"
        request.setValue(authorizationProvider(), forHTTPHeaderField: "Authorization")
        let (_, response) = try await WebDAVMediaSession.data(for: request, log: logLine)
        if let http = response as? HTTPURLResponse,
           let length = contentLength(from: http) {
            logLine?("Content-Length \(length) bytes (HEAD)")
            return length
        }

        _ = try await fetchRangeChunk(offset: 0, endInclusive: 0)
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let cachedContentLength else {
            throw WebDAVResourceLoaderError.missingContentLength
        }
        logLine?("Content-Length \(cachedContentLength) bytes (probe)")
        return cachedContentLength
    }

    private func contentLength(from response: HTTPURLResponse) -> Int64? {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let total = parseTotalLength(from: contentRange) {
            return total
        }
        return response.expectedContentLength >= 0
            ? response.expectedContentLength
            : nil
    }

    private func parseTotalLength(from contentRange: String) -> Int64? {
        guard let slash = contentRange.lastIndex(of: "/") else { return nil }
        let totalPart = contentRange[contentRange.index(after: slash)...]
        return Int64(totalPart)
    }

    private func storeLength(_ length: Int64) {
        storeLengthIfPlausible(length)
    }

    /// Ignore bogus totals from a bad MP4 parse (prevents multi‑GB stream reads).
    private func storeLengthIfPlausible(_ length: Int64) {
        guard length > 0, length <= Self.maxPlausibleFileBytes else { return }
        stateLock.lock()
        if let existing = cachedContentLength, existing > 0 {
            let ratio = Double(length) / Double(existing)
            if ratio > 4.0 || ratio < 0.25 {
                stateLock.unlock()
                return
            }
        }
        cachedContentLength = length
        stateLock.unlock()
        rangeCache?.storeContentLength(length)
    }

    private static let maxPlausibleFileBytes: Int64 = 32 * 1024 * 1024 * 1024

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
        }
        if bytes >= 1024 * 1024 {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
        }
        return "\(bytes) B"
    }

    private func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext),
           let mime = type.preferredMIMEType {
            return mime
        }
        switch ext {
        case "mp4", "m4v", "mov":
            return "video/mp4"
        case "mkv":
            return "video/x-matroska"
        case "webm":
            return "video/webm"
        case "avi":
            return "video/avi"
        default:
            return "application/octet-stream"
        }
    }
}

private final class LoaderThroughput: @unchecked Sendable {
    private let lock = NSLock()
    private var totalBytes: Int64 = 0
    private var lastSampleBytes: Int64 = 0
    private var lastSampleAt = CFAbsoluteTimeGetCurrent()
    private var startedAt = CFAbsoluteTimeGetCurrent()

    func resetIfIdle() {
        lock.lock()
        let idle = CFAbsoluteTimeGetCurrent() - lastSampleAt > 30
        if idle {
            totalBytes = 0
            lastSampleBytes = 0
            startedAt = CFAbsoluteTimeGetCurrent()
        }
        lock.unlock()
    }

    func recordNetworkBytes(_ bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        totalBytes += Int64(bytes)
        lock.unlock()
    }

    func speedSuffix() -> String {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        let intervalElapsed = now - lastSampleAt
        let deltaBytes = totalBytes - lastSampleBytes
        if intervalElapsed >= 0.5, deltaBytes > 0 {
            let mbps = (Double(deltaBytes) * 8.0) / (intervalElapsed * 1_000_000.0)
            lastSampleAt = now
            lastSampleBytes = totalBytes
            lock.unlock()
            return String(format: " @ %.1f Mbps", mbps)
        }
        let avgElapsed = now - startedAt
        let bytes = totalBytes
        lock.unlock()
        guard avgElapsed >= 1.0, bytes > 0 else { return "" }
        let avg = (Double(bytes) * 8.0) / (avgElapsed * 1_000_000.0)
        return String(format: " @ %.1f Mbps avg", avg)
    }
}

/// Limits parallel pCloud range GETs when AVFoundation issues many loader requests at once.
private actor RangeFetchGate {
    private let maxSlots: Int
    private var used = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxSlots: Int) {
        self.maxSlots = max(1, maxSlots)
    }

    func withSlot<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if used < maxSlots {
            used += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            used -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum WebDAVResourceLoaderError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case missingContentLength
    case suspiciousContentLength(Int64)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response loading media from pCloud."
        case .httpStatus(let code):
            return WebDAVHTTPMessages.requestFailed(code)
        case .missingContentLength:
            return "Could not determine file size from pCloud."
        case .suspiciousContentLength(let bytes):
            return "pCloud returned \(bytes) bytes for this file (not a video). Check the path or try re-browsing the folder."
        }
    }
}
