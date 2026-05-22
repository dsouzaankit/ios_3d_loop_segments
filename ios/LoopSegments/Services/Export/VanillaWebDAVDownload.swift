import Foundation

/// Full sequential WebDAV download (dense file, original extension) — backup when sparse probe / HLS fail.
enum VanillaWebDAVDownload {
    private static let enabledKey = "vanillaDownloadBackupEnabled"
    private static let chunkBytes: Int64 = 2 * 1024 * 1024
    private static let progressStepPercent = 5
    private static let faststartRefreshStepPercent = 25

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
        totalLength: Int64,
        fastStartDestinationURL: URL? = nil,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        isCancelled: @escaping () -> Bool,
        log: @escaping (String) -> Void
    ) async throws {
        guard totalLength > 0 else {
            throw WebDAVResourceLoaderError.missingContentLength
        }
        try WebDAVTempFileDownload.ensureFreeDiskSpace(forBytes: totalLength)

        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        if let fastStartDestinationURL, fm.fileExists(atPath: fastStartDestinationURL.path) {
            try? fm.removeItem(at: fastStartDestinationURL)
        }
        guard fm.createFile(atPath: destinationURL.path, contents: nil) else {
            throw SegmentExporterError.writerSetupFailed
        }
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        let rel = ExportPaths.pathRelativeToExports(destinationURL)
        log(
            "Vanilla download — \(rel) (\(formatBytes(totalLength)), extension preserved; " +
                "LAN serves \(destinationURL.lastPathComponent) while bytes arrive)"
        )
        if let fastStartDestinationURL {
            log(
                "MP4 faststart sidecar → \(ExportPaths.pathRelativeToExports(fastStartDestinationURL)) " +
                    "only if download lacks moov-at-head (skipped when pCloud source is pre-faststarted)"
            )
        }

        var offset: Int64 = 0
        var lastLoggedPercent = -1
        var lastFaststartPercent = 0
        var skipFaststartSidecar = false
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
            if let fastStartDestinationURL,
               !skipFaststartSidecar,
               pct >= lastFaststartPercent + faststartRefreshStepPercent {
                lastFaststartPercent = (pct / faststartRefreshStepPercent) * faststartRefreshStepPercent
                if await refreshFaststartCopyIfPossible(
                    from: destinationURL,
                    to: fastStartDestinationURL,
                    downloadedBytes: offset,
                    log: log
                ) == false,
                   MP4NetworkOptimize.sourceAlreadyNetworkOptimized(at: destinationURL) {
                    skipFaststartSidecar = true
                }
            }
        }
        try handle.synchronize()
        let onDisk = (try? fm.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard onDisk == totalLength else {
            throw WebDAVResourceLoaderError.invalidResponse
        }
        if let fastStartDestinationURL {
            _ = try await MP4NetworkOptimize.writeNetworkOptimizedCopy(
                from: destinationURL,
                to: fastStartDestinationURL,
                log: log
            )
        }
        log("Vanilla download complete — \(formatBytes(onDisk)) at \(rel)")
    }

    /// `true` when a sidecar was written/updated; `false` when source is already faststart.
    @discardableResult
    private static func refreshFaststartCopyIfPossible(
        from sourceURL: URL,
        to destinationURL: URL,
        downloadedBytes: Int64,
        log: @escaping (String) -> Void
    ) async -> Bool {
        guard downloadedBytes > 8 * 1024 * 1024 else { return false }
        if MP4NetworkOptimize.sourceAlreadyNetworkOptimized(at: sourceURL) {
            return false
        }
        do {
            return try await MP4NetworkOptimize.writeNetworkOptimizedCopy(
                from: sourceURL,
                to: destinationURL,
                log: log
            )
        } catch {
            log(
                "Faststart refresh skipped at \(formatBytes(downloadedBytes)) — " +
                    "\(error.localizedDescription)"
            )
            return false
        }
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
