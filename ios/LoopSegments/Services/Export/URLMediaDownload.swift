import Foundation

/// HTTP(S) download into `pcld_ios_media/downloads/<saveName>` (LAN-triggered or in-app).
enum URLMediaDownload {
    private static let chunkBytes: Int64 = 2 * 1024 * 1024
    private static let progressStepPercent = 5

    enum DownloadError: LocalizedError {
        case invalidURL
        case invalidSaveName
        case missingContentLength
        case httpStatus(Int)
        case incomplete(expected: Int64, got: Int64)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid download URL"
            case .invalidSaveName: return "Invalid save file name"
            case .missingContentLength: return "Server did not report Content-Length"
            case .httpStatus(let code): return "HTTP \(code)"
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

        let totalLength = try await probeContentLength(remoteURL: remoteURL, log: log)
        if let totalLength, totalLength > 0 {
            try await downloadWithRanges(
                remoteURL: remoteURL,
                destinationURL: destination,
                totalLength: totalLength,
                isCancelled: isCancelled,
                log: log
            )
        } else {
            try await downloadWholeFile(
                remoteURL: remoteURL,
                destinationURL: destination,
                isCancelled: isCancelled,
                log: log
            )
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        log("URL download complete — \(rel) (\(formatBytes(size)))")
        return destination
    }

    private static func probeContentLength(remoteURL: URL, log: @escaping (String) -> Void) async throws -> Int64? {
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "HEAD"
        applyURLCredentials(to: &request, from: remoteURL)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap({ Int64($0) }), length > 0 {
                return length
            }
            if let range = http.value(forHTTPHeaderField: "Content-Range"),
               let total = parseContentRangeTotal(range) {
                return total
            }
            if !(200 ... 299).contains(http.statusCode), http.statusCode != 206 {
                log("URL download HEAD \(http.statusCode) — falling back to full GET")
            }
            return nil
        } catch {
            log("URL download HEAD failed (\(error.localizedDescription)) — full GET")
            return nil
        }
    }

    private static func downloadWithRanges(
        remoteURL: URL,
        destinationURL: URL,
        totalLength: Int64,
        isCancelled: @escaping () -> Bool,
        log: @escaping (String) -> Void
    ) async throws {
        let fm = FileManager.default
        try WebDAVTempFileDownload.ensureFreeDiskSpace(forBytes: totalLength)
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        guard fm.createFile(atPath: destinationURL.path, contents: nil) else {
            throw SegmentExporterError.writerSetupFailed
        }

        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        var offset: Int64 = 0
        var lastLoggedPercent = -1
        var lastProgressLog = CFAbsoluteTimeGetCurrent()

        while offset < totalLength {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            let end = min(offset + chunkBytes - 1, totalLength - 1)
            var request = URLRequest(url: remoteURL)
            request.httpMethod = "GET"
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            applyURLCredentials(to: &request, from: remoteURL)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DownloadError.httpStatus(-1)
            }
            guard (200 ... 299).contains(http.statusCode) || http.statusCode == 206 else {
                throw DownloadError.httpStatus(http.statusCode)
            }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)

            let percent = Int(offset * 100 / totalLength)
            let now = CFAbsoluteTimeGetCurrent()
            if percent >= lastLoggedPercent + progressStepPercent || now - lastProgressLog >= 15 {
                lastLoggedPercent = (percent / progressStepPercent) * progressStepPercent
                lastProgressLog = now
                log(
                    "URL download — \(formatBytes(offset)) / \(formatBytes(totalLength)) (\(percent)%) → \(destinationURL.lastPathComponent)"
                )
            }
        }

        if offset < totalLength {
            throw DownloadError.incomplete(expected: totalLength, got: offset)
        }
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
        applyURLCredentials(to: &request, from: remoteURL)

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.httpStatus(-1)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw DownloadError.httpStatus(http.statusCode)
        }
        if isCancelled() || Task.isCancelled {
            try? FileManager.default.removeItem(at: tempURL)
            throw CancellationError()
        }

        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?.int64Value,
           size > 0 {
            try WebDAVTempFileDownload.ensureFreeDiskSpace(forBytes: size)
        }
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.moveItem(at: tempURL, to: destinationURL)
        log("URL download — full GET finished → \(destinationURL.lastPathComponent)")
    }

    private static func applyURLCredentials(to request: inout URLRequest, from url: URL) {
        guard let user = url.user, let password = url.password else { return }
        let token = Data("\(user):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }

    private static func parseContentRangeTotal(_ header: String) -> Int64? {
        // bytes 0-0/12345
        guard let slash = header.lastIndex(of: "/") else { return nil }
        let totalText = header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        guard totalText != "*", let total = Int64(totalText), total > 0 else { return nil }
        return total
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
