import Foundation

/// Search trace under `pcld_ios_media/logs/search_debug.txt` (newest lines at top; LAN when served).
enum SearchDebugLog {
    private static let queue = DispatchQueue(label: "com.loopsegments.search-debug")
    private static let maxBytes = 64 * 1024

    static var logURL: URL {
        ExportPaths.searchDebugLogURL
    }

    /// Creates the search debug log at launch (before any search runs).
    static func ensureReady() {
        queue.sync {
            ensureDirectoryLocked()
            guard !FileManager.default.fileExists(atPath: logURL.path) else { return }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            appendLine("Search debug log ready (Loop Segments \(version) build \(build))")
            appendLine("path=\(logURL.path)")
            flushLocked()
        }
    }

    /// Short line for Browse UI (file size on disk).
    static func statusLine() -> String {
        queue.sync {
            let url = logURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                return "search_debug.txt — not on disk yet (search once or reinstall build 82+)"
            }
            let bytes = fileByteCount(url)
            return "\(ExportPaths.pathRelativeToExports(url)) — \(bytes) bytes (LAN only)"
        }
    }

    static func beginSearch(query: String, credentials: WebDAVCredentials, browsePaths: [String]) {
        let tokenPresent = credentials.apiAuthToken?.isEmpty == false
        let root = credentials.webDAVFilesRoot ?? "(none)"
        let host = credentials.apiAuthHost ?? credentials.region.apiHost
        queue.sync {
            ensureDirectoryLocked()
            truncateIfNeeded()
            appendLine("========== search \"\(query)\" ==========")
            appendLine("region=\(credentials.region.rawValue) apiHost=\(host) tokenSaved=\(tokenPresent) webDAVRoot=\(root)")
            appendLine("browsePaths=\(browsePaths.joined(separator: " | "))")
            flushLocked()
        }
    }

    static func log(_ message: String) {
        queue.sync {
            ensureDirectoryLocked()
            appendLine(message)
            flushLocked()
        }
    }

    static func logAPIAttempt(
        host: String,
        parameterStyle: String,
        resultCode: Int,
        entryCount: Int,
        topLevelKeys: [String]
    ) {
        let keys = topLevelKeys.sorted().joined(separator: ",")
        log(
            "api search host=\(host) style=\(parameterStyle) result=\(resultCode) entries=\(entryCount) keys=[\(keys)]"
        )
    }

    static func logResolveSummary(
        inputCount: Int,
        resolvedCount: Int,
        skippedNoHref: Int,
        skippedNotBrowsable: Int,
        webDAVRoot: String?,
        sampleDrops: [String]
    ) {
        let root = webDAVRoot ?? "(none)"
        log(
            "resolve in=\(inputCount) out=\(resolvedCount) skipNoHref=\(skippedNoHref) skipNotVideo=\(skippedNotBrowsable) webDAVRoot=\(root)"
        )
        for line in sampleDrops.prefix(8) {
            log("  drop: \(line)")
        }
    }

    // MARK: - Private

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static var buffer = ""

    private static func appendLine(_ message: String) {
        buffer += "\(isoFormatter.string(from: Date())) \(message)\n"
    }

    private static func ensureDirectoryLocked() {
        let dir = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static func flushLocked() {
        guard let data = buffer.data(using: .utf8), !data.isEmpty else { return }
        let url = logURL
        ensureDirectoryLocked()
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try Data(contentsOf: url)
                try (data + existing).write(to: url, options: .atomic)
            } else {
                try data.write(to: url, options: .atomic)
            }
            buffer = ""
        } catch {
            let note = "\(isoFormatter.string(from: Date())) LOG FLUSH FAILED: \(error.localizedDescription)\n"
            let fallback = (note.data(using: .utf8) ?? Data()) + data
            try? fallback.write(to: url, options: .atomic)
            buffer = ""
        }
    }

    private static func truncateIfNeeded() {
        let url = logURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > maxBytes else { return }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let keep = String(text.prefix(maxBytes / 2))
        try? (keep + "\n… truncated (oldest lines removed) …\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func fileByteCount(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber else { return 0 }
        return n.int64Value
    }
}
