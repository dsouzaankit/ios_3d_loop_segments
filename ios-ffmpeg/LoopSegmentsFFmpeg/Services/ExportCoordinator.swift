import Foundation

final class ExportCoordinator {
    /// Lazy so FFmpeg xcframeworks are not loaded at app launch (iOS 26 crash mitigation).
    private lazy var ffmpeg = FFmpegRunner()
    private let lock = NSLock()
    private var active = false
    var userRequestedCancel = false

    func cancel() {
        ffmpeg.cancel()
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

        logHandler("Export started (FFmpeg stream copy)")
        logHandler("Logs: export_latest.txt, \(logWriter.sessionLogFileName), export_progress.txt (in Exports)")
        logHandler("pCloud region: \(credentials.region.displayName) (\(credentials.region.webDAVHost))")
        logHandler("Media URL: \(inputURL.absoluteString)")

        let authProvider = WebDAVAuth.provider(fallback: credentials)
        logHandler("Verifying file access (HEAD)…")
        try await WebDAVAccessProbe.verifyMediaURL(inputURL, authorization: authProvider, log: logHandler)

        if PhotosSegmentPublisher.isEnabled {
            logHandler("Requesting Photos access…")
            if await PhotosSegmentPublisher.ensureAccess(log: logHandler) {
                logHandler("Photos access granted — segments sync after export")
            } else {
                logHandler("Photos: export will write to Exports only until access is allowed")
            }
        }

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try await self.ffmpeg.run(
                    inputURL: inputURL,
                    seekMs: seekMs,
                    authorizationHeader: credentials.authorizationHeaderValue,
                    logHandler: logHandler
                )
                return SegmentExportResult(lastMediaTimeMs: seekMs, reachedEnd: true)
            }.value

            logHandler("Export finished — 3d_op_*.mp4 in Exports")
            if PhotosSegmentPublisher.isEnabled {
                logHandler("Photos: syncing finished segments to library…")
                await PhotosSegmentPublisher.publishAllSegmentsFromExports(log: logHandler)
            }
            logWriter.finish(status: result.reachedEnd ? "completed" : "stopped")
            return result
        } catch FFmpegRunnerError.cancelled {
            if userRequestedCancel {
                await SegmentCleanup.removeAllSegments(log: logHandler)
                logHandler("Cleanup: removed 3d_op_*.mp4 from Exports")
                logWriter.finish(status: "cancelled")
                throw FFmpegRunnerError.cancelled
            }
            logHandler("FFmpeg interrupted (not Stop) — try seek 0 min or Wi‑Fi")
            logWriter.finish(status: "interrupted", error: FFmpegRunnerError.cancelled)
            throw FFmpegRunnerError.cancelled
        } catch {
            logHandler("Export failed — partial segment files may remain in Exports")
            logWriter.finish(status: "failed", error: error)
            throw error
        }
    }
}
