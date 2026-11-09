import Darwin
import Foundation
import Network
import UIKit

/// File index, PROPFIND listings, and WebDAV writes (PUT, POST, MKCOL, DELETE, MOVE).
extension ExportLANServer {
    struct ExportFileEntry {
        let name: String
        let url: URL
        let size: Int64
        let modified: Date?
    }

    struct LANIndexSnapshot {
        let playback: [ExportFileEntry]
        let logs: [ExportFileEntry]
        let builtAt: Date
    }

    static var lanIndexSnapshot: LANIndexSnapshot?
    static let lanIndexSnapshotTTLIdle: TimeInterval = 30
    static let lanIndexSnapshotTTLExport: TimeInterval = 45
    static let lanStatusPollMs = 60_000
    static let lanStatusListsPollMs = 120_000
    static var lastLANMetricsRefresh: Date?
    static let lanMetricsRefreshMinInterval: TimeInterval = 45
    static let lanStatusFilesCap = 48

    static var lanIndexSnapshotTTL: TimeInterval {
        ExportPlaybackState.shared.isLANExportActive
            ? lanIndexSnapshotTTLExport
            : lanIndexSnapshotTTLIdle
    }

    static func exportFileEntry(relativePath: String) -> ExportFileEntry? {
        guard let url = resolveExportFile(relativePath: relativePath) else { return nil }
        let fm = FileManager.default
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = attrs?[.modificationDate] as? Date
        return ExportFileEntry(name: relativePath, url: url, size: size, modified: modified)
    }

    static func buildLANIndexSnapshot() -> LANIndexSnapshot {
        autoreleasepool {
            _ = ExportParkedMedia.migrateLegacyParkFolderNames()
            let exportActive = ExportPlaybackState.shared.isLANExportActive
            let archiveCap = exportActive
                ? ExportPaths.lanPlaybackArchiveIndexLimitDuringExport
                : ExportPaths.lanPlaybackArchiveIndexLimit
            let playback = ExportPaths.listLANPlaybackIndexRelativePaths(maxArchiveEntries: archiveCap)
                .compactMap { exportFileEntry(relativePath: $0) }
            let logCap = exportActive ? 4 : 24
            let logs = ExportPaths.listLANLogIndexRelativePaths(maxHistoryEntries: logCap)
                .compactMap { exportFileEntry(relativePath: $0) }
            return LANIndexSnapshot(playback: playback, logs: logs, builtAt: Date())
        }
    }

    static func currentLANIndexSnapshot() -> LANIndexSnapshot {
        if let cached = lanIndexSnapshot,
           Date().timeIntervalSince(cached.builtAt) < lanIndexSnapshotTTL {
            return cached
        }
        let snapshot = buildLANIndexSnapshot()
        lanIndexSnapshot = snapshot
        return snapshot
    }

    static func statusFilesJSONArray(from index: LANIndexSnapshot) -> [[String: Any]] {
        var fileEntries = index.playback + index.logs
        if fileEntries.count > lanStatusFilesCap {
            fileEntries = Array(fileEntries.prefix(lanStatusFilesCap))
        }
        var entries: [[String: Any]] = []
        entries.reserveCapacity(fileEntries.count)
        for entry in fileEntries {
            var dict: [String: Any] = ["name": entry.name]
            if entry.size > 0 {
                dict["bytes"] = entry.size
            }
            if let modified = entry.modified {
                dict["modified"] = ISO8601DateFormatter().string(from: modified)
            }
            entries.append(dict)
        }
        return entries
    }

    static func listExportFiles() -> [ExportFileEntry] {
        let index = currentLANIndexSnapshot()
        return index.playback + index.logs
    }

    static let archivePlaybackPrefix = "\(ExportPaths.mediaExportFolderName)/archive/"
    static let parkedPlaybackPrefix = "\(ExportPaths.mediaExportFolderName)/\(ExportParkedMedia.folderName)/"

    static func isLANExportLogRelativePath(_ relativePath: String) -> Bool {
        ExportPaths.isLANExportLogRelativePath(relativePath)
            || ExportPaths.canonicalLANLogRelativePath(relativePath) != nil
    }

    /// Playback/media paths (active first, then capped `archive/` newest-first).
    static func listExportFilesForPlaybackIndex() -> [ExportFileEntry] {
        currentLANIndexSnapshot().playback
    }

    /// `pcld_ios_media/logs/export_*.txt` (live + history) — newest first.
    static func listExportLogEntriesForLANIndex() -> [ExportFileEntry] {
        currentLANIndexSnapshot().logs.sorted { lhs, rhs in
            exportLogSortKey(lhs) > exportLogSortKey(rhs)
        }
    }

    static func exportLogSortKey(_ entry: ExportFileEntry) -> Date {
        let fileName = (entry.name as NSString).lastPathComponent
        if entry.name.hasPrefix("\(ExportPaths.exportLogsLANPrefix)/") {
            return ExportPaths.exportLogFileSortDate(fileName: fileName)
        }
        return entry.modified ?? .distantPast
    }

    static func playbackArchiveSortKey(_ entry: ExportFileEntry) -> Date {
        let fileName = (entry.name as NSString).lastPathComponent
        if let stamped = ExportMediaArchive.archivedMediaSortDate(fileName: fileName) {
            return stamped
        }
        return entry.modified ?? .distantPast
    }

    static func parseDepth(requestHeaders: String) -> Int {
        let line = requestHeaders
            .split(separator: "\r\n", omittingEmptySubsequences: true)
            .first { $0.lowercased().hasPrefix("depth:") }
        guard let line else { return 1 }
        let value = line.split(separator: ":", maxSplits: 1).dropFirst().joined()
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if value == "0" { return 0 }
        if value == "infinity" { return 2 }
        return 1
    }

    static func normalizedDAVPath(_ path: String) -> String {
        var p = path.hasPrefix("/") ? path : "/\(path)"
        while p.count > 1, p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }

    /// Windows `net use \\host\DavWWWRoot\` issues PROPFIND/GET under `/DavWWWRoot/…`.
    static func webDAVResourcePath(_ path: String) -> String {
        var p = normalizedDAVPath(path)
        let lower = p.lowercased()
        if lower == "/davwwwroot" {
            return "/"
        }
        if lower.hasPrefix("/davwwwroot/") {
            let suffix = String(p.dropFirst("/davwwwroot".count))
            return normalizedDAVPath(suffix.isEmpty ? "/" : suffix)
        }
        return p
    }

    /// Relative path under `Exports/` (e.g. `pcld_ios_media/loop/op_00.mp4`, `pcld_ios_media/_working.mp4`).
    static func relativeExportPath(fromDAVPath path: String) -> String? {
        let p = webDAVResourcePath(path)
        guard p != "/" else { return nil }
        var rel = p.hasPrefix("/") ? String(p.dropFirst()) : p
        while rel.hasSuffix("/"), rel.count > 1 {
            rel.removeLast()
        }
        guard !rel.isEmpty, !rel.contains("..") else { return nil }
        return rel
    }

    static func rootServableRelativePaths() -> Set<String> {
        [
            ExportPaths.pathRelativeToExports(ExportPaths.latestLogTextURL),
            ExportPaths.pathRelativeToExports(ExportPaths.exportProgressURL),
            "status.json",
        ]
    }

    static func allowedServableRelativePaths() -> Set<String> {
        var names = rootServableRelativePaths()
        for rel in ExportPaths.listLANPlaybackIndexRelativePaths(
            maxArchiveEntries: ExportPaths.lanPlaybackArchiveIndexLimit + 32
        ) {
            names.insert(rel)
        }
        for rel in ExportPaths.listLANLogIndexRelativePaths() {
            names.insert(rel)
        }
        return names
    }

    static func mediaPropfindChildDepthLimit(from depth: Int) -> Int {
        let requested = depth >= 2 ? 2 : max(0, depth)
        if ExportPlaybackState.shared.isLANExportActive {
            return min(requested, 1)
        }
        return min(requested, 3)
    }

    /// Root PROPFIND/GET-DAV children — light path during export (no archive scan / full log sort).
    static func propfindRootChildEntries() -> [ExportFileEntry] {
        if ExportPlaybackState.shared.isLANExportActive {
            return propfindRootChildEntriesDuringExport()
        }
        return listExportFilesForPlaybackIndex() + listExportLogEntriesForLANIndex()
    }

    static func propfindRootChildEntriesDuringExport() -> [ExportFileEntry] {
        autoreleasepool {
            let paths = ExportPaths.listLANPlaybackIndexRelativePaths(maxArchiveEntries: 0)
                + ExportPaths.listLANLogIndexRelativePaths(maxHistoryEntries: 4)
            return paths.compactMap { exportFileEntry(relativePath: $0) }
        }
    }

    static func appendMediaDirectoryPropfind(
        relativeDir: String,
        depthRemaining: Int,
        into responses: inout [String]
    ) {
        guard depthRemaining > 0 else { return }
        let fm = FileManager.default
        for entry in ExportPaths.listLANMediaDirectory(relativeDir: relativeDir) {
            let hrefPath = "/\(entry.relativePath)" + (entry.isDirectory ? "/" : "")
            let childURL = ExportPaths.urlUnderExports(relativePath: entry.relativePath)
            let attrs = try? fm.attributesOfItem(atPath: childURL.path)
            let size = entry.isDirectory ? nil : (attrs?[.size] as? NSNumber)?.int64Value
            let modified = attrs?[.modificationDate] as? Date
            responses.append(
                propfindEntryXML(
                    href: davListingHref(path: hrefPath, isCollection: entry.isDirectory),
                    isCollection: entry.isDirectory,
                    displayName: (entry.relativePath as NSString).lastPathComponent,
                    size: size,
                    modified: modified,
                    contentType: entry.isDirectory ? nil : mimeType(for: childURL)
                )
            )
            if entry.isDirectory, depthRemaining > 1 {
                appendMediaDirectoryPropfind(
                    relativeDir: entry.relativePath,
                    depthRemaining: depthRemaining - 1,
                    into: &responses
                )
            }
        }
    }

    static func mediaDirectoryRelativePath(from rel: String) -> String? {
        let media = ExportPaths.mediaExportFolderName
        if rel == media || rel == "\(media)/" { return media }
        guard rel.hasPrefix("\(media)/") else { return nil }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: ExportPaths.urlUnderExports(relativePath: rel).path, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }
        return rel
    }

    static func xmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func propfindEntryXML(
        href: String,
        isCollection: Bool,
        displayName: String,
        size: Int64?,
        modified: Date?,
        contentType: String? = nil
    ) -> String {
        var prop = ""
        prop += """
            <D:supportedlock>
            <D:lockentry>
            <D:lockscope><D:exclusive/></D:lockscope>
            <D:locktype><D:write/></D:locktype>
            </D:lockentry>
            </D:supportedlock>
            """
        if isCollection {
            prop += "<D:resourcetype><D:collection/></D:resourcetype>"
        } else {
            prop += "<D:resourcetype/>"
            if let size, size > 0 {
                prop += "<D:getcontentlength>\(size)</D:getcontentlength>"
            }
            if let contentType, !contentType.isEmpty {
                prop += "<D:getcontenttype>\(xmlEscape(contentType))</D:getcontenttype>"
            }
        }
        prop += "<D:displayname>\(xmlEscape(displayName))</D:displayname>"
        if let modified {
            prop += "<D:getlastmodified>\(xmlEscape(httpDate(modified)))</D:getlastmodified>"
        }
        if let size, size > 0 {
            let tag = String(format: "%016llx", size)
            prop += "<D:getetag>\"\(tag)\"</D:getetag>"
        } else if isCollection {
            prop += "<D:getetag>\"collection\"</D:getetag>"
        }
        return """
            <D:response>
            <D:href>\(xmlEscape(href))</D:href>
            <D:propstat>
            <D:prop>\(prop)</D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
            </D:response>
            """
    }

    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    static func sendUnauthorized(connection: NWConnection, done: @escaping () -> Void) {
        let body = Data(
            "Basic auth required: use the Loop Segments LAN WebDAV login."
                .utf8
        )
        var lines = [
            "HTTP/1.1 401 Unauthorized",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Length: \(body.count)",
        ]
        lines.append(contentsOf: lanWebDAVAuthHeaderLines())
        lines.append("Connection: close")
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
            done()
        })
    }

    static func parseContentLength(requestHeaders: String) -> Int? {
        guard let value = headerValue(named: "Content-Length", in: requestHeaders) else { return nil }
        return Int(value.trimmingCharacters(in: .whitespaces))
    }

    static func receiveRequestBody(
        on connection: NWConnection,
        requestHeaders: String,
        bodyPrefix: Data,
        maxBytes: Int,
        done: @escaping (Result<Data, LANWebDAVWriteError>) -> Void
    ) {
        guard let contentLength = parseContentLength(requestHeaders: requestHeaders), contentLength >= 0 else {
            done(.failure(.missingContentLength))
            return
        }
        if contentLength > maxBytes {
            done(.failure(.payloadTooLarge))
            return
        }
        if bodyPrefix.count >= contentLength {
            done(.success(Data(bodyPrefix.prefix(contentLength))))
            return
        }
        var accumulated = bodyPrefix
        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, _, error in
                if error != nil {
                    done(.failure(.readFailed))
                    return
                }
                guard let data, !data.isEmpty else {
                    done(.failure(.readFailed))
                    return
                }
                accumulated.append(data)
                if accumulated.count >= contentLength {
                    done(.success(Data(accumulated.prefix(contentLength))))
                } else if accumulated.count > maxBytes {
                    done(.failure(.payloadTooLarge))
                } else {
                    receiveMore()
                }
            }
        }
        receiveMore()
    }

    enum LANWebDAVWriteError: Error {
        case missingContentLength
        case payloadTooLarge
        case readFailed
    }

    static func handlePUT(
        path: String,
        requestHeaders: String,
        bodyPrefix: Data,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if normalized == "pcloud_bookmarks.json" {
            guard enforceLANProxyAuth(requestHeaders: requestHeaders, connection: connection, done: done) else { return }
            handlePCloudBookmarksPUT(
                requestHeaders: requestHeaders,
                bodyPrefix: bodyPrefix,
                connection: connection,
                done: done
            )
            return
        }
        if normalized == "export_from_url.json" {
            guard enforceLANProxyAuth(requestHeaders: requestHeaders, connection: connection, done: done) else { return }
            handleExportFromURLWrite(
                requestHeaders: requestHeaders,
                bodyPrefix: bodyPrefix,
                connection: connection,
                done: done
            )
            return
        }
        if normalized == "export_from_folder.json" {
            guard enforceLANProxyAuth(requestHeaders: requestHeaders, connection: connection, done: done) else { return }
            handleExportFromFolderWrite(
                requestHeaders: requestHeaders,
                bodyPrefix: bodyPrefix,
                connection: connection,
                done: done
            )
            return
        }
        if normalized == "export_queue.json" {
            guard enforceLANProxyAuth(requestHeaders: requestHeaders, connection: connection, done: done) else { return }
            handleExportQueueWrite(
                requestHeaders: requestHeaders,
                bodyPrefix: bodyPrefix,
                connection: connection,
                done: done
            )
            return
        }
        if normalized == "xr_tunnel.json" {
            guard enforceLANProxyAuth(requestHeaders: requestHeaders, connection: connection, done: done) else { return }
            handleXRTunnelWrite(
                requestHeaders: requestHeaders,
                bodyPrefix: bodyPrefix,
                connection: connection,
                done: done
            )
            return
        }
        guard let rel = relativeExportPath(fromDAVPath: path) else {
            sendResponse(connection: connection, status: 404, contentType: "text/plain", body: Data("Not found".utf8), done: done)
            return
        }
        guard ExportPaths.isLANWritableMediaRelativePath(rel) else {
            sendResponse(connection: connection, status: 403, contentType: "text/plain", body: Data("Read-only export path".utf8), done: done)
            return
        }
        _ = ExportPaths.mediaExportDirectory
        _ = ExportPaths.lanExportScriptsDirectory
        guard let fileURL = ExportPaths.urlForLANWritableMedia(relativePath: rel) else {
            sendResponse(connection: connection, status: 403, contentType: "text/plain", body: Data("Forbidden".utf8), done: done)
            return
        }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            sendResponse(connection: connection, status: 405, contentType: "text/plain", body: Data("Cannot PUT to a collection".utf8), done: done)
            return
        }
        let parentURL = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: parentURL, withIntermediateDirectories: true)
        } catch {
            sendResponse(connection: connection, status: 500, contentType: "text/plain; charset=utf-8", body: Data("Could not create parent directory".utf8), done: done)
            return
        }
        let existed = fm.fileExists(atPath: fileURL.path)
        receiveRequestBody(
            on: connection,
            requestHeaders: requestHeaders,
            bodyPrefix: bodyPrefix,
            maxBytes: maxWebDAVPutBytes
        ) { result in
            switch result {
            case .failure(.missingContentLength):
                sendResponse(connection: connection, status: 411, contentType: "text/plain", body: Data("Content-Length required".utf8), done: done)
            case .failure(.payloadTooLarge):
                sendResponse(connection: connection, status: 413, contentType: "text/plain", body: Data("PUT body exceeds \(maxWebDAVPutBytes) bytes".utf8), done: done)
            case .failure(.readFailed):
                connection.cancel()
                done()
            case .success(let body):
                do {
                    try body.write(to: fileURL, options: .atomic)
                    if existed {
                        sendNoContent(connection: connection, done: done)
                    } else {
                        sendCreated(connection: connection, done: done)
                    }
                } catch {
                    sendResponse(connection: connection, status: 500, contentType: "text/plain", body: Data("Write failed".utf8), done: done)
                }
            }
        }
    }

    static func handlePOST(
        path: String,
        requestHeaders: String,
        bodyPrefix: Data,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if normalized == "export_from_url.json" {
            guard enforceLANProxyAuth(requestHeaders: requestHeaders, connection: connection, done: done) else { return }
            handleExportFromURLWrite(
                requestHeaders: requestHeaders,
                bodyPrefix: bodyPrefix,
                connection: connection,
                done: done
            )
            return
        }
        if normalized == "export_from_folder.json" {
            guard enforceLANProxyAuth(requestHeaders: requestHeaders, connection: connection, done: done) else { return }
            handleExportFromFolderWrite(
                requestHeaders: requestHeaders,
                bodyPrefix: bodyPrefix,
                connection: connection,
                done: done
            )
            return
        }
        if normalized == "export_queue.json" {
            guard enforceLANProxyAuth(requestHeaders: requestHeaders, connection: connection, done: done) else { return }
            handleExportQueueWrite(
                requestHeaders: requestHeaders,
                bodyPrefix: bodyPrefix,
                connection: connection,
                done: done
            )
            return
        }
        if normalized == "paused_exports.json" {
            guard enforceLANProxyAuth(requestHeaders: requestHeaders, connection: connection, done: done) else { return }
            handlePausedExportsWrite(
                requestHeaders: requestHeaders,
                bodyPrefix: bodyPrefix,
                connection: connection,
                done: done
            )
            return
        }
        if normalized == "wifi_www_probe.json" {
            guard enforceLANProxyAuth(requestHeaders: requestHeaders, connection: connection, done: done) else { return }
            receiveRequestBody(
                on: connection,
                requestHeaders: requestHeaders,
                bodyPrefix: bodyPrefix,
                maxBytes: 4_096
            ) { result in
                switch result {
                case .failure(.missingContentLength):
                    // Allow empty POST with no Content-Length (companion / curl -X POST).
                    break
                case .failure(.payloadTooLarge):
                    sendResponse(connection: connection, status: 413, contentType: "text/plain", body: Data("Body too large".utf8), done: done)
                    return
                case .failure(.readFailed):
                    connection.cancel()
                    done()
                    return
                case .success:
                    break
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let snap = WifiWwwProbe.runBlocking(timeout: 8)
                    sendJSONPayload(snap.statusJSON(), connection: connection, done: done, status: 200)
                }
            }
            return
        }
        if normalized == "lan_throughput.json" {
            guard enforceLANProxyAuth(requestHeaders: requestHeaders, connection: connection, done: done) else { return }
            handleLANThroughputPOST(
                requestHeaders: requestHeaders,
                bodyPrefix: bodyPrefix,
                connection: connection,
                done: done
            )
            return
        }
        if normalized == "xr_tunnel.json" {
            guard enforceLANProxyAuth(requestHeaders: requestHeaders, connection: connection, done: done) else { return }
            handleXRTunnelWrite(
                requestHeaders: requestHeaders,
                bodyPrefix: bodyPrefix,
                connection: connection,
                done: done
            )
            return
        }
        // Quest Browser posts here without Basic auth (same as video GETs on the LAN).
        if normalized == "xr_debug.json" {
            handleXRDebugWrite(
                requestHeaders: requestHeaders,
                bodyPrefix: bodyPrefix,
                connection: connection,
                done: done
            )
            return
        }
        sendResponse(
            connection: connection,
            status: 405,
            contentType: "text/plain",
            body: Data("POST is only supported for /export_from_url.json, /export_from_folder.json, /export_queue.json, /paused_exports.json, /wifi_www_probe.json, /lan_throughput.json, /xr_tunnel.json, and /xr_debug.json".utf8),
            done: done
        )
    }

    static func handleMKCOL(
        path: String,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        guard let rel = relativeExportPath(fromDAVPath: path) else {
            sendResponse(connection: connection, status: 404, contentType: "text/plain", body: Data("Not found".utf8), done: done)
            return
        }
        guard ExportPaths.isLANWritableMediaRelativePath(rel) else {
            sendResponse(connection: connection, status: 403, contentType: "text/plain", body: Data("Read-only export path".utf8), done: done)
            return
        }
        _ = ExportPaths.mediaExportDirectory
        guard let dirURL = ExportPaths.urlForLANWritableMedia(relativePath: rel) else {
            sendResponse(connection: connection, status: 403, contentType: "text/plain", body: Data("Forbidden".utf8), done: done)
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: dirURL.path) {
            sendResponse(connection: connection, status: 405, contentType: "text/plain", body: Data("Collection already exists".utf8), done: done)
            return
        }
        let parentURL = dirURL.deletingLastPathComponent()
        var parentIsDir: ObjCBool = false
        guard fm.fileExists(atPath: parentURL.path, isDirectory: &parentIsDir), parentIsDir.boolValue else {
            sendResponse(connection: connection, status: 409, contentType: "text/plain", body: Data("Parent collection missing".utf8), done: done)
            return
        }
        do {
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: false)
            sendCreated(connection: connection, done: done)
        } catch {
            sendResponse(connection: connection, status: 500, contentType: "text/plain", body: Data("MKCOL failed".utf8), done: done)
        }
    }

    static func handleDELETE(
        path: String,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        guard let rel = relativeExportPath(fromDAVPath: path) else {
            sendResponse(connection: connection, status: 404, contentType: "text/plain", body: Data("Not found".utf8), done: done)
            return
        }
        guard ExportPaths.isLANWritableMediaRelativePath(rel) else {
            sendResponse(connection: connection, status: 403, contentType: "text/plain", body: Data("Read-only export path".utf8), done: done)
            return
        }
        guard let itemURL = ExportPaths.urlForLANWritableMedia(relativePath: rel) else {
            sendResponse(connection: connection, status: 403, contentType: "text/plain", body: Data("Forbidden".utf8), done: done)
            return
        }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: itemURL.path, isDirectory: &isDirectory) else {
            sendResponse(connection: connection, status: 404, contentType: "text/plain", body: Data("Not found".utf8), done: done)
            return
        }
        do {
            if isDirectory.boolValue {
                let children = try fm.contentsOfDirectory(atPath: itemURL.path)
                guard children.isEmpty else {
                    sendResponse(connection: connection, status: 409, contentType: "text/plain", body: Data("Collection not empty".utf8), done: done)
                    return
                }
            }
            try fm.removeItem(at: itemURL)
            sendNoContent(connection: connection, done: done)
        } catch {
            sendResponse(connection: connection, status: 500, contentType: "text/plain", body: Data("DELETE failed".utf8), done: done)
        }
    }

    /// Local rename/relocate under writable `pcld_ios_media/` paths (no LAN download). Pipeline slots stay 403.
    static func handleMOVE(
        path: String,
        requestHeaders: String,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        guard let destinationHeader = headerValue(named: "Destination", in: requestHeaders),
              !destinationHeader.isEmpty else {
            sendResponse(connection: connection, status: 400, contentType: "text/plain", body: Data("Destination required".utf8), done: done)
            return
        }
        let destPath = httpRequestPath(from: destinationHeader)
        guard let sourceRel = relativeExportPath(fromDAVPath: path),
              let destRel = relativeExportPath(fromDAVPath: destPath) else {
            sendResponse(connection: connection, status: 404, contentType: "text/plain", body: Data("Not found".utf8), done: done)
            return
        }
        guard ExportPaths.isLANWritableMediaRelativePath(sourceRel),
              ExportPaths.isLANWritableMediaRelativePath(destRel) else {
            sendResponse(connection: connection, status: 403, contentType: "text/plain", body: Data("Read-only export path".utf8), done: done)
            return
        }
        guard let sourceURL = ExportPaths.urlForLANWritableMedia(relativePath: sourceRel),
              let destURL = ExportPaths.urlForLANWritableMedia(relativePath: destRel) else {
            sendResponse(connection: connection, status: 403, contentType: "text/plain", body: Data("Forbidden".utf8), done: done)
            return
        }
        if sourceRel == destRel {
            sendNoContent(connection: connection, done: done)
            return
        }
        let fm = FileManager.default
        var sourceIsDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDir) else {
            sendResponse(connection: connection, status: 404, contentType: "text/plain", body: Data("Not found".utf8), done: done)
            return
        }
        if sourceIsDir.boolValue {
            let sourcePrefix = sourceURL.standardizedFileURL.path
            let destStd = destURL.standardizedFileURL.path
            if destStd == sourcePrefix || destStd.hasPrefix(sourcePrefix + "/") {
                sendResponse(connection: connection, status: 409, contentType: "text/plain", body: Data("Cannot MOVE into own descendant".utf8), done: done)
                return
            }
        }
        let overwriteRaw = (headerValue(named: "Overwrite", in: requestHeaders) ?? "T")
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        let overwriteAllowed = overwriteRaw != "F"
        var destIsDir: ObjCBool = false
        let destExists = fm.fileExists(atPath: destURL.path, isDirectory: &destIsDir)
        if destExists, destIsDir.boolValue {
            sendResponse(connection: connection, status: 409, contentType: "text/plain", body: Data("Destination is a collection".utf8), done: done)
            return
        }
        if destExists, !overwriteAllowed {
            sendResponse(connection: connection, status: 412, contentType: "text/plain", body: Data("Destination exists".utf8), done: done)
            return
        }
        let parentURL = destURL.deletingLastPathComponent()
        var parentIsDir: ObjCBool = false
        guard fm.fileExists(atPath: parentURL.path, isDirectory: &parentIsDir), parentIsDir.boolValue else {
            sendResponse(connection: connection, status: 409, contentType: "text/plain", body: Data("Parent collection missing".utf8), done: done)
            return
        }
        do {
            if destExists {
                try fm.removeItem(at: destURL)
            }
            try fm.moveItem(at: sourceURL, to: destURL)
            if destExists {
                sendNoContent(connection: connection, done: done)
            } else {
                sendCreated(connection: connection, done: done)
            }
        } catch {
            sendResponse(connection: connection, status: 500, contentType: "text/plain", body: Data("MOVE failed".utf8), done: done)
        }
    }

    static func sendCreated(connection: NWConnection, done: @escaping () -> Void) {
        let header = "HTTP/1.1 201 Created\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
            connection.cancel()
            done()
        })
    }

    static func sendOptions(connection: NWConnection, done: @escaping () -> Void) {
        let allow = "GET, HEAD, PUT, POST, MKCOL, DELETE, MOVE, OPTIONS, PROPFIND, LOCK, UNLOCK"
        var lines = [
            "HTTP/1.1 200 OK",
            "DAV: 1, 2",
            "MS-Author-Via: DAV",
            "Allow: \(allow)",
            "Public: \(allow)",
            "Content-Length: 0",
        ]
        lines.append("Connection: close")
        let header = lines.joined(separator: "\r\n") + "\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
            connection.cancel()
            done()
        })
    }

    static func sendLock(connection: NWConnection, done: @escaping () -> Void) {
        let token = "opaquelocktoken:loopsegments"
        let bodyText = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:prop xmlns:D="DAV:">
            <D:lockdiscovery>
            <D:activelock>
            <D:locktype><D:write/></D:locktype>
            <D:lockscope><D:exclusive/></D:lockscope>
            <D:depth>Infinity</D:depth>
            <D:timeout>Second-3600</D:timeout>
            </D:activelock>
            </D:lockdiscovery>
            </D:prop>
            """
        let body = Data(bodyText.utf8)
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/xml; charset=utf-8",
            "Content-Length: \(body.count)",
            "Lock-Token: <\(token)>",
            "DAV: 1, 2",
            "Connection: close",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
            done()
        })
    }

    static func sendNoContent(connection: NWConnection, done: @escaping () -> Void) {
        let header = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
            connection.cancel()
            done()
        })
    }

    static func sendPropfind(
        path: String,
        requestHeaders: String,
        connection: NWConnection,
        done: @escaping () -> Void,
        httpStatus: Int = 207,
        httpPhrase: String = "Multi-Status"
    ) {
        let davPath = webDAVResourcePath(path)
        let depth = parseDepth(requestHeaders: requestHeaders)
        var responses: [String] = []

        if let rel = relativeExportPath(fromDAVPath: davPath) {
            let childDepth = mediaPropfindChildDepthLimit(from: depth)

            if let mediaDir = mediaDirectoryRelativePath(from: rel) {
                responses.append(
                    propfindEntryXML(
                        href: davListingHref(path: "/\(mediaDir)/", isCollection: true),
                        isCollection: true,
                        displayName: (mediaDir as NSString).lastPathComponent,
                        size: nil,
                        modified: nil
                    )
                )
                if depth != 0 {
                    appendMediaDirectoryPropfind(
                        relativeDir: mediaDir,
                        depthRemaining: childDepth,
                        into: &responses
                    )
                }
            } else {
                guard let fileURL = resolveExportFile(relativePath: rel) else {
                    sendResponse(connection: connection, status: 404, contentType: "text/plain", body: Data("Not found".utf8), done: done)
                    return
                }
                let fm = FileManager.default
                let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let modified = attrs?[.modificationDate] as? Date
                responses.append(
                    propfindEntryXML(
                        href: davListingHref(path: davPath, isCollection: false),
                        isCollection: false,
                        displayName: fileURL.lastPathComponent,
                        size: size,
                        modified: modified,
                        contentType: mimeType(for: fileURL)
                    )
                )
            }
        } else {
            responses.append(
                propfindEntryXML(
                    href: davListingHref(path: "/", isCollection: true),
                    isCollection: true,
                    displayName: "Exports",
                    size: nil,
                    modified: nil
                )
            )
            if depth != 0 {
                responses.append(
                    propfindEntryXML(
                        href: davListingHref(path: "/\(ExportPaths.mediaExportFolderName)/", isCollection: true),
                        isCollection: true,
                        displayName: ExportPaths.mediaExportFolderName,
                        size: nil,
                        modified: nil
                    )
                )
                for entry in propfindRootChildEntries() {
                    responses.append(
                        propfindEntryXML(
                            href: davListingHref(path: "/\(entry.name)", isCollection: false),
                            isCollection: false,
                            displayName: (entry.name as NSString).lastPathComponent,
                            size: entry.size,
                            modified: entry.modified,
                            contentType: mimeType(for: entry.url)
                        )
                    )
                }
            }
        }

        let bodyText = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:">
            \(responses.joined())
            </D:multistatus>
            """
        let body = Data(bodyText.utf8)
        var headerLines = [
            "HTTP/1.1 \(httpStatus) \(httpPhrase)",
            "Content-Type: application/xml; charset=utf-8",
            "Content-Length: \(body.count)",
            "DAV: 1, 2",
        ]
        headerLines.append("Connection: close")
        let header = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
            done()
        })
    }

    /// Some clients (PotPlayer WebDAV, hand-typed URLs) request `/_working.mp4` or `loop/op_00.mp4`
    /// without the `pcld_ios_media/` prefix. Try the canonical path second.
    static func lanMediaRelativePathCandidates(_ relativePath: String) -> [String] {
        guard !relativePath.contains("..") else { return [] }
        let media = ExportPaths.mediaExportFolderName
        if relativePath.hasPrefix("\(media)/") {
            return [relativePath]
        }
        return [relativePath, "\(media)/\(relativePath)"]
    }

    static func resolveExportFile(relativePath: String) -> URL? {
        guard !relativePath.contains("..") else { return nil }
        if relativePath == "status.json" { return nil }
        let resolvedPath = ExportPaths.canonicalLANLogRelativePath(relativePath) ?? relativePath
        for candidate in lanMediaRelativePathCandidates(resolvedPath) {
            let allowed = ExportPaths.isLANBrowsableMediaRelativePath(candidate)
                || ExportPaths.isLANMediaTreeServableRelativePath(candidate)
                || ExportPaths.isLANExportLogRelativePath(candidate)
                || ExportPaths.isLANExportHistoryLogRelativePath(candidate)
                || rootServableRelativePaths().contains(candidate)
            guard allowed else { continue }
            let url = ExportPaths.urlUnderExports(relativePath: candidate)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
        return url
        }
        return nil
    }
}
