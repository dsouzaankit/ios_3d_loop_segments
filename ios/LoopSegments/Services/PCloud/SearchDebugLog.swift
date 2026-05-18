import Foundation

/// Append-only search trace under `Exports/search_debug.txt` (USB / Files on device).
enum SearchDebugLog {
    private static let queue = DispatchQueue(label: "com.loopsegments.search-debug")
    private static let maxBytes = 256 * 1024

    static var logURL: URL {
        ExportPaths.exportsDirectory.appendingPathComponent("search_debug.txt")
    }

    static func beginSearch(query: String, credentials: WebDAVCredentials, browsePaths: [String]) {
        let tokenPresent = credentials.apiAuthToken?.isEmpty == false
        let root = credentials.webDAVFilesRoot ?? "(none)"
        let host = credentials.apiAuthHost ?? credentials.region.apiHost
        queue.sync {
            truncateIfNeeded()
            appendLine("========== search \"\(query)\" ==========")
            appendLine("region=\(credentials.region.rawValue) apiHost=\(host) tokenSaved=\(tokenPresent) webDAVRoot=\(root)")
            appendLine("browsePaths=\(browsePaths.joined(separator: " | "))")
            flushLocked()
        }
    }

    static func log(_ message: String) {
        queue.sync {
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

    private static func flushLocked() {
        guard let data = buffer.data(using: .utf8) else { return }
        let url = logURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
        buffer = ""
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
        let keep = String(text.suffix(maxBytes / 2))
        try? ("… truncated …\n" + keep).write(to: url, atomically: true, encoding: .utf8)
    }
}
