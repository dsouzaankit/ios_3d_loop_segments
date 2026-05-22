import Foundation

/// Full sequential WebDAV download (dense file, original extension) — backup when sparse probe / HLS fail.
enum VanillaWebDAVDownload {
    private static let enabledKey = "vanillaDownloadBackupEnabled"
    private static let chunkBytes: Int64 = 2 * 1024 * 1024
    private static let progressStepPercent = 5

    static var isBackupEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func downloadFullFile(
        remoteURL: URL,
        destinationURL: URL,
        sourceFilename: String,
        totalLength: Int64,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        isCancelled: @escaping () -> Bool,
        log: @escaping (String) -> Void
    ) async throws {
        guard totalLength > 0 else {
            throw WebDAVResourceLoaderError.missingContentLength
        }
        try WebDAVTempFileDownload.ensureFreeDiskSpace(forBytes: totalLength)

        let fm = FileManager.default
        let inProgressURL = ExportPaths.vanillaDownloadInProgressURL(
            preservingExtensionFrom: sourceFilename
        )
        for url in [destinationURL, inProgressURL] {
            if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        }
        guard fm.createFile(atPath: inProgressURL.path, contents: nil) else {
            throw SegmentExporterError.writerSetupFailed
        }
        let handle = try FileHandle(forWritingTo: inProgressURL)
        defer { try? handle.close() }

        log(
            "Vanilla download — \(ExportPaths.pathRelativeToExports(inProgressURL)) " +
                "(hidden on LAN until complete → \(destinationURL.lastPathComponent), " +
                "\(formatBytes(totalLength)))"
        )

        var offset: Int64 = 0
        var lastLoggedPercent = -1
        var lastProgressLog = CFAbsoluteTimeGetCurrent()
        let auth = authorizationProvider()

        while offset < totalLength {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            let end = min(offset + chunkBytes - 1, totalLength - 1)
            let chunkLen = Int(end - offset + 1)
            let data = try await WebDAVTempFileDownload.fetchRemoteRange(
                remoteURL: remoteURL,
                authorization: auth,
                offset: offset,
                endInclusive: end
            )
            guard data.count == chunkLen else {
                throw WebDAVResourceLoaderError.invalidResponse
            }
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
            offset = end + 1

            let pct = Int(offset * 100 / totalLength)
            let now = CFAbsoluteTimeGetCurrent()
            if pct >= lastLoggedPercent + progressStepPercent || now - lastProgressLog >= 20 {
                lastProgressLog = now
                lastLoggedPercent = (pct / progressStepPercent) * progressStepPercent
                log("Vanilla download \(pct)% — \(formatBytes(offset)) / \(formatBytes(totalLength))")
            }
        }
        try handle.synchronize()
        let onDisk = (try? fm.attributesOfItem(atPath: inProgressURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard onDisk == totalLength else {
            try? fm.removeItem(at: inProgressURL)
            throw WebDAVResourceLoaderError.invalidResponse
        }
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.moveItem(at: inProgressURL, to: destinationURL)
        log("Vanilla download complete — \(formatBytes(onDisk)) at \(ExportPaths.pathRelativeToExports(destinationURL))")
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
