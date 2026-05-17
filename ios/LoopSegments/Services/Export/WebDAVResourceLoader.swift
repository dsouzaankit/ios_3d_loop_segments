import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Serves HTTPS WebDAV media to `AVURLAsset` with Basic auth and byte-range reads.
/// Uses async HTTP + incremental `respond(with:)` so AVFoundation's ~30s loader deadline is not hit.
final class WebDAVResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let customScheme = "loopsegments-webdav"
    /// Keep each network round-trip payload small on cellular.
    private static let maxRangeChunkBytes: Int64 = 512 * 1024

    let remoteURL: URL
    private let authorizationProvider: WebDAVAuthorizationProvider
    let queue = DispatchQueue(label: "com.loopsegments.webdav-resource-loader")

    private let session: URLSession
    private let rangeCache: WebDAVRangeCache?
    private var cachedContentLength: Int64?
    private let lengthLock = NSLock()
    private var lengthResolveTask: Task<Int64, Error>?
    private var inflightFills: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let inflightLock = NSLock()
    private let logLine: ((String) -> Void)?

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
            log: log
        )
    }

    init(
        remoteURL: URL,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        session: URLSession = WebDAVMediaSession.shared,
        rangeCache: WebDAVRangeCache? = nil,
        log: ((String) -> Void)? = nil
    ) {
        self.remoteURL = remoteURL
        self.authorizationProvider = authorizationProvider
        self.session = session
        self.rangeCache = rangeCache
        self.logLine = log
        super.init()
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
        let id = ObjectIdentifier(loadingRequest)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.fill(loadingRequest)
            self.removeInflight(id)
        }
        inflightLock.lock()
        inflightFills[id] = task
        inflightLock.unlock()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        queue.async {
            let id = ObjectIdentifier(loadingRequest)
            self.inflightLock.lock()
            let task = self.inflightFills.removeValue(forKey: id)
            self.inflightLock.unlock()
            task?.cancel()
        }
    }

    private func removeInflight(_ id: ObjectIdentifier) {
        inflightLock.lock()
        inflightFills.removeValue(forKey: id)
        inflightLock.unlock()
    }

    /// AVFoundation requires `respond` / `finishLoading` on the resource-loader delegate queue.
    private func onLoaderQueue<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    private func fill(_ loadingRequest: AVAssetResourceLoadingRequest) async {
        if await onLoaderQueue({ loadingRequest.isCancelled }) || Task.isCancelled {
            return
        }

        do {
            if loadingRequest.contentInformationRequest != nil {
                let length = try await resolveContentLength()
                await onLoaderQueue {
                    if loadingRequest.isCancelled || Task.isCancelled { return }
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
                if !loadingRequest.isCancelled, !Task.isCancelled {
                    loadingRequest.finishLoading()
                }
            }
        } catch is CancellationError {
            return
        } catch {
            let cancelled = await onLoaderQueue { loadingRequest.isCancelled }
            guard !cancelled, !Task.isCancelled else { return }
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
        let totalLength = Int64(dataRequest.requestedLength)
        guard totalLength > 0 else { return }

        var cursor = offset
        let end = offset + totalLength - 1
        if totalLength > Self.maxRangeChunkBytes {
            logLine?(
                "pCloud read \(offset)-\(end) (\(totalLength) bytes requested, \(Self.maxRangeChunkBytes / 1024) KiB HTTP chunks)"
            )
        } else {
            logLine?("pCloud range \(offset)-\(end) (\(totalLength) bytes)")
        }

        while cursor <= end {
            let cancelled = await onLoaderQueue { loadingRequest.isCancelled }
            if cancelled || Task.isCancelled {
                return
            }
            let chunkEnd = min(cursor + Self.maxRangeChunkBytes - 1, end)
            let chunk = try await fetchRangeChunk(offset: cursor, endInclusive: chunkEnd)
            await onLoaderQueue {
                if loadingRequest.isCancelled || Task.isCancelled { return }
                dataRequest.respond(with: chunk)
            }
            cursor = chunkEnd + 1
        }
    }

    private func resolveContentLength() async throws -> Int64 {
        if let preloaded = rangeCache?.contentLengthValue() {
            storeLength(preloaded)
            return preloaded
        }
        lengthLock.lock()
        if let cachedContentLength {
            lengthLock.unlock()
            return cachedContentLength
        }
        if let lengthResolveTask {
            lengthLock.unlock()
            return try await lengthResolveTask.value
        }

        let task = Task<Int64, Error> {
            try await self.loadContentLengthFromServer()
        }
        lengthResolveTask = task
        lengthLock.unlock()

        defer {
            lengthLock.lock()
            if lengthResolveTask != nil { lengthResolveTask = nil }
            lengthLock.unlock()
        }
        let length = try await task.value
        storeLength(length)
        return length
    }

    private func loadContentLengthFromServer() async throws -> Int64 {
        let request = authorizedRequest(method: "HEAD")
        let (_, response) = try await sessionData(for: request)
        if let http = response as? HTTPURLResponse,
           let length = contentLength(from: http) {
            logLine?("Content-Length \(length) bytes (HEAD)")
            return length
        }

        _ = try await fetchRangeChunk(offset: 0, endInclusive: 0)
        lengthLock.lock()
        defer { lengthLock.unlock() }
        guard let cachedContentLength else {
            throw WebDAVResourceLoaderError.missingContentLength
        }
        logLine?("Content-Length \(cachedContentLength) bytes (probe)")
        return cachedContentLength
    }

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

        if let length = contentLength(from: http) {
            storeLength(length)
        } else if http.statusCode == 206,
                  let range = http.value(forHTTPHeaderField: "Content-Range"),
                  let total = parseTotalLength(from: range) {
            storeLength(total)
        }

        rangeCache?.storeRange(offset: offset, data: data)
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

        let result = try await sessionData(for: request)
        if let http = result.1 as? HTTPURLResponse,
           http.statusCode == 401,
           !retriedAuth {
            logLine?("HTTP 401 on range read — retrying with fresh credentials")
            return try await performRangeGET(offset: offset, endInclusive: endInclusive, retriedAuth: true)
        }
        return result
    }

    private func authorizedRequest(method: String) -> URLRequest {
        var request = URLRequest(url: remoteURL)
        request.httpMethod = method
        request.setValue(authorizationProvider(), forHTTPHeaderField: "Authorization")
        return request
    }

    private func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await WebDAVMediaSession.data(for: request, log: logLine)
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
        lengthLock.lock()
        cachedContentLength = length
        lengthLock.unlock()
        rangeCache?.storeContentLength(length)
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
