import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Serves HTTPS WebDAV media to `AVURLAsset` with Basic auth and byte-range reads.
final class WebDAVResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let customScheme = "loopsegments-webdav"
    private static let maxRangeChunkBytes: Int64 = 2 * 1024 * 1024

    let remoteURL: URL
    let authorization: String
    let queue = DispatchQueue(label: "com.loopsegments.webdav-resource-loader")

    private let session: URLSession
    private var cachedContentLength: Int64?
    private let lengthLock = NSLock()
    private let log: ((String) -> Void)?

    init(
        remoteURL: URL,
        authorization: String,
        session: URLSession = WebDAVMediaSession.shared,
        log: ((String) -> Void)? = nil
    ) {
        self.remoteURL = remoteURL
        self.authorization = authorization
        self.session = session
        self.log = log
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
        queue.async { [weak self] in
            self?.fill(loadingRequest)
        }
        return true
    }

    private func fill(_ loadingRequest: AVAssetResourceLoadingRequest) {
        do {
            if let info = loadingRequest.contentInformationRequest {
                let length = try resolveContentLength()
                info.contentLength = length
                info.isByteRangeAccessSupported = true
                info.contentType = mimeType(for: remoteURL)
            }

            if let dataRequest = loadingRequest.dataRequest {
                let offset = dataRequest.requestedOffset
                let length = Int64(dataRequest.requestedLength)
                let end = offset + length - 1
                let data = try fetchRange(offset: offset, length: length, endInclusive: end)
                dataRequest.respond(with: data)
            }

            loadingRequest.finishLoading()
        } catch {
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

    private func resolveContentLength() throws -> Int64 {
        lengthLock.lock()
        if let cachedContentLength {
            lengthLock.unlock()
            return cachedContentLength
        }
        lengthLock.unlock()

        var request = URLRequest(url: remoteURL)
        request.httpMethod = "HEAD"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let (_, response) = try sessionSyncData(for: request)
        if let http = response as? HTTPURLResponse,
           let length = contentLength(from: http) {
            storeLength(length)
            log?("Content-Length \(length) bytes (HEAD)")
            return length
        }

        _ = try fetchRangeChunk(offset: 0, endInclusive: 0)
        lengthLock.lock()
        defer { lengthLock.unlock() }
        guard let cachedContentLength else {
            throw WebDAVResourceLoaderError.missingContentLength
        }
        return cachedContentLength
    }

    private func fetchRange(offset: Int64, length: Int64, endInclusive: Int64) throws -> Data {
        if length <= Self.maxRangeChunkBytes {
            return try fetchRangeChunk(offset: offset, endInclusive: endInclusive)
        }

        log?("Range \(offset)-\(endInclusive) (\(length) B) — reading in chunks")
        var combined = Data()
        combined.reserveCapacity(Int(min(length, Int64(32 * 1024 * 1024))))
        var cursor = offset
        while cursor <= endInclusive {
            let chunkEnd = min(cursor + Self.maxRangeChunkBytes - 1, endInclusive)
            let chunk = try fetchRangeChunk(offset: cursor, endInclusive: chunkEnd)
            combined.append(chunk)
            cursor = chunkEnd + 1
        }
        return combined
    }

    private func fetchRangeChunk(offset: Int64, endInclusive: Int64) throws -> Data {
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("bytes=\(offset)-\(endInclusive)", forHTTPHeaderField: "Range")

        let (data, response) = try sessionSyncData(for: request)
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

        return data
    }

    private func sessionSyncData(for request: URLRequest, maxAttempts: Int = 4) throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 1 ... maxAttempts {
            do {
                return try sessionSyncDataOnce(for: request)
            } catch {
                lastError = error
                guard WebDAVMediaSession.isRetriable(error), attempt < maxAttempts else {
                    throw error
                }
                let delay = UInt64(attempt) * 2_000_000_000
                log?("pCloud read retry \(attempt + 1)/\(maxAttempts): \(error.localizedDescription)")
                Thread.sleep(forTimeInterval: Double(delay) / 1_000_000_000)
            }
        }
        throw lastError ?? WebDAVResourceLoaderError.invalidResponse
    }

    private func sessionSyncDataOnce(for request: URLRequest) throws -> (Data, URLResponse) {
        var result: Result<(Data, URLResponse), Error>?
        let sem = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let data, let response {
                result = .success((data, response))
            } else {
                result = .failure(WebDAVResourceLoaderError.invalidResponse)
            }
            sem.signal()
        }
        task.resume()
        sem.wait()
        return try result!.get()
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

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response loading media from pCloud."
        case .httpStatus(let code):
            return "pCloud media request failed (HTTP \(code))."
        case .missingContentLength:
            return "Could not determine file size from pCloud."
        }
    }
}
