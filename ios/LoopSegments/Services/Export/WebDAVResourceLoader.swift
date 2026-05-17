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
    let authorization: String
    let queue = DispatchQueue(label: "com.loopsegments.webdav-resource-loader")

    private let session: URLSession
    private let rangeCache: WebDAVRangeCache?
    private var cachedContentLength: Int64?
    private let lengthLock = NSLock()
    private var lengthResolveTask: Task<Int64, Error>?
    private let logLine: ((String) -> Void)?

    init(
        remoteURL: URL,
        authorization: String,
        session: URLSession = WebDAVMediaSession.shared,
        rangeCache: WebDAVRangeCache? = nil,
        log: ((String) -> Void)? = nil
    ) {
        self.remoteURL = remoteURL
        self.authorization = authorization
        self.session = session
        self.rangeCache = rangeCache
        self.logLine = log
        super.init()
    }

    var customAssetURL: URL {
        var components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)!
        components.scheme = Self.customScheme
        return components.url!
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        Task {
            await self.fill(loadingRequest)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        logLine?("pCloud read cancelled")
    }

    private func fill(_ loadingRequest: AVAssetResourceLoadingRequest) async {
        if loadingRequest.isCancelled {
            finishCancelled(loadingRequest)
            return
        }

        do {
            if let info = loadingRequest.contentInformationRequest {
                let length = try await resolveContentLength()
                info.contentLength = length
                info.isByteRangeAccessSupported = true
                info.contentType = mimeType(for: remoteURL)
            }

            if let dataRequest = loadingRequest.dataRequest {
                try await fulfill(dataRequest, loadingRequest: loadingRequest)
            }

            if !loadingRequest.isCancelled {
                loadingRequest.finishLoading()
            }
        } catch {
            guard !loadingRequest.isCancelled else {
                finishCancelled(loadingRequest)
                return
            }
            let wrapped = NSError(
                domain: "WebDAVResourceLoader",
                code: 1,
                userInfo: [
                    NSUnderlyingErrorKey: error,
                    NSLocalizedDescriptionKey: WebDAVMediaSession.friendlyMessage(for: error),
                ]
            )
            loadingRequest.finishLoading(with: wrapped)
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
        logLine?("pCloud range \(offset)-\(end) (\(totalLength) bytes)")

        while cursor <= end {
            if loadingRequest.isCancelled {
                throw CancellationError()
            }
            let chunkEnd = min(cursor + Self.maxRangeChunkBytes - 1, end)
            let chunk = try await fetchRangeChunk(offset: cursor, endInclusive: chunkEnd)
            dataRequest.respond(with: chunk)
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
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "HEAD"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

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

        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("bytes=\(offset)-\(endInclusive)", forHTTPHeaderField: "Range")

        let (data, response) = try await sessionData(for: request)
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

    private func sessionData(for request: URLRequest, maxAttempts: Int = 4) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 1 ... maxAttempts {
            do {
                return try await session.data(for: request)
            } catch {
                lastError = error
                guard WebDAVMediaSession.isRetriable(error), attempt < maxAttempts else {
                    throw error
                }
                logLine?("pCloud retry \(attempt + 1)/\(maxAttempts): \(error.localizedDescription)")
                try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
        }
        throw lastError ?? WebDAVResourceLoaderError.invalidResponse
    }

    private func finishCancelled(_ loadingRequest: AVAssetResourceLoadingRequest) {
        loadingRequest.finishLoading(with: NSError(
            domain: NSCocoaErrorDomain,
            code: NSUserCancelledError,
            userInfo: nil
        ))
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
