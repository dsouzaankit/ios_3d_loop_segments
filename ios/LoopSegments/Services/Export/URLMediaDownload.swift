import Foundation

/// HTTP(S) download into `pcld_ios_media/downloads/<saveName>` (LAN-triggered or in-app).
/// Uses a full GET (not Range) — external CDNs often mishandle Range and left 0-byte files.
enum URLMediaDownload {
    private static let minPlayableBytes: Int64 = 1

    enum DownloadError: LocalizedError {
        case invalidURL
        case invalidSaveName
        case httpStatus(Int)
        case emptyFile
        case htmlNotMedia
        case incomplete(expected: Int64, got: Int64)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid download URL"
            case .invalidSaveName: return "Invalid save file name"
            case .httpStatus(let code): return "HTTP \(code)"
            case .emptyFile: return "Download produced an empty file (check the URL returns the media, not a webpage)"
            case .htmlNotMedia: return "URL returned HTML instead of a media file"
            case .incomplete(let expected, let got):
                return "Incomplete download (\(got) / \(expected) bytes)"
            }
        }
    }

    /// Sanitized basename under `downloads/` (no path traversal).
    static func sanitizeSaveFileName(_ raw: String, sourceURL: URL?) -> String? {
        var name = (raw as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/\\:?*%\"<>|\0")
            .union(.newlines)
            .union(.controlCharacters)
        name = name.components(separatedBy: invalid).joined(separator: "_")
        while name.contains("..") {
            name = name.replacingOccurrences(of: "..", with: "_")
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "._ "))
        if name.isEmpty { return nil }

        if name.count > 180 {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            let truncated = String(base.prefix(160))
            name = ext.isEmpty ? truncated : "\(truncated).\(ext)"
        }

        if (name as NSString).pathExtension.isEmpty,
           let sourceURL,
           !sourceURL.pathExtension.isEmpty {
            let ext = sourceURL.pathExtension
            if ext.count <= 12, ext.rangeOfCharacter(from: invalid) == nil {
                name = "\(name).\(ext)"
            }
        }
        return name
    }

    static func destinationURL(saveName: String) -> URL {
        ExportPaths.ensureDownloadsDirectory()
        return ExportPaths.downloadsDirectory.appendingPathComponent(saveName, isDirectory: false)
    }

    /// Downloads `remoteURL` to `pcld_ios_media/downloads/<saveName>`. Overwrites existing file.
    @discardableResult
    static func download(
        remoteURL: URL,
        saveName: String,
        isCancelled: @escaping () -> Bool,
        log: @escaping (String) -> Void
    ) async throws -> URL {
        guard let safeName = sanitizeSaveFileName(saveName, sourceURL: remoteURL) else {
            throw DownloadError.invalidSaveName
        }
        guard remoteURL.scheme == "http" || remoteURL.scheme == "https" else {
            throw DownloadError.invalidURL
        }

        let destination = destinationURL(saveName: safeName)
        let rel = ExportPaths.pathRelativeToExports(destination)
        log("URL download — \(remoteURL.absoluteString) → \(rel)")

        do {
            try await downloadWholeFile(
                remoteURL: remoteURL,
                destinationURL: destination,
                isCancelled: isCancelled,
                log: log
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        let size = fileSize(at: destination)
        guard size >= minPlayableBytes else {
            try? FileManager.default.removeItem(at: destination)
            throw DownloadError.emptyFile
        }
        log("URL download complete — \(rel) (\(formatBytes(size)))")
        return destination
    }

    private static func downloadWholeFile(
        remoteURL: URL,
        destinationURL: URL,
        isCancelled: @escaping () -> Bool,
        log: @escaping (String) -> Void
    ) async throws {
        if isCancelled() || Task.isCancelled { throw CancellationError() }

        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 60 * 60
        applyURLCredentials(to: &request, from: remoteURL)

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.httpStatus(-1)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw DownloadError.httpStatus(http.statusCode)
        }
        if let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           contentType.contains("text/html") {
            throw DownloadError.htmlNotMedia
        }
        if isCancelled() || Task.isCancelled {
            throw CancellationError()
        }

        let fm = FileManager.default
        let tempSize = fileSize(at: tempURL)
        guard tempSize >= minPlayableBytes else {
            throw DownloadError.emptyFile
        }
        if let expected = contentLength(from: http), expected > 0, tempSize < expected {
            throw DownloadError.incomplete(expected: expected, got: tempSize)
        }

        try WebDAVTempFileDownload.ensureFreeDiskSpace(forBytes: tempSize)
        ExportPaths.ensureDownloadsDirectory()
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.copyItem(at: tempURL, to: destinationURL)
        log(
            "URL download — GET \(http.statusCode) finished → \(destinationURL.lastPathComponent) " +
                "(\(formatBytes(tempSize)))"
        )
    }

    private static func contentLength(from http: HTTPURLResponse) -> Int64? {
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap({ Int64($0) }), length > 0 {
            return length
        }
        return nil
    }

    private static func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func applyURLCredentials(to request: inout URLRequest, from url: URL) {
        guard let user = url.user, let password = url.password else { return }
        let token = Data("\(user):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
        }
        if bytes >= 1024 * 1024 {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
        }
        return "\(bytes) B"
    }
}
