import Foundation

final class ExportCoordinator {
    private let exporter = SegmentExporter()
    private let lock = NSLock()
    private var active = false
    var userRequestedCancel = false
    var userRequestedPause = false

    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func cancel() {
        exporter.cancel()
    }

    func run(
        item: WebDAVItem,
        credentials: WebDAVCredentials,
        seekMs: Int64,
        continueLANExport: Bool = false,
        resumeCursorMs: Int64? = nil,
        onMediaProgress: (@Sendable (Int64) -> Void)? = nil
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
        ExportPaths.clearLogsForNewExport()
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

        ExportLANServer.ensureRunning(log: logHandler)

        logHandler("Export started — cleared prior export_latest.txt / export_progress.txt / old session logs")
        logHandler("Logs: export_latest.txt, \(logWriter.sessionLogFileName), export_progress.txt (in Exports)")
        logHandler("pCloud region: \(credentials.region.displayName) (\(credentials.region.webDAVHost))")
        logHandler("Media URL: \(inputURL.absoluteString)")

        let authProvider = WebDAVAuth.provider(fallback: credentials)
        logHandler("Verifying file access (HEAD)…")
        try await WebDAVAccessProbe.verifyMediaURL(inputURL, authorization: authProvider, log: logHandler)

        if PhotosSegmentPublisher.isEnabled {
            logHandler("Requesting Photos access…")
            if await PhotosSegmentPublisher.ensureAccess(log: logHandler) {
                logHandler("Photos access granted — each 60s chunk saves to Photos library")
            } else {
                logHandler("Photos: export will write to Exports only until access is allowed")
            }
        }

        do {
            // Export must not run on @MainActor — AVAssetReader + resource loader deadlock/crash the UI thread.
            let result = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try await self.exporter.run(
                        item: item,
                        inputURL: inputURL,
                        credentials: credentials,
                        catalogContentLength: item.contentLength,
                        seekMs: seekMs,
                        continueLANExport: continueLANExport,
                        resumeCursorMs: resumeCursorMs,
                        authorizationProvider: authProvider,
                        logHandler: logHandler,
                        onMediaProgress: onMediaProgress
                    )
                }.value
            } onCancel: {
                self.exporter.cancel()
            }
            if result.lanPreloadOnly {
                logHandler(
                    "LAN preload finished — pcld_ios_media/_working.mp4 on disk (no op_*.mp4; below bitrate cutoff). Play via :8765"
                )
            } else {
                if ExportPlaybackState.shared.usesPCloudTranscodedWorkingForLAN()
                    || FileManager.default.fileExists(atPath: ExportPaths.workingTranscodedURL.path) {
                    logHandler(
                        "Export finished — pcld_ios_media/loop/op_*.mp4 and " +
                            "pcld_ios_media/_working_pcloud_transcode.mp4 (pCloud transcode) kept until next export or Clear media"
                    )
                } else {
                    logHandler("Export finished — pcld_ios_media/loop/op_*.mp4 and pcld_ios_media/_working.mp4 kept until next export or Clear media")
                }
            }
            logHandler(ExportPaths.describeExportMediaOnDisk())
            logHandler("Files: On My iPhone → Loop Segments → Exports (same folder as export_latest.txt)")
            if PhotosSegmentPublisher.isEnabled, !result.lanPreloadOnly {
                logHandler("Photos: syncing finished segments to library…")
                await PhotosSegmentPublisher.publishAllSegmentsFromExports(log: logHandler)
            }
            if result.skippedSegmentCount > 0 {
                let suffix = result.reachedEnd ? "end of file" : "stopped"
                logHandler(
                    "Failsafe: \(result.skippedSegmentCount) minute(s) skipped; " +
                        "\(suffix); partial op_*.mp4 on LAN/USB"
                )
                logWriter.finish(
                    status: result.reachedEnd
                        ? "completed (\(result.skippedSegmentCount) minutes skipped)"
                        : "stopped (\(result.skippedSegmentCount) minutes skipped)"
                )
            } else {
                logWriter.finish(status: result.reachedEnd ? "completed (end of file)" : "stopped")
            }
            return result
        } catch SegmentExporterError.cancelled {
            if userRequestedPause {
                logHandler("Export paused — checkpoint saved; pcld_ios_media/loop/op_*.mp4 and _working.mp4 kept on device")
                logWriter.finish(status: "paused")
                throw SegmentExporterError.paused
            }
            if userRequestedCancel {
                await SegmentCleanup.removeAllSegments(log: logHandler)
                logHandler("Cleanup: removed pcld_ios_media/loop/op_*.mp4 from Exports (_working.mp4 kept until next export)")
                logWriter.finish(status: "cancelled")
                throw SegmentExporterError.cancelled
            }
            logHandler("Export interrupted by media reader (not Stop) — try seek 0 min or Wi‑Fi")
            logWriter.finish(status: "interrupted", error: SegmentExporterError.cancelled)
            throw SegmentExporterError.readerInterrupted
        } catch {
            logHandler("Export failed — partial segment files kept for USB/Photos sync")
            logHandler(ExportPaths.describeExportMediaOnDisk())
            logWriter.finish(status: "failed", error: error)
            throw error
        }
    }
}
