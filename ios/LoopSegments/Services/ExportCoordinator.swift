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

        var archivedPriorMediaFiles = 0
        let priorRetentionSource = ExportRetentionSourceCatalog.read()?.sourceFileName
        let skipRetentionArchive = !ExportMediaArchive.shouldArchivePriorMediaBeforeNewExport(
            continueLANExport: continueLANExport,
            item: item
        )
        if !skipRetentionArchive, ExportMediaArchive.hasActiveExportMediaOnDisk() {
            let timestamp = ExportMediaArchive.newRetentionTimestamp()
            archivedPriorMediaFiles = ExportMediaArchive.archiveActiveMedia(
                timestamp: timestamp,
                sourceFileName: priorRetentionSource
            )
            if archivedPriorMediaFiles > 0 {
                _ = ExportMediaArchive.pruneRetainedMedia(keepCount: ExportMediaArchive.retentionCount)
            }
        }
        ExportRetentionSourceCatalog.save(sourceFileName: item.name, fileKey: item.fileKey)

        if continueLANExport {
            ExportPaths.ensureExportDirectories()
        } else {
            ExportPaths.clearLogsForNewExport()
        }
        let logWriter = try ExportLogWriter(
            itemName: item.name,
            seekMs: seekMs,
            href: item.href,
            appendResumeMarker: continueLANExport
        )

        let logHandler: (String) -> Void = { line in
            logWriter.log(line)
        }
        ExportRuntimeLog.setMirror(logHandler)
        defer { ExportRuntimeLog.setMirror(nil) }

        BackgroundTaskKeeper.begin()
        defer { BackgroundTaskKeeper.end() }

        ExportLANServer.ensureRunning(log: logHandler)

        if continueLANExport {
            logHandler("Export resumed — kept pcld_ios_media media and checkpoint on disk")
        } else if skipRetentionArchive, ExportMediaArchive.hasActiveExportMediaOnDisk() {
            logHandler(
                "Export started — kept pcld_ios_media/ as-is (LAN resume; same checkpoint and on-disk media)"
            )
        } else if archivedPriorMediaFiles > 0 {
            logHandler(
                "Export started — archived \(archivedPriorMediaFiles) prior file(s) to pcld_ios_media/archive/ " +
                    "(pCloud basename[_3D_<n>K]_<local-time>; keeping last \(ExportMediaArchive.retentionCount) batches; loop/ ignored)"
            )
        } else {
            logHandler(
                "Export started — cleared export_latest.txt / export_progress.txt " +
                    "(kept logs/export_*.txt history, last \(ExportPaths.exportLogRetentionCount) runs)"
            )
        }
        logHandler(
            "Logs: export_latest.txt (live), \(logWriter.historyLogFileName) (this run, kept), export_progress.txt"
        )
        logHandler("pCloud region: \(credentials.region.displayName) (\(credentials.region.webDAVHost))")
        let authProvider = WebDAVAuth.provider(fallback: credentials)
        logHandler("Verifying file access (HEAD)…")
        let (resolvedURL, resolvedItem) = try await WebDAVAccessProbe.resolveMediaURL(
            for: item,
            credentials: credentials,
            authorization: authProvider,
            log: logHandler
        )
        logHandler("Media URL: \(resolvedURL.absoluteString)")
        if resolvedItem.fileKey != item.fileKey || resolvedItem.href != item.href {
            logHandler("pCloud path updated after rename — exporting \(resolvedItem.name)")
        }

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
                        item: resolvedItem,
                        inputURL: resolvedURL,
                        credentials: credentials,
                        catalogContentLength: resolvedItem.contentLength,
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
            if result.reachedEnd {
                WorkingSourceSparseCatalog.clearLANPlaybackStartHintAfterExportFinished(
                    fileURL: ExportPaths.workingSourceURL
                )
            }
            let archivedOnFinish = SegmentCleanup.archiveFinishedExportMedia(log: logHandler)
            if result.lanPreloadOnly {
                if archivedOnFinish > 0 {
                    logHandler(
                        "LAN preload finished — copied \(archivedOnFinish) file(s) to pcld_ios_media/archive/ " +
                            "(root _working* / _vanilla_* kept on LAN; no op_*.mp4)"
                    )
                } else {
                    logHandler(
                        "LAN preload finished — no root media to archive (no op_*.mp4; below bitrate cutoff)"
                    )
                }
            } else if archivedOnFinish > 0 {
                logHandler(
                    "Export finished — copied \(archivedOnFinish) root file(s) to pcld_ios_media/archive/ " +
                        "(root media left on LAN; loop/op_*.mp4 kept; " +
                        "last \(ExportMediaArchive.retentionCount) archive batches)"
                )
            } else {
                logHandler("Export finished — loop/op_*.mp4 on LAN (no root media to archive)")
            }
            logHandler(ExportPaths.describeExportMediaOnDisk())
            logHandler("Logs: http://<phone-ip>:8765/pcld_ios_media/logs/export_latest.txt (or legacy /export_latest.txt)")
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
        } catch SegmentExporterError.cancelled, is CancellationError {
            if userRequestedPause {
                logHandler("Export paused — checkpoint saved; pcld_ios_media/loop/op_*.mp4 and _working.mp4 kept on device")
                logWriter.finish(status: "paused")
                throw SegmentExporterError.paused
            }
            if userRequestedCancel {
                await SegmentCleanup.performStopCleanup(log: logHandler)
                logWriter.finish(status: "cancelled")
                throw SegmentExporterError.cancelled
            }
            logHandler(
                "Export interrupted (not Stop) — Wi‑Fi / reader cancelled mid-run; " +
                    "if this was not intentional, enable Keep Alive, stay on Wi‑Fi, then Start export to resume"
            )
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
