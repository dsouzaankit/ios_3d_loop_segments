import Foundation

/// Append-only export log under `Exports/` (Files + USB).
/// Important: `FileHandle(forWritingTo:)` **truncates** an existing file to 0 bytes — use `forUpdating` + `seekToEnd()`.
final class ExportLogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.loopsegments.export-log")
    private let primaryURL: URL
    private let archiveURL: URL
    private var lineCount = 0
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

        let header = """
        Loop Segments export log
        Started: \(isoFormatter.string(from: Date()))
        File: \(itemName)
        Path: \(href)
        Seek ms: \(seekMs)

        """

        try Self.writeAtomically(Data(header.utf8), to: primaryURL)
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try? FileManager.default.removeItem(at: archiveURL)
        }
        try FileManager.default.copyItem(at: primaryURL, to: archiveURL)
    }

    func log(_ message: String) {
        queue.sync { [self] in
            appendLine(message)
        }
    }

    private func appendLine(_ message: String) {
        let line = "\(isoFormatter.string(from: Date())) \(message)\n"
        do {
            try append(Data(line.utf8), to: primaryURL)
            try append(Data(line.utf8), to: archiveURL)
            lineCount += 1
            try mirrorPrimaryToLegacyNames()
        } catch {
            // Keep export running; finish() still records status
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
            (try? FileManager.default.attributesOfItem(atPath: primaryURL.path)[.size] as? NSNumber)?
                .int64Value ?? 0
        }
    }

    // MARK: - Private

    private func append(_ chunk: Data, to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer {
            try? handle.synchronize()
            try? handle.close()
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: chunk)
    }

    private func mirrorPrimaryToLegacyNames() throws {
        let data = try Data(contentsOf: primaryURL)
        guard !data.isEmpty else { return }
        try Self.writeAtomically(data, to: ExportPaths.latestLogURL)
        let logArchive = archiveURL.deletingPathExtension().appendingPathExtension("log")
        try Self.writeAtomically(data, to: logArchive)
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

enum ExportLogWriterError: LocalizedError {
    case createFailed(URL)

    var errorDescription: String? {
        switch self {
        case .createFailed(let url):
            return "Could not create log file at \(url.lastPathComponent)."
        }
    }
}
