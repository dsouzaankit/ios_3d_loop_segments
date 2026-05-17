import Foundation

/// HEAD + index bytes before AVAsset opens the file (avoids ~30s AVFoundation loader timeout).
enum WebDAVPrefetch {
    private static let headPrefixBytes: Int64 = 512 * 1024
    private static let tailSuffixBytes: Int64 = 2 * 1024 * 1024

    static func warmUp(
        remoteURL: URL,
        authorization: String,
        cache: WebDAVRangeCache,
        log: ((String) -> Void)?
    ) async throws {
        log?("Prefetch: HEAD")
        let length = try await fetchContentLength(remoteURL: remoteURL, authorization: authorization)
        cache.storeContentLength(length)
        log?("Prefetch: file size \(length) bytes")
        if length > 0, length < 4096 {
            throw WebDAVResourceLoaderError.suspiciousContentLength(length)
        }

        if length <= 0 { return }

        let firstEnd = min(headPrefixBytes, length) - 1
        if firstEnd >= 0 {
            log?("Prefetch: first \(firstEnd + 1) bytes")
            let data = try await fetchRange(
                remoteURL: remoteURL,
                authorization: authorization,
                offset: 0,
                endInclusive: firstEnd
            )
            cache.storeRange(offset: 0, data: data)
        }

        let tailLen = min(tailSuffixBytes, length)
        let tailStart = max(0, length - tailLen)
        if tailStart <= firstEnd + 1 {
            return
        }
        log?("Prefetch: last \(length - tailStart) bytes (MP4 index)")
        let tailData = try await fetchRange(
            remoteURL: remoteURL,
            authorization: authorization,
            offset: tailStart,
            endInclusive: length - 1
        )
        cache.storeRange(offset: tailStart, data: tailData)
    }

    private static func fetchContentLength(remoteURL: URL, authorization: String) async throws -> Int64 {
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "HEAD"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let (_, response) = try await sessionData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVResourceLoaderError.invalidResponse
        }
        if (200 ... 299).contains(http.statusCode), let len = contentLength(from: http) {
            return len
        }

        let (_, probeResponse) = try await sessionData(for: rangeRequest(
            remoteURL: remoteURL,
            authorization: authorization,
            offset: 0,
            endInclusive: 0
        ))
        guard let probeHttp = probeResponse as? HTTPURLResponse else {
            throw WebDAVResourceLoaderError.invalidResponse
        }
        guard (200 ... 299).contains(probeHttp.statusCode) || probeHttp.statusCode == 206 else {
            throw WebDAVResourceLoaderError.httpStatus(probeHttp.statusCode)
        }
        if let len = contentLength(from: probeHttp) { return len }
        throw WebDAVResourceLoaderError.missingContentLength
    }

    private static func rangeRequest(
        remoteURL: URL,
        authorization: String,
        offset: Int64,
        endInclusive: Int64
    ) -> URLRequest {
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("bytes=\(offset)-\(endInclusive)", forHTTPHeaderField: "Range")
        return request
    }

    private static func fetchRange(
        remoteURL: URL,
        authorization: String,
        offset: Int64,
        endInclusive: Int64
    ) async throws -> Data {
        let (data, response) = try await sessionData(for: rangeRequest(
            remoteURL: remoteURL,
            authorization: authorization,
            offset: offset,
            endInclusive: endInclusive
        ))
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVResourceLoaderError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) || http.statusCode == 206 else {
            throw WebDAVResourceLoaderError.httpStatus(http.statusCode)
        }
        if let len = contentLength(from: http) {
            // caller may not have length yet
            _ = len
        }
        return data
    }

    private static func sessionData(for request: URLRequest, maxAttempts: Int = 4) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 1 ... maxAttempts {
            do {
                return try await WebDAVMediaSession.shared.data(for: request)
            } catch {
                lastError = error
                guard WebDAVMediaSession.isRetriable(error), attempt < maxAttempts else { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
        }
        throw lastError ?? WebDAVResourceLoaderError.invalidResponse
    }

    private static func contentLength(from response: HTTPURLResponse) -> Int64? {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let total = parseTotalLength(from: contentRange) {
            return total
        }
        return response.expectedContentLength >= 0 ? response.expectedContentLength : nil
    }

    private static func parseTotalLength(from contentRange: String) -> Int64? {
        guard let slash = contentRange.lastIndex(of: "/") else { return nil }
        return Int64(contentRange[contentRange.index(after: slash)...])
    }
}
