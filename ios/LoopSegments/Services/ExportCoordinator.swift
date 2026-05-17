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

        do {
            let result = try await exporter.run(
                inputURL: inputURL,
                seekMs: seekMs,
                authorizationHeader: credentials.authorizationHeaderValue,
                logHandler: logHandler
            )
            logWriter.finish(status: result.reachedEnd ? "completed (end of file)" : "stopped")
            return result
        } catch {
            logWriter.finish(status: "failed", error: error)
            throw error
        }
    }
}
