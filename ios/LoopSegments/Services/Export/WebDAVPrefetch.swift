import Foundation

/// HEAD + index bytes before AVAsset opens the file (avoids ~30s AVFoundation loader timeout).
enum WebDAVPrefetch {
    private static let headPrefixBytes: Int64 = 512 * 1024
    private static let tailSuffixBytes: Int64 = 2 * 1024 * 1024

    static func warmUp(
        remoteURL: URL,
        authorization: String,
        cache: WebDAVRangeCache,
        catalogContentLength: Int64? = nil,
        log: ((String) -> Void)? = nil
    ) async throws {
        log?("Prefetch: HEAD (file size)")
        let headLength = try await fetchContentLength(
            remoteURL: remoteURL,
            authorization: authorization,
            log: log
        )
        let length = WebDAVContentLength.resolve(
            headBytes: headLength > 0 ? headLength : nil,
            catalogBytes: catalogContentLength,
            log: log
        )
        cache.storeContentLength(length)
        log?("Prefetch: file size \(formatBytes(length)) (\(length) bytes)")
        if length > 0, length < 4096 {
            throw WebDAVResourceLoaderError.suspiciousContentLength(length)
        }

        if length <= 0 {
            log?("Prefetch: skipped — unknown file size")
            return
        }

        let firstEnd = min(headPrefixBytes, length) - 1
        let tailLen = min(tailSuffixBytes, length)
        let tailStart = max(0, length - tailLen)

        // Index at EOF first — required for large moov-at-end files to expose video tracks.
        if tailStart > firstEnd + 1 {
            log?("Prefetch: downloading last \(formatBytes(length - tailStart)) (MP4 index at EOF)")
            let tailData = try await fetchRange(
                remoteURL: remoteURL,
                authorization: authorization,
                offset: tailStart,
                endInclusive: length - 1,
                log: log
            )
            cache.storeRange(offset: tailStart, data: tailData, isIndexTail: true)
        }

        if firstEnd >= 0 {
            log?("Prefetch: downloading first \(formatBytes(firstEnd + 1))")
            let data = try await fetchRange(
                remoteURL: remoteURL,
                authorization: authorization,
                offset: 0,
                endInclusive: firstEnd,
                log: log
            )
            cache.storeRange(offset: 0, data: data)
        }

        if tailStart <= firstEnd + 1 {
            log?("Prefetch: complete (file smaller than head+tail window)")
            return
        }
        log?("Prefetch: complete — \(formatBytes(length)) file, head + index cached for export")
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", Double(bytes) / 1_073_741_824.0)
        }
        if bytes >= 1024 * 1024 {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
        }
        return "\(bytes) B"
    }

    private static func fetchContentLength(
        remoteURL: URL,
        authorization: String,
        log: ((String) -> Void)?
    ) async throws -> Int64 {
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "HEAD"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let (_, response) = try await sessionData(for: request, log: log)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVResourceLoaderError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw WebDAVResourceLoaderError.httpStatus(http.statusCode)
        }
        if (200 ... 299).contains(http.statusCode), let len = contentLength(from: http) {
            return len
        }

        let (_, probeResponse) = try await sessionData(for: rangeRequest(
            remoteURL: remoteURL,
            authorization: authorization,
            offset: 0,
            endInclusive: 0
        ), log: log)
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
        endInclusive: Int64,
        log: ((String) -> Void)?
    ) async throws -> Data {
        let (data, response) = try await sessionData(for: rangeRequest(
            remoteURL: remoteURL,
            authorization: authorization,
            offset: offset,
            endInclusive: endInclusive
        ), log: log)
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

    private static func sessionData(
        for request: URLRequest,
        log: ((String) -> Void)?
    ) async throws -> (Data, URLResponse) {
        try await WebDAVMediaSession.data(for: request, log: log)
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
