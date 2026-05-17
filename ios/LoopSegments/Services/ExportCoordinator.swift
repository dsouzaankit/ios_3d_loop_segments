import Foundation

final class ExportCoordinator {
    private let exporter = SegmentExporter()
    private let lock = NSLock()
    private var active = false

    func cancel() {
        exporter.cancel()
    }

    func run(
        item: WebDAVItem,
        credentials: WebDAVCredentials,
        seekMs: Int64
    ) async throws -> SegmentExportResult {
        lock.lock()
        guard !active else {
            lock.unlock()
            throw ExportError.jobAlreadyActive
        }
        active = true
        lock.unlock()
        defer {
            lock.lock()
            active = false
            lock.unlock()
        }

        let inputURL = item.mediaURL(credentials: credentials)
        let logWriter = try ExportLogWriter(
            itemName: item.name,
            seekMs: seekMs,
            href: item.href
        )

        let logHandler: (String) -> Void = { line in
            logWriter.log(line)
        }

        BackgroundTaskKeeper.begin()
        defer { BackgroundTaskKeeper.end() }

        logHandler("Export started")
        logHandler("Logs: export_latest.txt, \(logWriter.sessionLogFileName), export_progress.txt (in Exports)")
        logHandler("pCloud region: \(credentials.region.displayName) (\(credentials.region.webDAVHost))")
        logHandler("Media URL: \(inputURL.absoluteString)")

        let authProvider = WebDAVAuth.provider(fallback: credentials)
        logHandler("Verifying file access (HEAD)…")
        try await WebDAVAccessProbe.verifyMediaURL(inputURL, authorization: authProvider, log: logHandler)

        if PhotosSegmentPublisher.isEnabled {
            logHandler("Requesting Photos access…")
            if await PhotosSegmentPublisher.ensureAccess(log: logHandler) {
                logHandler("Photos access granted")
            } else {
                logHandler("Photos: export will write to Exports only until access is allowed")
            }
        }

        do {
            let result = try await exporter.run(
                inputURL: inputURL,
                seekMs: seekMs,
                authorizationProvider: authProvider,
                logHandler: logHandler
            )
            logHandler("Export finished — segment files kept for USB/Photos sync (removed on Stop or when app backgrounds)")
            logWriter.finish(status: result.reachedEnd ? "completed (end of file)" : "stopped")
            return result
        } catch SegmentExporterError.cancelled {
            await SegmentCleanup.removeAllSegments(log: logHandler)
            logHandler("Cleanup: removed segment files after Stop")
            logWriter.finish(status: "cancelled")
            throw SegmentExporterError.cancelled
        } catch {
            logHandler("Export failed — partial segment files kept for USB/Photos sync")
            logWriter.finish(status: "failed", error: error)
            throw error
        }
    }
}
