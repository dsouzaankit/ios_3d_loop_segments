import Foundation

/// Downloads the full remote MP4 to app storage so `AVAssetReader` uses `file://` (no custom loader / jetsam).
enum WebDAVSourceSpooler {
    private static let chunkBytes: Int64 = 1024 * 1024
    private static let progressStepPercent = 5

    static func spool(
        remoteURL: URL,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        rangeCache: WebDAVRangeCache,
        isCancelled: @escaping () -> Bool,
        log: @escaping (String) -> Void
    ) async throws -> URL {
        guard let total = rangeCache.contentLengthValue(), total > 0 else {
            throw WebDAVResourceLoaderError.missingContentLength
        }

        try ensureFreeDiskSpace(forBytes: total)

        let dest = ExportPaths.workingSourceURL
        try? FileManager.default.removeItem(at: dest)
        guard FileManager.default.createFile(atPath: dest.path, contents: nil) else {
            throw SegmentExporterError.writerSetupFailed
        }

        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }

        log("Step 1/2: copy \(formatBytes(total)) from pCloud to local storage (need ~\(formatBytes(total)) free)…")
        log("Keeps app open — export starts after copy finishes")

        var offset: Int64 = 0
        var lastLoggedPercent = -progressStepPercent

        while offset < total {
            if isCancelled() { throw SegmentExporterError.cancelled }

            let end = min(offset + chunkBytes - 1, total - 1)
            let length = Int(end - offset + 1)

            let data: Data
            if let cached = rangeCache.dataForRequest(offset: offset, length: length) {
                data = cached
            } else {
                let auth = authorizationProvider()
                data = try await fetchRange(
                    remoteURL: remoteURL,
                    authorization: auth,
                    offset: offset,
                    endInclusive: end,
                    log: nil
                )
            }

            guard data.count == length else {
                throw WebDAVResourceLoaderError.invalidResponse
            }
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
            offset = end + 1

            let percent = Int(offset * 100 / total)
            if percent >= lastLoggedPercent + progressStepPercent || offset >= total {
                lastLoggedPercent = (percent / progressStepPercent) * progressStepPercent
                log("Copy \(percent)% — \(formatBytes(offset)) / \(formatBytes(total))")
            }

            await Task.yield()
        }

        log("Step 2/2: local copy ready — segment export (~1× realtime)")
        return dest
    }

    private static func ensureFreeDiskSpace(forBytes needed: Int64) throws {
        let path = ExportPaths.exportsDirectory.path
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let freeNumber = attrs[.systemFreeSize] as? NSNumber else {
            return
        }
        let free = freeNumber.int64Value
        let margin: Int64 = 64 * 1024 * 1024
        if free < needed + margin {
            throw SegmentExporterError.insufficientDiskSpace(needed: needed, available: max(0, free))
        }
    }

    private static func fetchRange(
        remoteURL: URL,
        authorization: String,
        offset: Int64,
        endInclusive: Int64,
        log: ((String) -> Void)?
    ) async throws -> Data {
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("bytes=\(offset)-\(endInclusive)", forHTTPHeaderField: "Range")

        let (data, response) = try await WebDAVMediaSession.data(for: request, log: log)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVResourceLoaderError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) || http.statusCode == 206 else {
            throw WebDAVResourceLoaderError.httpStatus(http.statusCode)
        }
        return data
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
        }
        if bytes >= 1024 * 1024 {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
        }
        return "\(bytes) B"
    }
}
