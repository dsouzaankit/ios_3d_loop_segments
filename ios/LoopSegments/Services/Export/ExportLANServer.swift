import Darwin
import Foundation
import Network
import UIKit

/// Serves export logs from `Documents/Exports/` and media from private `Application Support/pcld_ios_media/` on the LAN (HTTP + WebDAV).
/// `pcld_ios_media/` accepts authenticated PUT/MKCOL for PC scripts and nested folders; export pipeline paths stay read-only.
enum ExportLANServer {
    static let defaultPort: UInt16 = 8765
    /// Per-response cap — open-ended `Range: bytes=0-` must not ship multi-GB (Quest browser / Safari OOM).
    private static let maxResponseBodyBytes: Int64 = 32 * 1024 * 1024
    /// PC script uploads via WebDAV PUT (Basic auth required).
    private static let maxWebDAVPutBytes: Int = 2 * 1024 * 1024
    /// LAN WebDAV Basic auth (Skybox, mapped drives). GET without auth still works for PC sync.
    static let lanWebDAVUsername = "admin"
    static let lanWebDAVPassword = "iosadmin"
    private static let lanWebDAVRealm = "Loop Segments LAN"
    private static let enabledKey = "serveExportsOnLAN"
    private static let backgroundCutoffKey = "lanBackgroundPrefetchCutoffMbps"

    /// Mbps UX cutoff: below → LAN preload / vanilla only; at/above → op_00/op_01 when codecs allow (LAN optional).
    static let backgroundPrefetchCutoffOptions: [Double] = [21, 25, 27, 29, 32, 35, 42, 150]
    static let defaultBackgroundPrefetchCutoffMbps = 35.0

    static func prefetchCutoffOptionLabel(mbps: Double) -> String {
        let value = Int(mbps.rounded())
        if mbps == defaultBackgroundPrefetchCutoffMbps {
            return "\(value) Mbps (default)"
        }
        return "\(value) Mbps"
    }

    static var prefetchCutoffSummary: String {
        let mbps = Int(backgroundPrefetchCutoffMbps.rounded())
        if backgroundPrefetchCutoffMbps == defaultBackgroundPrefetchCutoffMbps {
            return "\(mbps) Mbps (default) — 60s segments when source is at/above"
        }
        return "\(mbps) Mbps — 60s segments when source is at/above"
    }

    static var backgroundPrefetchCutoffMbps: Double {
        get {
            guard UserDefaults.standard.object(forKey: backgroundCutoffKey) != nil else {
                return defaultBackgroundPrefetchCutoffMbps
            }
            let stored = UserDefaults.standard.double(forKey: backgroundCutoffKey)
            return nearestBackgroundPrefetchCutoff(to: stored)
        }
        set {
            UserDefaults.standard.set(
                nearestBackgroundPrefetchCutoff(to: newValue),
                forKey: backgroundCutoffKey
            )
        }
    }

    static func nearestBackgroundPrefetchCutoff(to value: Double) -> Double {
        backgroundPrefetchCutoffOptions.min(by: { abs($0 - value) < abs($1 - value) })
            ?? defaultBackgroundPrefetchCutoffMbps
    }

    static let lanServerToggleTitle = "LAN server on Wi‑Fi"

    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private static let lock = NSLock()
    private static var listener: NWListener?
    private static var connections: [ObjectIdentifier: NWConnection] = [:]
    private static let queue = DispatchQueue(label: "com.loopsegments.lan-server")
    /// Bonjour service name (`loopsegments._http._tcp.local` in browsers) — not a pingable hostname.
    static let bonjourServiceName = "loopsegments"
    /// Settings → General → About → Name (e.g. `John's iPhone` → `http://johns-iphone.local:8765/`, not `iphone.local` unless named "iPhone").
    static var deviceAboutName: String {
        UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// mDNS host label from this iPhone (Settings → General → About → Name → `<name>.local`).
    static var deviceMDNSHostName: String {
        "\(deviceMDNSHostLabel()).local"
    }
    /// @deprecated Misleading; use `deviceMDNSHostName`. Kept for call-site compatibility.
    static var bonjourHostName: String { deviceMDNSHostName }
    private static var advertisedBaseURL: String?
    private static var advertisedIPAddressURL: String?

    static var baseURLString: String? {
        lock.lock()
        defer { lock.unlock() }
        return advertisedBaseURL
    }

    /// `http://<iphone-name>.local:8765/` plus numeric IP (prefer IP on Windows).
    static var displayLANURLs: (host: String?, ip: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (advertisedBaseURL, advertisedIPAddressURL)
    }

    /// Start the listener when the user preference is on (idempotent).
    static func ensureRunning(log: @escaping (String) -> Void = { _ in }) {
        guard isEnabled else { return }
        start(log: log)
    }

    static func start(log: @escaping (String) -> Void) {
        guard isEnabled else { return }
        lock.lock()
        if listener != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        queue.async {
            do {
                let port = NWEndpoint.Port(rawValue: defaultPort)!
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let nwListener = try NWListener(using: params, on: port)
                let ipForTXT = Self.primaryLANIPv4Address()
                var txtRecord: Data?
                if let ipForTXT, !ipForTXT.isEmpty {
                    let txt = NetService.data(fromTXTRecord: ["ip": Data(ipForTXT.utf8)])
                    txtRecord = txt
                }
                nwListener.service = NWListener.Service(
                    name: bonjourServiceName,
                    type: "_http._tcp",
                    txtRecord: txtRecord
                )
                lock.lock()
                listener = nwListener
                lock.unlock()

                nwListener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let ip = Self.primaryLANIPv4Address()
                        let hostURL = "http://\(Self.deviceMDNSHostName):\(defaultPort)/"
                        let ipURL = ip.map { "http://\($0):\(defaultPort)/" }
                        lock.lock()
                        advertisedBaseURL = hostURL
                        advertisedIPAddressURL = ipURL
                        lock.unlock()
                        log(
                            "LAN export: \(hostURL)\(ip.map { " · IP \($0)" } ?? "") — Bonjour \(bonjourServiceName)._http._tcp"
                        )
                        log(
                            "LAN: Windows often cannot resolve .local — use IP above; ping may fail even when HTTP works"
                        )
                        log("LAN: HTTP + WebDAV — pcld_ios_media/ (read + auth PUT/MKCOL for scripts), loop/op_*, logs (not SMB)")
                    case .failed(let error):
                        log("LAN export server failed: \(error.localizedDescription)")
                        Self.stopOnQueue(log: nil)
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }

                nwListener.newConnectionHandler = { connection in
                    connection.start(queue: queue)
                    let id = ObjectIdentifier(connection)
                    lock.lock()
                    connections[id] = connection
                    lock.unlock()
                    Self.receiveRequest(on: connection) { [id] in
                        lock.lock()
                        connections.removeValue(forKey: id)
                        lock.unlock()
                    }
                }

                nwListener.start(queue: queue)
            } catch {
                log("LAN export server could not start: \(error.localizedDescription)")
            }
        }
    }

    static func stop(log: ((String) -> Void)? = nil) {
        queue.async {
            stopOnQueue(log: log)
        }
    }

    private static func stopOnQueue(log: ((String) -> Void)?) {
        lock.lock()
        let nwListener = listener
        listener = nil
        advertisedBaseURL = nil
        advertisedIPAddressURL = nil
        let open = connections.values
        connections.removeAll()
        lock.unlock()

        for connection in open {
            connection.cancel()
        }
        nwListener?.cancel()
        log?("LAN export server stopped")
    }

    // MARK: - HTTP

    private static func performWhenReady(
        connection: NWConnection,
        onFailure: @escaping () -> Void,
        work: @escaping () -> Void
    ) {
        if connection.state == .ready {
            work()
            return
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                work()
            case .failed, .cancelled:
                connection.stateUpdateHandler = nil
                connection.cancel()
                onFailure()
            default:
                break
            }
        }
    }

    private static func receiveRequest(on connection: NWConnection, done: @escaping () -> Void) {
        performWhenReady(connection: connection, onFailure: done) {
            receiveHTTPHeaders(on: connection, accumulated: Data(), done: done)
        }
    }

    private static func receiveHTTPHeaders(
        on connection: NWConnection,
        accumulated: Data,
        done: @escaping () -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
            if let error {
                connection.cancel()
                done()
                return
            }
            guard let data, !data.isEmpty else {
                sendResponse(connection: connection, status: 400, contentType: "text/plain", body: Data("Bad request".utf8), done: done)
                return
            }
            var buffer = accumulated
            buffer.append(data)
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 256 * 1024 {
                    sendResponse(connection: connection, status: 413, contentType: "text/plain", body: Data("Request too large".utf8), done: done)
                    return
                }
                receiveHTTPHeaders(on: connection, accumulated: buffer, done: done)
                return
            }
            let headerData = buffer[..<headerEnd.lowerBound]
            guard let text = String(data: headerData, encoding: .utf8) else {
                sendResponse(connection: connection, status: 400, contentType: "text/plain", body: Data("Bad request".utf8), done: done)
                return
            }
            guard let line = text.split(separator: "\r\n", maxSplits: 1).first,
                  let (method, path) = parseRequestLine(String(line)) else {
                sendResponse(connection: connection, status: 400, contentType: "text/plain", body: Data("Bad request".utf8), done: done)
                return
            }
            handleRequest(
                method: method,
                path: webDAVResourcePath(path),
                requestHeaders: text,
                bodyPrefix: Data(buffer[headerEnd.upperBound...]),
                connection: connection,
                done: done
            )
        }
    }

    private static func handleRequest(
        method: String,
        path: String,
        requestHeaders: String,
        bodyPrefix: Data,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        if !enforceLANWebDAVAuth(method: method, path: path, requestHeaders: requestHeaders, connection: connection, done: done) {
            return
        }
        switch method {
        case "GET", "HEAD":
            handleGET(path: path, method: method, requestHeaders: requestHeaders, connection: connection, done: done)
        case "PUT":
            handlePUT(
                path: path,
                requestHeaders: requestHeaders,
                bodyPrefix: bodyPrefix,
                connection: connection,
                done: done
            )
        case "MKCOL":
            handleMKCOL(path: path, connection: connection, done: done)
        case "DELETE":
            handleDELETE(path: path, connection: connection, done: done)
        case "OPTIONS":
            sendOptions(connection: connection, done: done)
        case "PROPFIND":
            sendPropfind(path: path, requestHeaders: requestHeaders, connection: connection, done: done)
        case "LOCK":
            sendLock(connection: connection, done: done)
        case "UNLOCK":
            sendNoContent(connection: connection, done: done)
        default:
            sendResponse(connection: connection, status: 405, contentType: "text/plain", body: Data("Allowed: GET, HEAD, PUT, MKCOL, DELETE, OPTIONS, PROPFIND, LOCK, UNLOCK".utf8), done: done)
        }
    }

    private static func requestBaseURL(from requestHeaders: String) -> String {
        for line in requestHeaders.split(separator: "\r\n", omittingEmptySubsequences: true) {
            guard line.lowercased().hasPrefix("host:") else { continue }
            let host = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            guard host.count == 2 else { continue }
            let hostValue = String(host[1]).trimmingCharacters(in: .whitespaces)
            guard !hostValue.isEmpty else { continue }
            return "http://\(hostValue)"
        }
        lock.lock()
        let advertised = advertisedBaseURL?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        lock.unlock()
        if let advertised, !advertised.isEmpty {
            return advertised
        }
        return "http://127.0.0.1:\(defaultPort)"
    }

    /// Path-only hrefs (pCloud-style) — Skybox resolves against the configured WebDAV root URL.
    private static func davListingHref(path: String, isCollection: Bool) -> String {
        var p = normalizedDAVPath(path)
        if isCollection, p != "/", !p.hasSuffix("/") {
            p += "/"
        }
        return p
    }

    private static func parseRequestLine(_ line: String) -> (String, String)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let path = httpRequestPath(from: String(parts[1]))
        return (String(parts[0]).uppercased(), path)
    }

    /// Request-target may be `/op_00.mp4` (browser) or `http://host:8765/op_00.mp4` (Skybox, some WebDAV clients).
    /// Preserves `?query=` for LAN JSON APIs (`pcloud_list.json?path=…`).
    private static func httpRequestPath(from raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return "/" }

        let lower = path.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            if let url = URL(string: path) {
                var resolved = url.path.isEmpty ? "/" : url.path
                if let query = url.query, !query.isEmpty {
                    return normalizedDAVPath(resolved) + "?" + query
                }
                return normalizedDAVPath(resolved)
            }
        }

        var querySuffix = ""
        if let queryStart = path.firstIndex(of: "?") {
            querySuffix = String(path[queryStart...])
            path = String(path[..<queryStart])
        }
        if let hash = path.firstIndex(of: "#") {
            path = String(path[..<hash])
        }
        if path.isEmpty { path = "/" }

        if path.hasPrefix("//") {
            let withoutScheme = String(path.dropFirst(2))
            if let slash = withoutScheme.firstIndex(of: "/") {
                path = String(withoutScheme[slash...])
            } else {
                path = "/"
            }
        }

        if let decoded = path.removingPercentEncoding {
            path = decoded
        }
        if !path.hasPrefix("/") {
            path = "/\(path)"
        }
        return normalizedDAVPath(path) + querySuffix
    }

    private static func isWebDAVClient(requestHeaders: String) -> Bool {
        let lower = requestHeaders.lowercased()
        if lower.contains("microsoft-webdav") { return true }
        if lower.contains("translate: f") { return true }
        if lower.contains("\ndepth:") || lower.hasPrefix("depth:") { return true }
        if lower.contains("user-agent:") {
            for token in ["skybox", "webdav", "okhttp", "dalvik", "unity"] {
                if lower.contains(token) { return true }
            }
        }
        return false
    }

    private static func normalizedGETPath(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    /// Auth on OPTIONS/PROPFIND/LOCK, WebDAV writes, and WebDAV `GET /`. Media GET stays open (Skybox often omits Authorization on play).
    private static func requiresLANWebDAVAuth(method: String, path: String, requestHeaders: String) -> Bool {
        switch method {
        case "OPTIONS", "PROPFIND", "LOCK", "PUT", "MKCOL", "DELETE":
            return true
        case "GET", "HEAD":
            return normalizedGETPath(path).isEmpty && !isBrowserLikeRequest(requestHeaders: requestHeaders)
        default:
            return false
        }
    }

    @discardableResult
    private static func enforceLANWebDAVAuth(
        method: String,
        path: String,
        requestHeaders: String,
        connection: NWConnection,
        done: @escaping () -> Void
    ) -> Bool {
        guard requiresLANWebDAVAuth(method: method, path: path, requestHeaders: requestHeaders) else {
            return true
        }
        guard headerValue(named: "Authorization", in: requestHeaders) != nil else {
            sendUnauthorized(connection: connection, done: done)
            return false
        }
        guard lanWebDAVAuthorizationOK(requestHeaders: requestHeaders) else {
            sendUnauthorized(connection: connection, done: done)
            return false
        }
        return true
    }

    /// Browsers get the HTML index; WebDAV clients (Skybox, Windows `net use`) get DAV listings.
    private static func isBrowserLikeRequest(requestHeaders: String) -> Bool {
        if isWebDAVClient(requestHeaders: requestHeaders) { return false }
        let lower = requestHeaders.lowercased()
        if lower.contains("accept:"), lower.contains("text/html") { return true }
        if lower.contains("user-agent:") {
            if lower.contains("mozilla") || lower.contains("applewebkit") || lower.contains("safari") {
                return true
            }
        }
        return false
    }

    private static func lanWebDAVAuthHeaderLines() -> [String] {
        ["WWW-Authenticate: Basic realm=\"\(lanWebDAVRealm)\""]
    }

    /// When `Authorization` is sent it must match `lanWebDAVUsername` / `lanWebDAVPassword`.
    private static func lanWebDAVAuthorizationOK(requestHeaders: String) -> Bool {
        guard let value = headerValue(named: "Authorization", in: requestHeaders) else {
            return true
        }
        guard let (user, password) = parseBasicAuthorization(value) else { return false }
        return user.caseInsensitiveCompare(lanWebDAVUsername) == .orderedSame
            && password == lanWebDAVPassword
    }

    private static func parseBasicAuthorization(_ value: String) -> (user: String, password: String)? {
        guard value.lowercased().hasPrefix("basic ") else { return nil }
        let encoded = String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        guard let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        let parts = decoded.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let userPart = parts.first else { return nil }
        let user = String(userPart)
        let password = parts.count > 1 ? String(parts[1]) : ""
        return (user, password)
    }

    private static func headerValue(named name: String, in requestHeaders: String) -> String? {
        let prefix = "\(name.lowercased()):"
        for line in requestHeaders.split(separator: "\r\n", omittingEmptySubsequences: true) {
            let lower = line.lowercased()
            guard lower.hasPrefix(prefix) else { continue }
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func handleGET(
        path: String,
        method: String,
        requestHeaders: String,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if normalized.isEmpty {
            if isBrowserLikeRequest(requestHeaders: requestHeaders) {
                sendIndexHTML(connection, done: done)
                return
            }
            // Skybox validates with GET / — use 200 + DAV XML (207 on GET confuses some clients).
            sendPropfind(
                path: "/",
                requestHeaders: requestHeaders,
                connection: connection,
                done: done,
                httpStatus: 200,
                httpPhrase: "OK"
            )
            return
        }
        if normalized == "status.json" {
            sendStatusJSON(connection, done: done)
            return
        }
        let (resourcePath, query) = splitPathAndQuery(normalized)
        if resourcePath == "pcloud_list.json" {
            sendPCloudListJSON(folderPath: query["path"] ?? "/", connection: connection, done: done)
            return
        }
        if resourcePath == "pcloud_bookmarks.json" {
            sendPCloudBookmarksJSON(connection: connection, done: done)
            return
        }
        guard let fileURL = resolveExportFile(relativePath: resourcePath) else {
            sendResponse(connection: connection, status: 404, contentType: "text/plain", body: Data("Not found".utf8), done: done)
            return
        }
        sendFile(
            connection: connection,
            fileURL: fileURL,
            method: method,
            requestHeaders: requestHeaders,
            done: done
        )
    }

    private static func httpResponseHeader(
        status: Int,
        phrase: String,
        contentType: String,
        contentLength: Int,
        contentRange: String? = nil,
        includeAcceptRanges: Bool = false,
        lastModified: Date? = nil,
        etag: String? = nil
    ) -> String {
        var lines = [
            "HTTP/1.1 \(status) \(phrase)",
            "Content-Type: \(contentType)",
            "Content-Length: \(contentLength)",
        ]
        if includeAcceptRanges {
            lines.append("Accept-Ranges: bytes")
        }
        if let contentRange {
            lines.append("Content-Range: \(contentRange)")
        }
        if let lastModified {
            lines.append("Last-Modified: \(httpDate(lastModified))")
        }
        if let etag {
            lines.append("ETag: \(etag)")
        }
        lines.append("Connection: close")
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    private static func clampResponseEnd(byteStart: Int64, byteEnd: Int64, fileSize: Int64) -> Int64 {
        let maxEnd = min(fileSize - 1, byteStart + maxResponseBodyBytes - 1)
        return min(byteEnd, maxEnd)
    }

    private static func fileETag(size: Int64) -> String {
        String(format: "\"%016llx\"", size)
    }

    /// Parses `Range: bytes=…` for a file of `fileSize` bytes (single range only).
    private static func parseByteRange(requestHeaders: String, fileSize: Int64) -> (start: Int64, end: Int64)? {
        guard fileSize > 0 else { return nil }
        let rangeLine = requestHeaders
            .split(separator: "\r\n", omittingEmptySubsequences: true)
            .first { $0.lowercased().hasPrefix("range:") }
        guard let rangeLine else { return nil }
        let value = rangeLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        guard value.count == 2 else { return nil }
        var spec = String(value[1]).trimmingCharacters(in: .whitespaces)
        guard spec.lowercased().hasPrefix("bytes=") else { return nil }
        spec = String(spec.dropFirst(6))
        if let comma = spec.firstIndex(of: ",") {
            spec = String(spec[..<comma])
        }
        spec = spec.trimmingCharacters(in: .whitespaces)
        if spec.isEmpty { return nil }

        if spec.hasPrefix("-") {
            guard let suffix = Int64(spec.dropFirst()), suffix > 0 else { return nil }
            let start = max(0, fileSize - suffix)
            return (start, fileSize - 1)
        }

        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map { String($0) }
        guard parts.count == 2, let start = Int64(parts[0]), start >= 0 else { return nil }
        let end: Int64
        if parts[1].isEmpty {
            end = fileSize - 1
        } else if let parsedEnd = Int64(parts[1]) {
            end = min(parsedEnd, fileSize - 1)
        } else {
            return nil
        }
        guard start <= end else { return nil }
        return (start, end)
    }

    private struct ExportFileEntry {
        let name: String
        let url: URL
        let size: Int64
        let modified: Date?
    }

    private static func listExportFiles() -> [ExportFileEntry] {
        let fm = FileManager.default
        var entries: [ExportFileEntry] = []
        for rel in allowedServableRelativePaths().sorted() where rel != "status.json" {
            guard let url = resolveExportFile(relativePath: rel) else { continue }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = attrs?[.modificationDate] as? Date
            entries.append(ExportFileEntry(name: rel, url: url, size: size, modified: modified))
        }
        return entries
    }

    private static func parseDepth(requestHeaders: String) -> Int {
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

    private static func normalizedDAVPath(_ path: String) -> String {
        var p = path.hasPrefix("/") ? path : "/\(path)"
        while p.count > 1, p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }

    /// Windows `net use \\host\DavWWWRoot\` issues PROPFIND/GET under `/DavWWWRoot/…`.
    private static func webDAVResourcePath(_ path: String) -> String {
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
    private static func relativeExportPath(fromDAVPath path: String) -> String? {
        let p = webDAVResourcePath(path)
        guard p != "/" else { return nil }
        var rel = p.hasPrefix("/") ? String(p.dropFirst()) : p
        while rel.hasSuffix("/"), rel.count > 1 {
            rel.removeLast()
        }
        guard !rel.isEmpty, !rel.contains("..") else { return nil }
        return rel
    }

    private static func rootServableRelativePaths() -> Set<String> {
        [
            ExportPaths.latestLogTextURL.lastPathComponent,
            ExportPaths.latestLogURL.lastPathComponent,
            ExportPaths.exportProgressURL.lastPathComponent,
            "status.json",
        ]
    }

    private static func allowedServableRelativePaths() -> Set<String> {
        var names = rootServableRelativePaths()
        for rel in ExportPaths.lanBrowsableMediaRelativePaths() {
            names.insert(rel)
        }
        return names
    }

    private static func mediaPropfindChildDepthLimit(from depth: Int) -> Int {
        depth == 2 ? 999 : depth
    }

    private static func appendMediaDirectoryPropfind(
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

    private static func mediaDirectoryRelativePath(from rel: String) -> String? {
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

    private static func xmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func propfindEntryXML(
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

    private static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    private static func sendUnauthorized(connection: NWConnection, done: @escaping () -> Void) {
        let body = Data(
            "Basic auth required — username \(lanWebDAVUsername), password \(lanWebDAVPassword)."
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

    private static func parseContentLength(requestHeaders: String) -> Int? {
        guard let value = headerValue(named: "Content-Length", in: requestHeaders) else { return nil }
        return Int(value.trimmingCharacters(in: .whitespaces))
    }

    private static func receiveRequestBody(
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

    private enum LANWebDAVWriteError: Error {
        case missingContentLength
        case payloadTooLarge
        case readFailed
    }

    private static func handlePUT(
        path: String,
        requestHeaders: String,
        bodyPrefix: Data,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if normalized == "pcloud_bookmarks.json" {
            handlePCloudBookmarksPUT(
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

    private static func handleMKCOL(
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

    private static func handleDELETE(
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

    private static func sendCreated(connection: NWConnection, done: @escaping () -> Void) {
        let header = "HTTP/1.1 201 Created\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
            connection.cancel()
            done()
        })
    }

    private static func sendOptions(connection: NWConnection, done: @escaping () -> Void) {
        let allow = "GET, HEAD, PUT, MKCOL, DELETE, OPTIONS, PROPFIND, LOCK, UNLOCK"
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

    private static func sendLock(connection: NWConnection, done: @escaping () -> Void) {
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

    private static func sendNoContent(connection: NWConnection, done: @escaping () -> Void) {
        let header = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
            connection.cancel()
            done()
        })
    }

    private static func sendPropfind(
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
                for entry in listExportFiles() {
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
    private static func lanMediaRelativePathCandidates(_ relativePath: String) -> [String] {
        guard !relativePath.contains("..") else { return [] }
        let media = ExportPaths.mediaExportFolderName
        if relativePath.hasPrefix("\(media)/") {
            return [relativePath]
        }
        return [relativePath, "\(media)/\(relativePath)"]
    }

    private static func resolveExportFile(relativePath: String) -> URL? {
        guard !relativePath.contains("..") else { return nil }
        if relativePath == "status.json" { return nil }
        for candidate in lanMediaRelativePathCandidates(relativePath) {
            let allowed = ExportPaths.isLANBrowsableMediaRelativePath(candidate)
                || ExportPaths.isLANMediaTreeServableRelativePath(candidate)
                || rootServableRelativePaths().contains(candidate)
            guard allowed else { continue }
            let url = ExportPaths.urlUnderExports(relativePath: candidate)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            return url
        }
        return nil
    }

    private static func htmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func htmlDashboardStatsBlock() -> String {
        let dashboard = ExportPlaybackState.shared.lanDashboardLines()
        guard !dashboard.isEmpty else { return "" }
        let statsEscaped = dashboard.map { "<li>\(htmlEscape($0))</li>" }.joined()
        return """
        <ul id="lan-dashboard-stats">\(statsEscaped)</ul>
        """
    }

    private static func htmlExportSourceLineBlock() -> String {
        let resolved = LANExportSourceDisplay.resolve()
        let hidden = resolved == nil ? " style=\"display:none\"" : ""
        let label = htmlEscape(resolved.map { LANExportSourceDisplay.label(for: $0.phase) } ?? "Export source")
        let name = htmlEscape(resolved?.displayName ?? "")
        let phase = resolved?.phase ?? ""
        let showActions = phase == "running" || phase == "paused"
        let actionsHidden = showActions ? "" : " style=\"display:none\""
        let phaseClass = phase == "running" ? " is-active" : (phase == "paused" ? " is-paused" : "")
        let pauseHidden = phase == "running" ? "" : " style=\"display:none\""
        let resumeHidden = phase == "paused" ? "" : " style=\"display:none\""
        return """
        <div id="lan-export-source-wrap" class="export-source-line\(phaseClass)"\(hidden)>
          <div class="export-source-main">
            <strong id="lan-export-source-label">\(label):</strong>
            <span id="lan-export-source-name">\(name)</span>
          </div>
          <div class="export-source-actions" id="lan-export-source-actions"\(actionsHidden)>
            <button type="button" id="export-resume"\(resumeHidden)>Start export</button>
            <button type="button" id="export-pause"\(pauseHidden)>Pause export</button>
            <button type="button" id="export-stop">Stop export</button>
          </div>
        </div>
        """
    }

    private static func htmlPlaybackStatusLine(_ line: String) -> String {
        """
        <p><strong id="lan-playback-line">\(htmlEscape(line))</strong></p>
        """
    }

    /// Poll `status.json` for export source + LAN playback stats.
    private static func htmlLANLiveRefreshScript() -> String {
        let pollMs = ExportPlaybackState.shared.isLANExportActive ? 3000 : 5000
        return """
        <script>
        (function () {
          var pollMs = \(pollMs);
          function esc(s) {
            return String(s)
              .replace(/&/g, "&amp;")
              .replace(/</g, "&lt;")
              .replace(/"/g, "&quot;");
          }
          function setMediaMaintenanceEnabled(enabled) {
            ["export-trim-media", "export-clear-media"].forEach(function (id) {
              var btn = document.getElementById(id);
              if (btn) btn.disabled = !enabled;
            });
          }
          function applyExportSource(src) {
            if (window._exportSourcePending) return;
            var wrap = document.getElementById("lan-export-source-wrap");
            if (!wrap) return;
            if (!src || !src.displayName) {
              wrap.style.display = "none";
              setMediaMaintenanceEnabled(true);
              return;
            }
            wrap.style.display = "";
            wrap.className = "export-source-line"
              + (src.phase === "running" ? " is-active" : src.phase === "paused" ? " is-paused" : "");
            var label = document.getElementById("lan-export-source-label");
            var name = document.getElementById("lan-export-source-name");
            if (label) label.textContent = (src.label || "Export source") + ":";
            if (name) name.textContent = src.displayName;
            var actions = document.getElementById("lan-export-source-actions");
            var pauseBtn = document.getElementById("export-pause");
            var resumeBtn = document.getElementById("export-resume");
            var active = src.phase === "running" || src.phase === "paused";
            if (actions) actions.style.display = active ? "" : "none";
            if (pauseBtn) pauseBtn.style.display = src.phase === "running" ? "" : "none";
            if (resumeBtn) resumeBtn.style.display = src.phase === "paused" ? "" : "none";
            setMediaMaintenanceEnabled(src.phase !== "running");
          }
          window.updateExportSourceLine = function (phase, displayName) {
            var labels = { running: "Exporting", paused: "Paused export", finished: "Last export" };
            applyExportSource({ phase: phase, displayName: displayName, label: labels[phase] || "Export source" });
          };
          function applyLive(live) {
            if (!live) return;
            var stats = document.getElementById("lan-dashboard-stats");
            if (stats && live.dashboardLines && live.dashboardLines.length) {
              stats.innerHTML = live.dashboardLines.map(function (l) {
                return "<li>" + esc(l) + "</li>";
              }).join("");
            }
            var line = document.getElementById("lan-playback-line");
            if (line && live.playableStatusLine) {
              line.textContent = live.playableStatusLine;
            }
          }
          function applyPlaybackSection(j) {
            if (!j) return;
            if (typeof j.playbackStatusHTML === "string") {
              var status = document.getElementById("lan-playback-status");
              if (status) status.innerHTML = j.playbackStatusHTML;
            }
            if (typeof j.playbackListHTML === "string") {
              var list = document.getElementById("lan-playback-files");
              if (list) list.innerHTML = j.playbackListHTML;
            }
          }
          window.refreshLANPlayback = function () {
            return fetch("status.json", { cache: "no-store" })
              .then(function (r) { return r.json(); })
              .then(function (j) { applyPlaybackSection(j); return j; });
          };
          function poll() {
            if (typeof window.refreshLANBookmarks === "function") {
              window.refreshLANBookmarks().catch(function () {});
            }
            fetch("status.json", { cache: "no-store" })
              .then(function (r) { return r.json(); })
              .then(function (j) {
                applyExportSource(j.exportSource);
                applyLive(j.lanLive);
                applyPlaybackSection(j);
              })
              .catch(function () {});
          }
          poll();
          setInterval(poll, pollMs);
        })();
        </script>
        """
    }

    private static func refreshLANMetricsBeforeStatusResponse() {
        if ExportPlaybackState.shared.usesVanillaDownloadForLAN() {
            return
        }
        if ExportPlaybackState.shared.usesPCloudTranscodedWorkingForLAN() {
            let url = ExportPaths.workingTranscodedURL
            guard FileManager.default.fileExists(atPath: url.path),
                  let sizeNum = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
                return
            }
            ExportPlaybackState.shared.updateTranscodedWorkingFileBytes(sizeNum.int64Value)
            return
        }
        if FileManager.default.fileExists(atPath: ExportPaths.workingSourceURL.path),
           !ExportPaths.shouldHideSparseWorkingFromLAN() {
            WorkingSourceSparseCatalog.refreshPlaybackState(for: ExportPaths.workingSourceURL)
        }
    }

    private static func playbackStatusHTMLBlock() -> String {
        let usesVanilla = ExportPlaybackState.shared.usesVanillaDownloadForLAN()
        if usesVanilla {
            let rel = ExportPlaybackState.shared.vanillaLANRelativePath()
            let line = ExportPlaybackState.shared.lanPlayableStatusLine()
            let startSec = ExportPlaybackState.shared.frozenPlaybackStartSecondsInt
            let seekNote = startSec > 0
                ? "<p><em>Export seek <code>\(formatLANClock(startSec))</code> — open the vanilla file (or faststart copy) via WebDAV or a plain index link (no <code>#t=</code>; some players break on fragments). Seek in the player once dense bytes exist. Download grows from 0:00.</em></p>"
                : ""
            return """
            \(htmlPlaybackStatusLine(line))
            \(htmlDashboardStatsBlock())
            <p><em>Vanilla download — <code>\(rel)</code> (full file, original extension; not sparse <code>_working.mp4</code>).</em></p>
            \(seekNote)
            <p>MP4 faststart copy (when built): <code>pcld_ios_media/_vanilla_faststart.mp4</code>. Prefer <code>loop/op_00.mp4</code> when segments exist.</p>
            """
        }
        if ExportPlaybackState.shared.usesPCloudTranscodedWorkingForLAN()
            || FileManager.default.fileExists(atPath: ExportPaths.workingTranscodedURL.path) {
            let line = ExportPlaybackState.shared.lanPlayableStatusLine()
            return """
            \(htmlPlaybackStatusLine(line))
            \(htmlDashboardStatsBlock())
            <p><em>pCloud HLS transcode — <code>pcld_ios_media/_working_pcloud_transcode.mp4</code> grows with export (real MP4, not the original WMV/MKV file).</em></p>
            <p>Prefer <code>loop/op_00.mp4</code> while export runs.</p>
            """
        }
        if FileManager.default.fileExists(atPath: ExportPaths.workingSourceURL.path),
           !ExportPaths.shouldHideSparseWorkingFromLAN() {
            let line = ExportPlaybackState.shared.lanPlayableStatusLine()
            let startSec = ExportPlaybackState.shared.playbackStartSeconds
            let startedReadable = ExportPlaybackState.shared.timelineSecondsIsReadable(startSec)
            let startedNote = startedReadable
                ? ""
                : "<p><em>Started position is not dense on disk yet (need ~45s preroll before <code>\(formatLANClock(startSec))</code> for decode) — run export again from that seek on a new build, use <code>loop/op_00.mp4</code>, or VLC on <code>_working.mp4</code>.</em></p>"
            return """
            \(htmlPlaybackStatusLine(line))
            \(htmlDashboardStatsBlock())
            <p><code>LAN playable till</code> = furthest contiguous dense bytes from playback start. Below Mbps cutoff: prefetch to EOF, no <code>op_*.mp4</code>. At/above cutoff: <code>op_*.mp4</code> plus minimal <code>_working</code> prefetch when LAN server is on.</p>
            \(startedNote)
            """
        }
        return ""
    }

    private static func playbackFileListHTML() -> String {
        var items: [String] = []
        for entry in listExportFiles() {
            let name = entry.name
            var sizeNote = ""
            if entry.size > 0 {
                sizeNote = " (\(entry.size / 1024) KB)"
            }
            let escaped = htmlEscape(name)
            var note = ""
            if name.hasPrefix("\(ExportPaths.mediaExportFolderName)/_vanilla_download.")
                || name == ExportPaths.pathRelativeToExports(ExportPaths.vanillaFastStartURL) {
                let startSec = ExportPlaybackState.shared.frozenPlaybackStartSecondsInt
                let vanillaNote = name.contains("_vanilla_faststart")
                    ? " — faststart MP4 (replaces _vanilla_download.* after moov-at-end remux)"
                    : " — full vanilla WebDAV download (original extension)"
                let seekNote = startSec > 0
                    ? " — export seek \(formatLANClock(startSec)) (download from 0:00; seek in player)"
                    : ""
                items.append("<li><a href=\"\(escaped)\">\(escaped)</a>\(sizeNote)\(vanillaNote)\(seekNote)</li>")
                continue
            }
            if name == ExportPaths.pathRelativeToExports(ExportPaths.workingTranscodedURL) {
                let cursorSec = Int(ExportPlaybackState.shared.exportCursorSeconds.rounded(.down))
                items.append(
                    "<li><a href=\"\(escaped)\">\(escaped)</a>\(sizeNote)" +
                        " — pCloud transcode (grows through ~\(formatLANClock(cursorSec)); not original file)</li>"
                )
                continue
            }
            if name == ExportPaths.pathRelativeToExports(ExportPaths.workingSourceURL) {
                let startSec = ExportPlaybackState.shared.frozenPlaybackStartSecondsInt
                let tillSec = Int(
                    ExportPlaybackState.shared.maxBrowserPlayableTimelineSeconds().rounded(.down)
                )
                let startNote = startSec > 0
                    ? " — resume from \(formatLANClock(startSec)); LAN dense through ~\(formatLANClock(tillSec))"
                    : " — sparse partial copy; LAN dense through ~\(formatLANClock(tillSec))"
                items.append("<li><a href=\"\(escaped)\">\(escaped)</a>\(sizeNote)\(startNote)</li>")
                continue
            } else if name.hasSuffix(".mp4"),
                      name.contains("\(ExportPaths.mediaExportFolderName)/\(ExportPaths.segmentLoopFolderName)/") {
                note = " — ~60s segment in loop/ (Range supported)"
            } else if name.hasSuffix(".mp4") {
                note = " — sparse in-progress source (seek in player to export start)"
            }
            items.append("<li><a href=\"\(escaped)\">\(escaped)</a>\(sizeNote)\(note)</li>")
        }
        return items.isEmpty
            ? "<li><em>No export files yet — start export on the phone.</em></li>"
            : items.joined()
    }

    private static func sendIndexHTML(_ connection: NWConnection, done: @escaping () -> Void) {
        refreshLANMetricsBeforeStatusResponse()
        let playbackStatusBlock = playbackStatusHTMLBlock()
        let fileList = playbackFileListHTML()
        let html = """
            <!DOCTYPE html>
            <html lang="en"><head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Loop Segments — LAN export</title>
            <style>
            .export-source-line { margin: 0.75rem 0 1rem; padding: 0.65rem 0.85rem; background: #f5f8ff; border: 1px solid #c5d4f0; border-radius: 8px; display: flex; flex-wrap: wrap; gap: 0.65rem; align-items: center; justify-content: space-between; }
            .export-source-line.is-active { background: #fffbea; border-color: #c8a415; }
            .export-source-line.is-paused { background: #fff5f0; border-color: #d08050; }
            .export-source-main { flex: 1 1 12rem; min-width: 0; }
            .export-source-actions { display: flex; flex-wrap: wrap; gap: 0.5rem; flex-shrink: 0; }
            .export-source-line #lan-export-source-name { word-break: break-all; }
            .export-pending-banner { margin: 0.75rem 0 1rem; padding: 0.75rem 1rem; background: #e8f4fd; border: 1px solid #5b9bd5; border-radius: 8px; color: #0d3a5c; }
            .export-pending-banner strong { display: block; margin-bottom: 0.25rem; font-size: 1.05em; }
            .export-pending-banner span { font-size: 0.95em; line-height: 1.45; }
            body { font: -apple-system-body; margin: 1.25rem; line-height: 1.4; }
            code { font-size: 0.9em; }
            ul { padding-left: 1.25rem; }
            .panel { border: 1px solid #ccc; border-radius: 8px; padding: 1rem; margin: 1rem 0; }
            .row { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; margin: 0.5rem 0; }
            button, .btn { font: inherit; padding: 0.35rem 0.65rem; cursor: pointer; }
            button:disabled, .btn:disabled { opacity: 0.55; cursor: wait; }
            .pcloud-folders { display: flex; flex-wrap: wrap; gap: 0.5rem; margin: 0.5rem 0; }
            .pcloud-folders .pcloud-dir { flex: 1 1 9rem; max-width: 14rem; text-align: left; }
            .pcloud-pinned-wrap { margin: 0.25rem 0 0.75rem; }
            .pcloud-pinned-wrap .label { margin-bottom: 0.25rem; font-size: 0.9em; color: #666; }
            .pcloud-pinned .pcloud-dir { border: 1px solid #c8a415; background: #fffbea; }
            .folder-item { display: flex; flex: 1 1 9rem; max-width: 14rem; align-items: stretch; }
            .folder-item .pcloud-dir { flex: 1; max-width: none; border-top-right-radius: 0; border-bottom-right-radius: 0; }
            .pin-toggle { border-top-left-radius: 0; border-bottom-left-radius: 0; padding: 0.35rem 0.5rem; min-width: 2rem; }
            .pin-toggle.pinned { color: #c8a415; }
            #pcloud-files { list-style: none; padding-left: 0; margin: 0.5rem 0; }
            #pcloud-files li { margin: 0.35rem 0; display: flex; flex-wrap: wrap; gap: 0.35rem; align-items: baseline; }
            .file-meta { color: #666; font-size: 0.85em; }
            .muted { color: #666; font-size: 0.9em; }
            #trigger-status { min-height: 1.2em; }
            </style>
            </head><body>
            <h1>Loop Segments — LAN export</h1>
            <div id="lan-export-pending" class="export-pending-banner" style="display:none" role="status" aria-live="polite">
              <strong id="lan-export-pending-title">Processing export request</strong>
              <span id="lan-export-pending-detail">Please wait — keep Loop Segments open in the foreground on the phone.</span>
            </div>
            \(htmlExportSourceLineBlock())
            <p>Serving on port \(defaultPort): logs under <code>Documents/Exports/</code>; media under <code>pcld_ios_media/</code> (private on phone, not in Files app).</p>
            <p>PC: <code>Mount-LoopSegmentsRclone.ps1</code> (maps <code>pcld_ios_media/</code> and logs).</p>
            <p><strong>Playback:</strong> <code>pcld_ios_media/loop/op_00.mp4</code> / <code>pcld_ios_media/loop/op_01.mp4</code> (DLNA can loop the <code>loop/</code> folder). In-progress: <code>_working.mp4</code> (sparse original) or <code>_working_pcloud_transcode.mp4</code> (pCloud HLS transcode — labeled on index when active).</p>
            <div id="lan-playback-status">\(playbackStatusBlock)</div>
            <h2>On phone (playback)</h2>
            <ul id="lan-playback-files">
            \(fileList)
            </ul>
            \(htmlExportControlPanel())
            \(htmlLANLiveRefreshScript())
            </body></html>
            """
        sendResponse(
            connection: connection,
            status: 200,
            contentType: "text/html; charset=utf-8",
            body: Data(html.utf8),
            done: done
        )
    }

    private static func splitPathAndQuery(_ normalized: String) -> (path: String, query: [String: String]) {
        let parts = normalized.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        guard parts.count > 1 else { return (path, [:]) }
        var query: [String: String] = [:]
        for pair in parts[1].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            query[key] = value
        }
        return (path, query)
    }

    private static func sendJSONPayload(
        _ payload: [String: Any],
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            sendResponse(connection: connection, status: 500, contentType: "text/plain", body: Data("JSON error".utf8), done: done)
            return
        }
        sendResponse(connection: connection, status: 200, contentType: "application/json", body: data, done: done)
    }

    private static func sendPCloudListJSON(
        folderPath: String,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        Task { @MainActor in
            let payload = await LANHTTPExportAPI.pcloudListPayload(folderPath: folderPath)
            sendJSONPayload(payload, connection: connection, done: done)
        }
    }

    private static func sendPCloudBookmarksJSON(
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        sendJSONPayload(FolderBookmarkStore.lanBookmarksPayload(), connection: connection, done: done)
    }

    private static func handlePCloudBookmarksPUT(
        requestHeaders: String,
        bodyPrefix: Data,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        receiveRequestBody(
            on: connection,
            requestHeaders: requestHeaders,
            bodyPrefix: bodyPrefix,
            maxBytes: 16_384
        ) { result in
            switch result {
            case .failure(.missingContentLength):
                sendResponse(connection: connection, status: 411, contentType: "text/plain", body: Data("Content-Length required".utf8), done: done)
            case .failure(.payloadTooLarge):
                sendResponse(connection: connection, status: 413, contentType: "text/plain", body: Data("PUT body too large".utf8), done: done)
            case .failure(.readFailed):
                connection.cancel()
                done()
            case .success(let body):
                guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let action = object["action"] as? String,
                      action == "toggle" else {
                    sendResponse(connection: connection, status: 400, contentType: "text/plain; charset=utf-8", body: Data("Expected JSON { \"action\": \"toggle\", \"listingPath\", \"displayName\" }".utf8), done: done)
                    return
                }
                let listingPath = (object["listingPath"] as? String) ?? (object["path"] as? String) ?? ""
                let displayName = (object["displayName"] as? String) ?? (object["name"] as? String) ?? ""
                guard !listingPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    sendResponse(connection: connection, status: 400, contentType: "text/plain; charset=utf-8", body: Data("listingPath required".utf8), done: done)
                    return
                }
                Task { @MainActor in
                    let payload = LANHTTPExportAPI.applyBookmarkToggle(
                        listingPath: listingPath,
                        displayName: displayName
                    )
                    sendJSONPayload(payload, connection: connection, done: done)
                }
            }
        }
    }

    private static func htmlExportControlPanel() -> String {
        let user = htmlEscape(lanWebDAVUsername)
        let pass = htmlEscape(lanWebDAVPassword)
        return """
        <div class="panel">
        <h2>Start export (pCloud → phone)</h2>
        <p class="muted">Phone app must be <strong>open and in foreground</strong> on Wi‑Fi. Uses pCloud sign-in on the phone — not your PC pCloud login.</p>
        <div id="pcloud-pinned-wrap" class="pcloud-pinned-wrap" style="display:none">
          <div class="label">Bookmarked folders</div>
          <p class="muted" style="margin:0 0 0.35rem;font-size:0.85em">Synced with Browse bookmarks on the phone.</p>
          <div id="pcloud-pinned" class="pcloud-folders pcloud-pinned"></div>
        </div>
        <div class="row">
          <button type="button" id="pcloud-up" disabled>↑ Up</button>
          <code id="pcloud-path">/</code>
          <button type="button" id="pcloud-refresh">Refresh</button>
          <button type="button" id="pcloud-pin-current" style="display:none" title="Bookmark this folder">Bookmark folder</button>
        </div>
        <div class="row">
          <label>Sort
            <select id="pcloud-sort">
              <option value="name">Name</option>
              <option value="size">Size</option>
              <option value="date">Date</option>
            </select>
          </label>
        </div>
        <div id="pcloud-folders" class="pcloud-folders"><span class="muted">Loading…</span></div>
        <ul id="pcloud-files"><li class="muted">Loading…</li></ul>
        <div class="row">
          <button type="button" id="export-random">Export random in folder</button>
        </div>
        <div class="row">
          <button type="button" id="export-trim-media">Trim media (keep last 2)</button>
          <button type="button" id="export-clear-media">Clear media</button>
        </div>
        <p id="trigger-status" class="muted"></p>
        </div>
        <script>
        (function () {
          var AUTH = "Basic " + btoa("\(user):\(pass)");
          var triggerUrl = "/\(LANExportTriggerControl.triggerRelativePath)";
          var ackUrl = "/\(LANExportTriggerControl.ackRelativePath)";
          var pcloudPath = "/";
          var pcloudEntries = [];
          var sortKey = "name";
          var LEGACY_PIN_KEY = "loopsegments.lan.pinnedFolders.v1";
          var pinnedFolders = [];
          function normalizePath(p) {
            p = p || "/";
            if (p === "/") return "/";
            return p.replace(/\\/+$/, "") + "/";
          }
          function folderNameFromPath(p) {
            var trimmed = normalizePath(p).replace(/\\/+$/, "");
            if (!trimmed) return "/";
            var parts = trimmed.split("/").filter(Boolean);
            return parts.length ? parts[parts.length - 1] : "/";
          }
          function applyBookmarkPayload(j) {
            pinnedFolders = (j.entries || j.bookmarks || []).map(function (b) {
              var path = normalizePath(b.listingPath || b.path);
              return { path: path, name: b.displayName || b.name || folderNameFromPath(path) };
            });
            renderPinned();
            updatePinCurrentButton();
            if (pcloudEntries.length) renderPCloud();
          }
          async function loadPins() {
            try {
              var r = await fetch("/pcloud_bookmarks.json");
              var j = await r.json();
              applyBookmarkPayload(j);
              await migrateLegacyLocalPins();
            } catch (e) {
              pinnedFolders = [];
              renderPinned();
            }
          }
          async function migrateLegacyLocalPins() {
            try {
              var raw = localStorage.getItem(LEGACY_PIN_KEY);
              if (!raw) return;
              localStorage.removeItem(LEGACY_PIN_KEY);
              var local = JSON.parse(raw);
              if (!Array.isArray(local)) return;
              for (var i = 0; i < local.length; i++) {
                var item = local[i];
                var path = normalizePath(item.path);
                if (!isPinned(path)) {
                  await togglePin(path, item.name);
                }
              }
            } catch (e) {}
          }
          function isPinned(path) {
            var norm = normalizePath(path);
            return pinnedFolders.some(function (p) { return normalizePath(p.path) === norm; });
          }
          async function togglePin(path, name) {
            var norm = normalizePath(path);
            var r = await fetch("/pcloud_bookmarks.json", {
              method: "PUT",
              headers: { "Authorization": AUTH, "Content-Type": "application/json" },
              body: JSON.stringify({
                action: "toggle",
                listingPath: norm,
                displayName: name || folderNameFromPath(norm)
              })
            });
            if (!r.ok) throw new Error("bookmark PUT " + r.status);
            var j = await r.json();
            applyBookmarkPayload(j);
          }
          function renderPinned() {
            var wrap = document.getElementById("pcloud-pinned-wrap");
            var el = document.getElementById("pcloud-pinned");
            if (!pinnedFolders.length) {
              wrap.style.display = "none";
              el.innerHTML = "";
              return;
            }
            wrap.style.display = "";
            el.innerHTML = pinnedFolders.map(function (p) {
              return "<div class=\\"folder-item\\">" +
                "<button type=\\"button\\" class=\\"pcloud-dir pcloud-pinned-dir\\" data-path=\\"" + esc(p.path) + "\\">⭐ " + esc(p.name) + "</button>" +
                "<button type=\\"button\\" class=\\"pin-toggle pinned\\" data-path=\\"" + esc(p.path) + "\\" data-name=\\"" + esc(p.name) + "\\" title=\\"Remove bookmark\\">★</button>" +
                "</div>";
            }).join("");
          }
          function updatePinCurrentButton() {
            var btn = document.getElementById("pcloud-pin-current");
            var norm = normalizePath(pcloudPath);
            if (norm === "/") {
              btn.style.display = "none";
              return;
            }
            btn.style.display = "";
            btn.textContent = isPinned(norm) ? "Remove bookmark" : "Bookmark folder";
          }
          function esc(s) {
            return String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/"/g,"&quot;");
          }
          function formatBytes(n) {
            if (n == null || isNaN(n)) return "";
            var u = ["B","KB","MB","GB","TB"];
            var i = 0, v = Number(n);
            while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
            return v.toFixed(i ? 1 : 0) + " " + u[i];
          }
          function formatDate(iso) {
            if (!iso) return "";
            try { return new Date(iso).toLocaleString(); } catch (e) { return iso; }
          }
          function compareEntries(a, b) {
            if (sortKey === "size") {
              var as = a.bytes || 0, bs = b.bytes || 0;
              if (as !== bs) return bs - as;
            } else if (sortKey === "date") {
              var ad = a.modified || "", bd = b.modified || "";
              if (ad !== bd) return bd.localeCompare(ad);
            }
            return String(a.name || "").localeCompare(String(b.name || ""), undefined, { sensitivity: "base" });
          }
          function renderPCloud() {
            var foldersEl = document.getElementById("pcloud-folders");
            var filesEl = document.getElementById("pcloud-files");
            var pinnedPaths = pinnedFolders.map(function (p) { return normalizePath(p.path); });
            var dirs = pcloudEntries.filter(function (e) { return e.isDirectory; }).filter(function (e) {
              return pinnedPaths.indexOf(normalizePath(e.path)) === -1;
            }).slice().sort(compareEntries);
            var files = pcloudEntries.filter(function (e) { return e.isVideo; }).slice().sort(compareEntries);
            renderPinned();
            updatePinCurrentButton();
            foldersEl.innerHTML = dirs.length
              ? dirs.map(function (e) {
                  var pinned = isPinned(e.path);
                  return "<div class=\\"folder-item\\">" +
                    "<button type=\\"button\\" class=\\"pcloud-dir\\" data-path=\\"" + esc(e.path) + "\\">📁 " + esc(e.name) + "</button>" +
                    "<button type=\\"button\\" class=\\"pin-toggle" + (pinned ? " pinned" : "") + "\\" data-path=\\"" + esc(e.path) + "\\" data-name=\\"" + esc(e.name) + "\\" title=\\"" + (pinned ? "Remove bookmark" : "Bookmark") + "\\">" + (pinned ? "★" : "☆") + "</button>" +
                    "</div>";
                }).join("")
              : "<span class=\\"muted\\">(no folders)</span>";
            filesEl.innerHTML = files.length
              ? files.map(function (e) {
                  var meta = [];
                  if (e.bytes != null) meta.push(formatBytes(e.bytes));
                  if (e.modified) meta.push(formatDate(e.modified));
                  var metaHtml = meta.length ? " <span class=\\"file-meta\\">(" + esc(meta.join(" · ")) + ")</span>" : "";
                  return "<li><span>🎬 " + esc(e.name) + metaHtml + "</span>" +
                    " <button type=\\"button\\" class=\\"export-file\\" data-href=\\"" + esc(e.href) + "\\" data-name=\\"" + esc(e.name) + "\\">Export 0:00</button></li>";
                }).join("")
              : "<li class=\\"muted\\">(no videos)</li>";
          }
          function uuid() {
            return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function (c) {
              var r = Math.random() * 16 | 0, v = c === "x" ? r : (r & 0x3 | 0x8);
              return v.toString(16);
            });
          }
          function setStatus(msg, isErr) {
            var el = document.getElementById("trigger-status");
            el.textContent = msg || "";
            el.style.color = isErr ? "#b00020" : "#333";
          }
          function exportPendingMessage(command, body) {
            var foreground = " Keep Loop Segments open in the foreground on the phone.";
            switch (command) {
              case "start_export":
                return {
                  title: "Switching export source",
                  detail: "Please wait while the phone switches to "
                    + (body.displayName || "the selected file") + "." + foreground
                };
              case "start_export_random":
                return {
                  title: "Switching export source",
                  detail: "Please wait while the phone picks and starts a new export in this folder." + foreground
                };
              case "pause_export":
                return {
                  title: "Pausing export",
                  detail: "Please wait while the phone pauses the current export." + foreground
                };
              case "resume_export":
                return {
                  title: "Starting export",
                  detail: "Please wait while the phone resumes the paused export." + foreground
                };
              case "stop_export":
                return {
                  title: "Stopping export",
                  detail: "Please wait while the phone stops export, removes loop/ segments, and archives working copies." + foreground
                };
              case "clear_media":
                return {
                  title: "Clearing media",
                  detail: "Please wait while the phone permanently deletes active export media and archive/ files." + foreground
                };
              case "trim_media":
                return {
                  title: "Trimming archive",
                  detail: "Please wait while the phone removes older archive/ batches (keeps last 2)." + foreground
                };
              default:
                return {
                  title: "Processing export request",
                  detail: "Please wait while the phone applies your export change." + foreground
                };
            }
          }
          function setExportPending(active, title, detail) {
            window._exportSourcePending = !!active;
            var banner = document.getElementById("lan-export-pending");
            if (banner) banner.style.display = active ? "" : "none";
            var titleEl = document.getElementById("lan-export-pending-title");
            var detailEl = document.getElementById("lan-export-pending-detail");
            if (titleEl && title) titleEl.textContent = title;
            if (detailEl && detail) detailEl.textContent = detail;
            ["export-resume", "export-pause", "export-stop", "export-random", "export-trim-media", "export-clear-media"].forEach(function (id) {
              var btn = document.getElementById(id);
              if (btn) btn.disabled = !!active;
            });
            document.querySelectorAll(".export-file").forEach(function (btn) {
              btn.disabled = !!active;
            });
          }
          window.setExportPending = setExportPending;
          async function putTrigger(body) {
            var pending = exportPendingMessage(body.command, body);
            setExportPending(true, pending.title, pending.detail);
            try {
            setStatus("Sending trigger…");
            if (body.command === "start_export" && body.displayName && window.updateExportSourceLine) {
              window.updateExportSourceLine("running", body.displayName);
            } else if (body.command === "start_export_random" && window.updateExportSourceLine) {
              window.updateExportSourceLine("running", "Random in " + pcloudPath);
            } else if (body.command === "pause_export" && window.updateExportSourceLine) {
              var cur = document.getElementById("lan-export-source-name");
              if (cur && cur.textContent) window.updateExportSourceLine("paused", cur.textContent);
            } else if (body.command === "resume_export" && window.updateExportSourceLine) {
              var curName = document.getElementById("lan-export-source-name");
              if (curName && curName.textContent) window.updateExportSourceLine("running", curName.textContent);
            } else if (body.command === "stop_export" && window.updateExportSourceLine) {
              var last = document.getElementById("lan-export-source-name");
              if (last && last.textContent) window.updateExportSourceLine("finished", last.textContent);
            }
            var r = await fetch(triggerUrl, {
              method: "PUT",
              headers: { "Authorization": AUTH, "Content-Type": "application/json" },
              body: JSON.stringify(body)
            });
            if (!r.ok) {
              var errText = "";
              try { errText = await r.text(); } catch (e) {}
              throw new Error("PUT " + r.status + (errText ? ": " + errText.trim() : ""));
            }
            for (var i = 0; i < 8; i++) {
              await new Promise(function (res) { setTimeout(res, 500); });
              try {
                var ack = await fetch(ackUrl, { headers: { "Authorization": AUTH } });
                if (ack.ok) {
                  var j = await ack.json();
                  setStatus((j.status || "?") + ": " + (j.message || ""), j.status === "rejected");
                  if (j.status === "accepted" && window.refreshLANPlayback) {
                    for (var p = 0; p < 6; p++) {
                      await new Promise(function (res) { setTimeout(res, 500); });
                      try { await window.refreshLANPlayback(); } catch (e) {}
                    }
                  }
                  return;
                }
              } catch (e) {}
            }
            setStatus("Trigger sent — check phone app (foreground).", false);
            } finally {
              setExportPending(false);
            }
          }
          async function loadPCloud() {
            document.getElementById("pcloud-path").textContent = pcloudPath;
            document.getElementById("pcloud-up").disabled = pcloudPath === "/";
            updatePinCurrentButton();
            var foldersEl = document.getElementById("pcloud-folders");
            var filesEl = document.getElementById("pcloud-files");
            foldersEl.innerHTML = "<span class=\\"muted\\">Loading…</span>";
            filesEl.innerHTML = "<li class=\\"muted\\">Loading…</li>";
            try {
              var r = await fetch("/pcloud_list.json?path=" + encodeURIComponent(pcloudPath));
              var j = await r.json();
              if (j.error) {
                foldersEl.innerHTML = "<span class=\\"muted\\">" + esc(j.error) + "</span>";
                filesEl.innerHTML = "";
                pcloudEntries = [];
                renderPinned();
                return;
              }
              pcloudEntries = j.entries || [];
              if (!pcloudEntries.length) {
                foldersEl.innerHTML = "<span class=\\"muted\\">(empty folder)</span>";
                filesEl.innerHTML = "";
                renderPinned();
                updatePinCurrentButton();
                return;
              }
              renderPCloud();
            } catch (err) {
              foldersEl.innerHTML = "<span class=\\"muted\\">" + esc(err.message || err) + "</span>";
              filesEl.innerHTML = "";
              pcloudEntries = [];
              renderPinned();
            }
          }
          function handleFolderAreaClick(ev) {
            var pinBtn = ev.target.closest ? ev.target.closest(".pin-toggle") : null;
            if (pinBtn) {
              togglePin(pinBtn.getAttribute("data-path"), pinBtn.getAttribute("data-name"))
                .catch(function (e) { setStatus(e.message || e, true); });
              return;
            }
            var dirBtn = ev.target.closest ? ev.target.closest(".pcloud-dir") : null;
            if (!dirBtn && ev.target.classList && ev.target.classList.contains("pcloud-dir")) {
              dirBtn = ev.target;
            }
            if (dirBtn) {
              pcloudPath = dirBtn.getAttribute("data-path") || "/";
              loadPCloud();
            }
          }
          document.getElementById("pcloud-up").onclick = function () {
            var trimmed = pcloudPath.replace(/\\/$/, "");
            if (!trimmed || trimmed === "/") { pcloudPath = "/"; loadPCloud(); return; }
            var parts = trimmed.split("/").filter(Boolean);
            parts.pop();
            pcloudPath = parts.length ? "/" + parts.join("/") + "/" : "/";
            loadPCloud();
          };
          document.getElementById("pcloud-refresh").onclick = function () {
            loadPins().then(function () { loadPCloud(); }).catch(function () { loadPCloud(); });
          };
          document.getElementById("export-random").onclick = function () {
            putTrigger({ version: 1, command: "start_export_random", pool: "same_folder", folderPath: pcloudPath, id: uuid(), seekMs: 0 })
              .catch(function (e) { setStatus(e.message || e, true); });
          };
          document.getElementById("export-resume").onclick = function () {
            putTrigger({ version: 1, command: "resume_export", id: uuid() })
              .catch(function (e) { setStatus(e.message || e, true); });
          };
          document.getElementById("export-pause").onclick = function () {
            putTrigger({ version: 1, command: "pause_export", id: uuid() })
              .catch(function (e) { setStatus(e.message || e, true); });
          };
          document.getElementById("export-stop").onclick = function () {
            putTrigger({ version: 1, command: "stop_export", id: uuid() })
              .catch(function (e) { setStatus(e.message || e, true); });
          };
          document.getElementById("export-trim-media").onclick = function () {
            putTrigger({ version: 1, command: "trim_media", id: uuid() })
              .catch(function (e) { setStatus(e.message || e, true); });
          };
          document.getElementById("export-clear-media").onclick = function () {
            if (!confirm("Permanently delete active export media and all archive/ files on the phone?")) return;
            putTrigger({ version: 1, command: "clear_media", id: uuid() })
              .catch(function (e) { setStatus(e.message || e, true); });
          };
          document.getElementById("pcloud-sort").onchange = function (ev) {
            sortKey = ev.target.value || "name";
            renderPCloud();
          };
          document.getElementById("pcloud-folders").onclick = handleFolderAreaClick;
          document.getElementById("pcloud-pinned").onclick = handleFolderAreaClick;
          document.getElementById("pcloud-pin-current").onclick = function () {
            togglePin(pcloudPath, folderNameFromPath(pcloudPath))
              .catch(function (e) { setStatus(e.message || e, true); });
          };
          document.getElementById("pcloud-files").onclick = function (ev) {
            var exportBtn = ev.target.closest ? ev.target.closest(".export-file") : null;
            if (!exportBtn && ev.target.classList && ev.target.classList.contains("export-file")) {
              exportBtn = ev.target;
            }
            if (exportBtn) {
              putTrigger({
                version: 1,
                command: "start_export",
                href: exportBtn.getAttribute("data-href"),
                displayName: exportBtn.getAttribute("data-name"),
                seekMs: 0,
                id: uuid()
              }).catch(function (e) { setStatus(e.message || e, true); });
            }
          };
          loadPins().then(function () { loadPCloud(); }).catch(function () { loadPCloud(); });
          window.refreshLANBookmarks = loadPins;
        })();
        </script>
        """
    }

    private static func sendStatusJSON(_ connection: NWConnection, done: @escaping () -> Void) {
        refreshLANMetricsBeforeStatusResponse()
        let fm = FileManager.default
        var entries: [[String: Any]] = []
        for rel in rootServableRelativePaths().union(Set(ExportPaths.lanBrowsableMediaRelativePaths())).sorted() {
            guard let url = resolveExportFile(relativePath: rel) else { continue }
            var dict: [String: Any] = ["name": rel]
            if let attrs = try? fm.attributesOfItem(atPath: url.path) {
                if let size = attrs[.size] as? NSNumber {
                    dict["bytes"] = size.int64Value
                }
                if let modified = attrs[.modificationDate] as? Date {
                    dict["modified"] = ISO8601DateFormatter().string(from: modified)
                }
            }
            entries.append(dict)
        }
        var payload: [String: Any] = [
            "exportsDirectory": "Exports",
            "port": Int(defaultPort),
            "files": entries,
        ]
        if ExportPlaybackState.shared.usesVanillaDownloadForLAN() {
            var playback = ExportPlaybackState.shared.frozenStatusPayload
            let startSec = (playback["playbackStartSeconds"] as? Double) ?? 0
            playback["resumeTimelineReadable"] = startSec <= 0
                || ((playback["lanPlayableTillSeconds"] as? Double) ?? 0) >= startSec
            payload["vanillaDownloadPlayback"] = playback
        } else if ExportPlaybackState.shared.usesPCloudTranscodedWorkingForLAN() {
            var playback = ExportPlaybackState.shared.frozenStatusPayload
            let startSec = (playback["playbackStartSeconds"] as? Double) ?? 0
            playback["resumeTimelineReadable"] = ExportPlaybackState.shared.timelineSecondsIsReadable(startSec)
            payload["pcloudTranscodedPlayback"] = playback
        } else if FileManager.default.fileExists(atPath: ExportPaths.workingSourceURL.path),
                  !ExportPaths.shouldHideSparseWorkingFromLAN() {
            var playback = ExportPlaybackState.shared.frozenStatusPayload
            let startSec = (playback["playbackStartSeconds"] as? Double) ?? 0
            playback["resumeTimelineReadable"] = ExportPlaybackState.shared.timelineSecondsIsReadable(startSec)
            payload["workingSourcePlayback"] = playback
        }
        if ExportPlaybackState.shared.isLANExportActive {
            payload["lanLive"] = ExportPlaybackState.shared.lanLiveStatusPayload()
        }
        if let exportSource = LANExportSourceDisplay.statusPayload() {
            payload["exportSource"] = exportSource
        }
        payload["playbackStatusHTML"] = playbackStatusHTMLBlock()
        payload["playbackListHTML"] = playbackFileListHTML()
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            sendResponse(connection: connection, status: 500, contentType: "text/plain", body: Data("JSON error".utf8), done: done)
            return
        }
        sendResponse(connection: connection, status: 200, contentType: "application/json", body: data, done: done)
    }

    private static func sendFile(
        connection: NWConnection,
        fileURL: URL,
        method: String,
        requestHeaders: String,
        done: @escaping () -> Void
    ) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let sizeNum = attrs[.size] as? NSNumber,
              sizeNum.int64Value > 0 else {
            sendResponse(connection: connection, status: 404, contentType: "text/plain", body: Data("Empty or missing".utf8), done: done)
            return
        }
        let fileSize = sizeNum.int64Value
        let contentType = mimeType(for: fileURL)
        let modified = attrs[.modificationDate] as? Date
        let etag = fileETag(size: fileSize)
        let isSparseWorkingSource = fileURL.standardizedFileURL.path
            == ExportPaths.workingSourceURL.standardizedFileURL.path
        let isTranscodedWorking = fileURL.standardizedFileURL.path
            == ExportPaths.workingTranscodedURL.standardizedFileURL.path
        if isSparseWorkingSource {
            WorkingSourceSparseCatalog.refreshPlaybackState(for: fileURL)
        }
        let isWorkingSource = isSparseWorkingSource || isTranscodedWorking
        /// Only sparse/in-progress working copies are capped (Quest OOM). Dense `_vanilla_download.*` is always full-file Range/seek.
        let capResponseBody = isWorkingSource

        let byteStart: Int64
        var byteEnd: Int64
        let status: Int
        let phrase: String
        let hasRangeHeader = requestHeaders.split(separator: "\r\n").contains { $0.lowercased().hasPrefix("range:") }

        if let range = parseByteRange(requestHeaders: requestHeaders, fileSize: fileSize) {
            byteStart = range.start
            byteEnd = range.end
            if isSparseWorkingSource {
                guard let readableEnd = ExportPlaybackState.shared.maxContiguousReadableEnd(
                    from: byteStart,
                    maxEnd: byteEnd
                ) else {
                    respondWorkingSourceUnreadable(connection: connection, done: done)
                    return
                }
                byteEnd = min(byteEnd, readableEnd)
            }
            if capResponseBody {
                byteEnd = clampResponseEnd(byteStart: byteStart, byteEnd: byteEnd, fileSize: fileSize)
            }
            status = 206
            phrase = "Partial Content"
        } else if hasRangeHeader {
            sendResponse(connection: connection, status: 416, contentType: "text/plain", body: Data("Range not satisfiable".utf8), done: done)
            return
        } else if isSparseWorkingSource, method == "GET" {
            let tailStart = ExportPlaybackState.shared.indexTailStartByte
            let moovInHead = MP4NetworkOptimize.moovPresentInFirstBytes(
                of: fileURL,
                scanBytes: 512 * 1024
            )
            let preferTail = ExportPlaybackState.shared.tailOnDiskForLAN
                && tailStart > 0
                && tailStart < fileSize
                && !moovInHead
            if preferTail,
               let readableEnd = ExportPlaybackState.shared.maxContiguousReadableEnd(
                   from: tailStart,
                   maxEnd: fileSize - 1
               ) {
                byteStart = tailStart
                byteEnd = clampResponseEnd(byteStart: tailStart, byteEnd: readableEnd, fileSize: fileSize)
                status = 206
                phrase = "Partial Content"
            } else if let readableEnd = ExportPlaybackState.shared.maxContiguousReadableEnd(
                from: 0,
                maxEnd: fileSize - 1
            ) {
                byteStart = 0
                byteEnd = clampResponseEnd(byteStart: 0, byteEnd: readableEnd, fileSize: fileSize)
                status = 206
                phrase = "Partial Content"
            } else {
                let header = httpResponseHeader(
                    status: 200,
                    phrase: "OK",
                    contentType: contentType,
                    contentLength: 0,
                    contentRange: nil,
                    includeAcceptRanges: true,
                    lastModified: modified,
                    etag: etag
                )
                guard let headerData = header.data(using: .utf8) else {
                    done()
                    return
                }
                connection.send(content: headerData, completion: .contentProcessed { _ in
                    connection.cancel()
                    done()
                })
                return
            }
        } else {
            byteStart = 0
            byteEnd = fileSize - 1
            if capResponseBody {
                byteEnd = clampResponseEnd(byteStart: 0, byteEnd: byteEnd, fileSize: fileSize)
            }
            status = byteEnd >= fileSize - 1 ? 200 : 206
            phrase = status == 206 ? "Partial Content" : "OK"
        }

        let bodyLength = byteEnd - byteStart + 1
        guard bodyLength > 0, bodyLength <= fileSize else {
            sendResponse(connection: connection, status: 416, contentType: "text/plain", body: Data("Range not satisfiable".utf8), done: done)
            return
        }

        if isWorkingSource, method != "HEAD", !ExportPlaybackState.shared.rangeIsReadable(start: byteStart, end: byteEnd) {
            respondWorkingSourceUnreadable(connection: connection, done: done)
            return
        }

        let contentRange = status == 206
            ? "bytes \(byteStart)-\(byteEnd)/\(fileSize)"
            : nil
        let reportedContentLength: Int = {
            if method == "HEAD", !hasRangeHeader, !isWorkingSource {
                return Int(fileSize)
            }
            return Int(bodyLength)
        }()
        let headStatus = method == "HEAD" && !hasRangeHeader && !isWorkingSource ? 200 : status
        let headPhrase = headStatus == 200 ? "OK" : phrase
        let headContentRange = method == "HEAD" && !hasRangeHeader && !isWorkingSource ? nil : contentRange
        let header = httpResponseHeader(
            status: headStatus,
            phrase: headPhrase,
            contentType: contentType,
            contentLength: reportedContentLength,
            contentRange: headContentRange,
            includeAcceptRanges: true,
            lastModified: modified,
            etag: etag
        )
        guard let headerData = header.data(using: .utf8) else {
            done()
            return
        }

        if method == "HEAD" {
            connection.send(content: headerData, completion: .contentProcessed { _ in
                connection.cancel()
                done()
            })
            return
        }

        connection.send(content: headerData, completion: .contentProcessed { error in
            if error != nil {
                connection.cancel()
                done()
                return
            }
            // One handle for the whole response — reopening per chunk can splice two op_00.mp4
            // versions if the phone publishes a new segment mid-download (corrupt / no moov on PC).
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: fileURL)
            } catch {
                sendResponse(
                    connection: connection,
                    status: 500,
                    contentType: "text/plain",
                    body: Data("Cannot open file".utf8),
                    done: done
                )
                return
            }
            streamFile(
                connection: connection,
                handle: handle,
                offset: byteStart,
                remaining: bodyLength,
                done: done
            )
        })
    }

    private static func streamFile(
        connection: NWConnection,
        handle: FileHandle,
        offset: Int64,
        remaining: Int64,
        done: @escaping () -> Void
    ) {
        if remaining <= 0 {
            try? handle.close()
            connection.cancel()
            done()
            return
        }
        let chunkSize = min(remaining, 512 * 1024)
        do {
            try handle.seek(toOffset: UInt64(offset))
            let data = handle.readData(ofLength: Int(chunkSize))
            guard !data.isEmpty else {
                try? handle.close()
                connection.cancel()
                done()
                return
            }
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    try? handle.close()
                    connection.cancel()
                    done()
                    return
                }
                let sent = Int64(data.count)
                streamFile(
                    connection: connection,
                    handle: handle,
                    offset: offset + sent,
                    remaining: remaining - sent,
                    done: done
                )
            })
        } catch {
            try? handle.close()
            connection.cancel()
            done()
        }
    }

    private static func respondWorkingSourceUnreadable(
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        let snap = ExportPlaybackState.shared.frozenStatusPayload
        let startSec = (snap["playbackStartSeconds"] as? Double) ?? 0
        let cursorSec = (snap["exportCursorSeconds"] as? Double) ?? 0
        let durationSec = (snap["durationSeconds"] as? Double) ?? 0
        let active = ExportPlaybackState.shared.isLANExportActive
        let status = active ? 503 : 416
        let resumeReadable = ExportPlaybackState.shared.timelineSecondsIsReadable(startSec)
        let hint = active
            ? "Range not on disk yet. Export is still filling this part of the file; retry in a few seconds."
            : "Range not on disk. Open http://<phone-ip>:8765/ and use the index link to pcld_ios_media/_working.mp4 (not a typed URL). Resume at \(formatLANClock(Int(startSec.rounded(.down)))) \(resumeReadable ? "is dense" : "is NOT dense yet"); export filled through ~\(formatLANClock(Int(cursorSec.rounded(.down)))) of ~\(formatLANClock(Int(durationSec.rounded(.down)))). For playback now use pcld_ios_media/loop/op_00.mp4 on the same page, or VLC/ffplay on _working.mp4."
        sendResponse(
            connection: connection,
            status: status,
            contentType: "text/plain; charset=utf-8",
            body: Data(hint.utf8),
            done: done
        )
    }

    private static func sendResponse(
        connection: NWConnection,
        status: Int,
        contentType: String,
        body: Data,
        done: @escaping () -> Void
    ) {
        let phrase: String
        switch status {
        case 200: phrase = "OK"
        case 201: phrase = "Created"
        case 206: phrase = "Partial Content"
        case 403: phrase = "Forbidden"
        case 404: phrase = "Not Found"
        case 405: phrase = "Method Not Allowed"
        case 409: phrase = "Conflict"
        case 411: phrase = "Length Required"
        case 413: phrase = "Payload Too Large"
        case 416: phrase = "Range Not Satisfiable"
        case 503: phrase = "Service Unavailable"
        default: phrase = "Error"
        }
        let header = httpResponseHeader(
            status: status,
            phrase: phrase,
            contentType: contentType,
            contentLength: body.count,
            includeAcceptRanges: false
        )
        var data = Data(header.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
            done()
        })
    }

    private static func formatLANClock(_ totalSeconds: Double) -> String {
        formatLANClock(Int(totalSeconds.rounded(.down)))
    }

    private static func formatLANClock(_ totalSeconds: Int) -> String {
        ExportTimelineLog.wallClock(seconds: Double(max(0, totalSeconds)))
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "wmv", "asf": return "video/x-ms-wmv"
        case "avi": return "video/x-msvideo"
        case "ts", "m2ts", "mts": return "video/mp2t"
        case "txt", "log": return "text/plain; charset=utf-8"
        case "json": return "application/json"
        case "ps1": return "text/plain; charset=utf-8"
        case "sh", "bash": return "text/x-shellscript; charset=utf-8"
        case "bat", "cmd": return "text/plain; charset=utf-8"
        case "py": return "text/x-python; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    // MARK: - IPv4

    /// User-visible device label for mDNS (Settings → General → About → Name).
    private static func deviceMDNSHostLabel() -> String {
        let deviceName = UIDevice.current.name
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if !deviceName.isEmpty {
            return sanitizeMDNSHostLabel(deviceName)
        }
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            let host = String(cString: buffer)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !host.isEmpty, host != "localhost" {
                let base = host.hasSuffix(".local") ? String(host.dropLast(6)) : host
                return sanitizeMDNSHostLabel(base)
            }
        }
        return "iphone"
    }

    private static func sanitizeMDNSHostLabel(_ label: String) -> String {
        let folded = label.folding(options: .diacriticInsensitive, locale: .current)
        let safe = folded.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "'", with: "")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return safe.isEmpty ? "iphone" : safe
    }

    private static func primaryLANIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidates: [(name: String, address: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name.hasPrefix("en") else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(cString: hostname)
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") || ip == "0.0.0.0" { continue }
            candidates.append((name, ip))
        }
        if let en0 = candidates.first(where: { $0.name == "en0" })?.address {
            return en0
        }
        return candidates.first?.address
    }
}
