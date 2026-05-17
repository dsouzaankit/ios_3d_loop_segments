import Foundation

final class ExportCoordinator {
    private let ffmpeg = FFmpegRunner()
    private let lock = NSLock()
    private var active = false

    func cancel() {
        ffmpeg.cancel()
    }

    func run(
        item: WebDAVItem,
        credentials: WebDAVCredentials,
        seekMs: Int64
    ) async throws {
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
        let logURL = ExportPaths.logsDirectory
            .appendingPathComponent("export_\(Int(Date().timeIntervalSince1970)).log")

        var logLines: [String] = []
        let logHandler: (String) -> Void = { line in
            logLines.append(line)
            if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
        }

        BackgroundTaskKeeper.begin()
        defer { BackgroundTaskKeeper.end() }

        do {
            try await ffmpeg.run(
                inputURL: inputURL,
                seekMs: seekMs,
                authorizationHeader: credentials.authorizationHeaderValue,
                logHandler: logHandler
            )
        } catch {
            try? String(logLines.joined(separator: "\n")).write(
                to: logURL,
                atomically: true,
                encoding: .utf8
            )
            throw error
        }

        try? String(logLines.joined(separator: "\n")).write(
            to: logURL,
            atomically: true,
            encoding: .utf8
        )
    }
}
