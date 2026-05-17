import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Serves HTTPS WebDAV media to `AVURLAsset` with Basic auth and byte-range reads.
final class WebDAVResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let customScheme = "loopsegments-webdav"
    private static let maxRangeChunkBytes: Int64 = 512 * 1024

    let remoteURL: URL
    private let authorizationProvider: WebDAVAuthorizationProvider
    let queue = DispatchQueue(label: "com.loopsegments.webdav-resource-loader")

    private let session: URLSession
    private let rangeCache: WebDAVRangeCache?
    private let logLine: ((String) -> Void)?

    private var cachedContentLength: Int64?
    private let trustedContentLength: Int64?
    private var lengthResolveTask: Task<Int64, Error>?
    private var activeFillTask: Task<Void, Never>?
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
        log: ((String) -> Void)? = nil
    ) {
        self.remoteURL = remoteURL
        self.authorizationProvider = authorizationProvider
        self.session = session
        self.rangeCache = rangeCache
        self.trustedContentLength = trustedContentLength
        self.logLine = log
        super.init()
    }

    /// Stop in-flight probe reads when switching to local temp export.
    func cancelOutstandingWork() {
        stateLock.lock()
        activeFillTask?.cancel()
        activeFillTask = nil
        lengthResolveTask?.cancel()
        lengthResolveTask = nil
        stateLock.unlock()
    }

    var customAssetURL: URL {
        var components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        components.scheme = Self.customScheme
        components.host = remoteURL.host ?? components.host
        components.path = remoteURL.path.isEmpty ? "/" : remoteURL.path
        return components.url ?? remoteURL
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.fill(loadingRequest)
        }
        stateLock.lock()
        activeFillTask?.cancel()
        activeFillTask = task
        stateLock.unlock()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        stateLock.lock()
        activeFillTask?.cancel()
        activeFillTask = nil
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
        let totalLength: Int64
        if dataRequest.requestsAllDataToEndOfResource {
            // Never satisfy “to EOF” in one callback — AV may ask for 10+ GB and jetsam/cancel export.
            totalLength = min(bytesRemaining, Self.maxRangeChunkBytes)
        } else {
            let requested = Int64(dataRequest.requestedLength)
            guard requested > 0 else { return }
            totalLength = min(requested, bytesRemaining)
        }
        guard totalLength > 0 else { return }

        var cursor = offset
        let end = offset + totalLength - 1
        if totalLength > Self.maxRangeChunkBytes {
            logLine?(
                "pCloud read \(offset)-\(end) (\(formatBytes(totalLength)) of \(formatBytes(fileLength)), \(Self.maxRangeChunkBytes / 1024) KiB chunks)"
            )
        } else {
            logLine?("pCloud range \(offset)-\(end) (\(totalLength) bytes)")
        }

        var chunksDone = 0
        while cursor <= end {
            if await onLoaderQueue({ loadingRequest.isCancelled }) || Task.isCancelled {
                return
            }
            let chunkEnd = min(cursor + Self.maxRangeChunkBytes - 1, end)
            let chunk = try await fetchRangeChunk(offset: cursor, endInclusive: chunkEnd)
            await onLoaderQueue {
                if loadingRequest.isCancelled { return }
                dataRequest.respond(with: chunk)
            }
            cursor = chunkEnd + 1
            chunksDone += 1
            if chunksDone % 16 == 0 {
                await Task.yield()
            }
        }
    }

    /// Read prefetch cache only; do not store streamed bytes (multi-GB files would jetsam).
    private func fetchRangeChunk(offset: Int64, endInclusive: Int64) async throws -> Data {
        let length = Int(endInclusive - offset + 1)
        if length > 0, let cached = rangeCache?.dataForRequest(offset: offset, length: length) {
            return cached
        }

        let (data, response) = try await performRangeGET(offset: offset, endInclusive: endInclusive, retriedAuth: false)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVResourceLoaderError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) || http.statusCode == 206 else {
            throw WebDAVResourceLoaderError.httpStatus(http.statusCode)
        }
        return data
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
