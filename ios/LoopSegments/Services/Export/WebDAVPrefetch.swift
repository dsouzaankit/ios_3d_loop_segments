import Foundation

/// HEAD + index bytes before AVAsset opens the file (avoids ~30s AVFoundation loader timeout).
enum WebDAVPrefetch {
    static func warmUp(
        remoteURL: URL,
        authorization: String,
        cache: WebDAVRangeCache,
        container: MediaContainerFormat,
        catalogContentLength: Int64? = nil,
        headOnly: Bool = false,
        log: ((String) -> Void)? = nil
    ) async throws {
        log?("Prefetch: HEAD (file size) — \(container.displayName)")
        let headLength = try await fetchRemoteContentLength(
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

        if headOnly {
            log?("Prefetch: HEAD only — skipped byte ranges (vanilla-only \(container.displayName))")
            return
        }

        let headPrefixBytes = container.prefetchHeadBytes
        let firstEnd = min(headPrefixBytes, length) - 1
        let tailSuffixBytes = container.prefetchTailBytes
        let tailStart: Int64
        if let tailSuffixBytes {
            let tailLen = min(tailSuffixBytes, length)
            tailStart = max(0, length - tailLen)
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
        } else {
            tailStart = length
            log?("Prefetch: \(container.displayName) — header at file start (no MP4 index at EOF)")
        }

        if firstEnd >= 0 {
            log?("Prefetch: downloading first \(formatBytes(firstEnd + 1)) (\(container.displayName) header)")
            let data = try await fetchRange(
                remoteURL: remoteURL,
                authorization: authorization,
                offset: 0,
                endInclusive: firstEnd,
                log: log
            )
            cache.storeRange(offset: 0, data: data)
        }

        if tailSuffixBytes == nil || tailStart <= firstEnd + 1 {
            log?("Prefetch: complete — \(formatBytes(length)) file, header cached for export")
            return
        }
        log?("Prefetch: complete — \(formatBytes(length)) file, head + index cached for export")
    }

    /// Before streaming a segment window, cache a large MP4 index at EOF (moov-at-end HEVC).
    static func prefetchStreamExportIndex(
        remoteURL: URL,
        authorization: String,
        cache: WebDAVRangeCache,
        fileLength: Int64,
        log: ((String) -> Void)? = nil
    ) async throws {
        guard fileLength > 0 else { return }
        let tailLen = WebDAVTempFileDownload.indexTailFetchBytes(totalLength: fileLength)
        let tailStart = max(0, fileLength - tailLen)
        if tailStart >= fileLength { return }
        log?("Prefetch: MP4 index \(formatBytes(fileLength - tailStart)) at EOF for pCloud stream export")
        let tailData = try await fetchRange(
            remoteURL: remoteURL,
            authorization: authorization,
            offset: tailStart,
            endInclusive: fileLength - 1,
            log: log
        )
        cache.storeRange(offset: tailStart, data: tailData, isIndexTail: true)
        log?("Prefetch: index cached — stream reads are capped to this window + index (not full file)")
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

    /// HEAD (or 1-byte GET) content length for resume reconciliation after range 404/416.
    static func fetchRemoteContentLength(
        remoteURL: URL,
        authorization: String,
        log: ((String) -> Void)? = nil
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
