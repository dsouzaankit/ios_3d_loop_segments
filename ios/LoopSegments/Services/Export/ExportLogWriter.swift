import Foundation

/// Append-only export log under `Exports/`. Rewrites whole file atomically each line so USB/Files always see a complete snapshot.
final class ExportLogWriter: @unchecked Sendable {
    private static let progressLineCount = 12

    private let queue = DispatchQueue(label: "com.loopsegments.export-log")
    private let primaryURL: URL
    private let archiveURL: URL
    private let sessionURL: URL
    private let progressURL: URL
    private var text: String
    private var lastFlushError: String?
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(itemName: String, seekMs: Int64, href: String) throws {
        ExportPaths.ensureExportDirectories()
        let stamp = Int(Date().timeIntervalSince1970)
        primaryURL = ExportPaths.latestLogTextURL
        archiveURL = ExportPaths.logsDirectory.appendingPathComponent("export_\(stamp).txt")
        sessionURL = ExportPaths.exportsDirectory.appendingPathComponent("export_session_\(stamp).txt")
        progressURL = ExportPaths.exportProgressURL

        text = """
        Loop Segments export log
        Started: \(isoFormatter.string(from: Date()))
        File: \(itemName)
        Path: \(href)
        Seek ms: \(seekMs)

        """

        try queue.sync {
            try flushLocked()
        }
    }

    func log(_ message: String) {
        queue.sync {
            appendLine(message)
        }
    }

    func finish(status: String, error: Error? = nil) {
        queue.sync {
            if let error {
                appendLine("ERROR: \(error.localizedDescription)")
            }
            appendLine("--- \(status) ---")
        }
    }

    var primaryFileByteCount: Int64 {
        queue.sync {
            Int64(text.utf8.count)
        }
    }

    func tailText(maxLines: Int = 6) -> String {
        queue.sync {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            return lines.suffix(maxLines).joined(separator: "\n")
        }
    }

    var sessionLogFileName: String {
        sessionURL.lastPathComponent
    }

    // MARK: - Private

    private func appendLine(_ message: String) {
        text += "\(isoFormatter.string(from: Date())) \(message)\n"
        do {
            try flushLocked()
        } catch {
            lastFlushError = error.localizedDescription
            text += "\(isoFormatter.string(from: Date())) LOG FLUSH FAILED: \(error.localizedDescription)\n"
            try? flushLocked()
        }
    }

    private func flushLocked() throws {
        let data = Data(text.utf8)
        guard !data.isEmpty else { return }

        try Self.writeAtomically(data, to: primaryURL)
        try Self.writeAtomically(data, to: archiveURL)
        try Self.writeAtomically(data, to: sessionURL)
        try Self.writeAtomically(data, to: ExportPaths.latestLogURL)

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if !lines.isEmpty {
            // PC sync often only copies this file — keep last N lines so Prefetch is still visible after Download updates.
            let progress = lines.suffix(Self.progressLineCount).joined(separator: "\n") + "\n"
            try progress.write(to: progressURL, atomically: true, encoding: .utf8)
        }

        let logArchive = archiveURL.deletingPathExtension().appendingPathExtension("log")
        try Self.writeAtomically(data, to: logArchive)
        lastFlushError = nil
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}
