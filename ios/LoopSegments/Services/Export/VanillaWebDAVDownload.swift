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
        fileKey: String,
        sourceHref: String?,
        totalLength: Int64,
        fastStartDestinationURL: URL? = nil,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        isCancelled: @escaping () -> Bool,
        log: @escaping (String) -> Void,
        onDownloadedBytes: ((Int64) -> Void)? = nil
    ) async throws {
        var expectedLength = totalLength
        if expectedLength <= 0 {
            log("Vanilla download — unknown Content-Length; using full GET")
            try await downloadViaFullGET(
                remoteURL: remoteURL,
                destinationURL: destinationURL,
                fileKey: fileKey,
                sourceHref: sourceHref,
                authorization: authorizationProvider(),
                isCancelled: isCancelled,
                log: log,
                onDownloadedBytes: onDownloadedBytes
            )
            return
        }

        let fm = FileManager.default
        let plan = VanillaDownloadResumeCatalog.resumePlan(
            fileKey: fileKey,
            totalLength: expectedLength,
            destinationURL: destinationURL
        )
        var offset: Int64 = 0
        switch plan {
        case .startFresh:
            try WebDAVTempFileDownload.ensureFreeDiskSpace(forBytes: expectedLength)
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            if let fastStartDestinationURL, fm.fileExists(atPath: fastStartDestinationURL.path) {
                try? fm.removeItem(at: fastStartDestinationURL)
            }
            guard fm.createFile(atPath: destinationURL.path, contents: nil) else {
                throw SegmentExporterError.writerSetupFailed
            }
            VanillaDownloadResumeCatalog.save(fileKey: fileKey, totalLength: expectedLength, href: sourceHref)
        case .resume(let partial):
            let remaining = expectedLength - partial
            try WebDAVTempFileDownload.ensureFreeDiskSpace(forBytes: remaining)
            offset = partial
            log(
                "Vanilla download resume — \(formatBytes(offset)) / \(formatBytes(expectedLength)) on disk " +
                    "(same pCloud file; WebDAV continues from next byte; retries logged below)"
            )
            onDownloadedBytes?(offset)
        case .alreadyComplete:
            offset = expectedLength
            log(
                "Vanilla download already on disk — \(formatBytes(expectedLength)) " +
                    "(skipping WebDAV fill; segments / faststart use local copy)"
            )
            onDownloadedBytes?(offset)
        }

        let handle: FileHandle?
        if offset < expectedLength {
            handle = try FileHandle(forWritingTo: destinationURL)
        } else {
            handle = nil
        }
        defer { try? handle?.close() }

        let rel = ExportPaths.pathRelativeToExports(destinationURL)
        if case .startFresh = plan {
            log(
                "Vanilla download — \(rel) (\(formatBytes(expectedLength)), extension preserved; " +
                    "LAN serves \(destinationURL.lastPathComponent) while bytes arrive)"
            )
        }
        if let fastStartDestinationURL {
            log(
                "MP4 faststart sidecar → \(ExportPaths.pathRelativeToExports(fastStartDestinationURL)) " +
                    "(replaces _vanilla_download.* after download when moov was at EOF; skipped when pCloud is pre-faststarted)"
            )
        }

        var lastLoggedPercent = offset > 0 ? Int(offset * 100 / expectedLength) - progressStepPercent : -1
        var lastFaststartPercent = lastLoggedPercent >= 0
            ? (lastLoggedPercent / faststartRefreshStepPercent) * faststartRefreshStepPercent
            : 0
        var skipFaststartSidecar = false
        var lastProgressLog = CFAbsoluteTimeGetCurrent()
        let auth = authorizationProvider()

        while offset < expectedLength {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            let end = min(offset + chunkBytes - 1, expectedLength - 1)
            let chunkLen = Int(end - offset + 1)
            let data: Data
            do {
                data = try await WebDAVTempFileDownload.fetchRemoteRange(
                    remoteURL: remoteURL,
                    authorization: auth,
                    offset: offset,
                    endInclusive: end,
                    log: log
                )
            } catch let error as WebDAVResourceLoaderError {
                if case .httpStatus(let code) = error, code == 404 || code == 416 {
                    let onDisk = (try? fm.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?
                        .int64Value ?? offset
                    if let reconciled = try await reconcileLengthAfterRangeFailure(
                        remoteURL: remoteURL,
                        authorization: auth,
                        onDiskBytes: onDisk,
                        expectedLength: expectedLength,
                        handle: handle,
                        fileKey: fileKey,
                        sourceHref: sourceHref,
                        log: log
                    ) {
                        expectedLength = reconciled
                        offset = (try? fm.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?
                            .int64Value ?? reconciled
                        onDownloadedBytes?(offset)
                        if offset >= expectedLength {
                            break
                        }
                        continue
                    }
                }
                throw error
            }
            guard data.count == chunkLen else {
                if offset == 0 {
                    log(
                        "Range response size mismatch (\(data.count) vs \(chunkLen)) — " +
                            "falling back to full GET (common for external CDNs)"
                    )
                    try? handle?.close()
                    try await downloadViaFullGET(
                        remoteURL: remoteURL,
                        destinationURL: destinationURL,
                        fileKey: fileKey,
                        sourceHref: sourceHref,
                        authorization: auth,
                        isCancelled: isCancelled,
                        log: log,
                        onDownloadedBytes: onDownloadedBytes
                    )
                    return
                }
                throw WebDAVResourceLoaderError.invalidResponse
            }
            try handle?.seek(toOffset: UInt64(offset))
            try handle?.write(contentsOf: data)
            offset = end + 1
            onDownloadedBytes?(offset)

            let pct = Int(offset * 100 / expectedLength)
            let now = CFAbsoluteTimeGetCurrent()
            if pct >= lastLoggedPercent + progressStepPercent || now - lastProgressLog >= 20 {
                lastProgressLog = now
                lastLoggedPercent = (pct / progressStepPercent) * progressStepPercent
                log("Vanilla download \(pct)% — \(formatBytes(offset)) / \(formatBytes(expectedLength))")
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
        try handle?.synchronize()
        VanillaDownloadResumeCatalog.save(fileKey: fileKey, totalLength: expectedLength, href: sourceHref)
        let onDisk = (try? fm.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard onDisk == expectedLength else {
            throw WebDAVResourceLoaderError.invalidResponse
        }
        if let readHandle = try? FileHandle(forReadingFrom: destinationURL) {
            defer { try? readHandle.close() }
            let head = readHandle.readData(ofLength: 12)
            if head.count >= 8 {
                let detected = MediaContainerFormat.from(filename: destinationURL.lastPathComponent, headBytes: head)
                if case .asf = detected {
                    log(
                        "Vanilla WMV/ASF header verified — copy to PC (USB or ranged LAN GET); " +
                            "PotPlayer/VLC; iOS cannot build op_00/op_01 from WMV"
                    )
                } else if case .mp4 = detected {
                    log("Vanilla MP4 header verified")
                }
            }
        }
        if let fastStartDestinationURL {
            let wroteSidecar = try await MP4NetworkOptimize.writeNetworkOptimizedCopy(
                from: destinationURL,
                to: fastStartDestinationURL,
                log: log
            )
            if wroteSidecar {
                ExportPaths.replaceVanillaDownloadWithFaststartSidecar(log: log)
            }
        }
        let completeRel = ExportPaths.pathRelativeToExports(
            FileManager.default.fileExists(atPath: destinationURL.path)
                ? destinationURL
                : (fastStartDestinationURL ?? destinationURL)
        )
        log("Vanilla download complete — \(formatBytes(onDisk)) (\(completeRel))")
    }

    /// Returns reconciled total length when the partial on disk matches pCloud; `nil` to rethrow.
    private static func reconcileLengthAfterRangeFailure(
        remoteURL: URL,
        authorization: String,
        onDiskBytes: Int64,
        expectedLength: Int64,
        handle: FileHandle?,
        fileKey: String,
        sourceHref: String?,
        log: @escaping (String) -> Void
    ) async throws -> Int64? {
        guard onDiskBytes > 0 else { return nil }
        let remoteLength = try await WebDAVPrefetch.fetchRemoteContentLength(
            remoteURL: remoteURL,
            authorization: authorization,
            log: log
        )
        guard remoteLength > 0 else { return nil }

        if remoteLength == onDiskBytes {
            log(
                "Vanilla download — pCloud file is \(formatBytes(remoteLength)) " +
                    "(matches partial on disk; expected \(formatBytes(expectedLength)) was wrong — treating as complete)"
            )
            return remoteLength
        }

        if remoteLength < onDiskBytes {
            try handle?.truncate(atOffset: UInt64(remoteLength))
            log(
                "Vanilla download — pCloud file shrank to \(formatBytes(remoteLength)); " +
                    "truncated local copy from \(formatBytes(onDiskBytes))"
            )
            VanillaDownloadResumeCatalog.save(fileKey: fileKey, totalLength: remoteLength, href: sourceHref)
            return remoteLength
        }

        if remoteLength > onDiskBytes, remoteLength != expectedLength {
            log(
                "Vanilla download — pCloud length is \(formatBytes(remoteLength)) " +
                    "(was \(formatBytes(expectedLength)); resuming from \(formatBytes(onDiskBytes))"
            )
            VanillaDownloadResumeCatalog.save(fileKey: fileKey, totalLength: remoteLength, href: sourceHref)
            return remoteLength
        }

        return nil
    }

    /// When Range is unsupported (CDN returns full body / wrong size), fill destination with one GET.
    private static func downloadViaFullGET(
        remoteURL: URL,
        destinationURL: URL,
        fileKey: String,
        sourceHref: String?,
        authorization: String,
        isCancelled: @escaping () -> Bool,
        log: @escaping (String) -> Void,
        onDownloadedBytes: ((Int64) -> Void)?
    ) async throws {
        if isCancelled() || Task.isCancelled { throw CancellationError() }
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 60 * 60
        WebDAVAuth.applyAuthorization(authorization, to: &request)

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let http = response as? HTTPURLResponse else {
            throw WebDAVResourceLoaderError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw WebDAVResourceLoaderError.httpStatus(http.statusCode)
        }
        if isCancelled() || Task.isCancelled { throw CancellationError() }

        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw WebDAVResourceLoaderError.missingContentLength
        }
        try WebDAVTempFileDownload.ensureFreeDiskSpace(forBytes: size)
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.copyItem(at: tempURL, to: destinationURL)
        VanillaDownloadResumeCatalog.save(fileKey: fileKey, totalLength: size, href: sourceHref)
        onDownloadedBytes?(size)
        log("Vanilla download via full GET — \(formatBytes(size)) → \(destinationURL.lastPathComponent)")
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
