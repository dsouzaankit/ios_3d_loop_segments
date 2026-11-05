import Darwin
import Foundation
import Network
import UIKit

/// Serves export logs and media from private `Application Support/pcld_ios_media/` on the LAN (HTTP + WebDAV).
/// `pcld_ios_media/` accepts authenticated PUT/MKCOL/DELETE/MOVE for PC scripts and writable media; export pipeline paths stay read-only.
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
    private static var listenerIsReady = false
    private static var startInFlight = false
    private static var addressInUseRetryCount = 0
    private static let maxAddressInUseRetries = 8
    private static var connections: [ObjectIdentifier: NWConnection] = [:]
    private static let queue = DispatchQueue(label: "com.loopsegments.lan-server")
    /// Serializes cancel→rebind so a still-tearing-down NWListener cannot leave :8765 wedged (EADDRINUSE + nothing accepting).
    private static var listenerCancelGeneration = 0
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
        SearchLocationCache.refreshLANSnapshot()
        lock.lock()
        let running = listenerIsReady && listener != nil
        lock.unlock()
        if !running {
        start(log: log)
        }
    }

    static func start(log: @escaping (String) -> Void) {
        guard isEnabled else { return }
        lock.lock()
        if listenerIsReady, listener != nil {
            lock.unlock()
            return
        }
        if startInFlight {
            lock.unlock()
            return
        }
        startInFlight = true
        lock.unlock()

        queue.async {
            defer {
                lock.lock()
                startInFlight = false
                lock.unlock()
            }
            beginListenAttempt(log: log)
        }
    }

    private static func beginListenAttempt(log: @escaping (String) -> Void, delaySeconds: TimeInterval = 0) {
        guard isEnabled else { return }
        if delaySeconds > 0 {
            queue.asyncAfter(deadline: .now() + delaySeconds) {
                beginListenAttempt(log: log)
            }
            return
        }

        lock.lock()
        if listenerIsReady, listener != nil {
            lock.unlock()
            return
        }
        let stale = listener
        listener = nil
        listenerIsReady = false
        let open = connections.values
        connections.removeAll()
        lock.unlock()

        for connection in open {
            connection.cancel()
        }

        // Wait for the prior NWListener to leave the port before binding again.
        lock.lock()
        let skipBonjour = addressInUseRetryCount > 0
        lock.unlock()
        cancelListenerAndWait(stale) {
            Self.bindNewListener(log: log, includeBonjour: !skipBonjour)
        }
    }

    private static func cancelListenerAndWait(_ stale: NWListener?, then work: @escaping () -> Void) {
        guard let stale else {
            work()
            return
        }
        listenerCancelGeneration += 1
        let generation = listenerCancelGeneration
        var finished = false
        let finish: () -> Void = {
            guard !finished else { return }
            finished = true
            work()
        }
        stale.stateUpdateHandler = { state in
            switch state {
            case .cancelled, .failed:
                finish()
            default:
                break
            }
        }
        stale.cancel()
        // Bound wait — some iOS builds never deliver .cancelled after cancel().
        queue.asyncAfter(deadline: .now() + 0.75) {
            guard generation == listenerCancelGeneration else { return }
            finish()
        }
    }

    private static func bindNewListener(log: @escaping (String) -> Void, includeBonjour: Bool = true) {
        guard isEnabled else { return }
        lock.lock()
        if listenerIsReady, listener != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        do {
            let port = NWEndpoint.Port(rawValue: defaultPort)!
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Prefer Wi‑Fi; avoids some cellular/VPN interface bind conflicts on :8765.
            params.requiredInterfaceType = .wifi
            let nwListener = try NWListener(using: params, on: port)
            if includeBonjour {
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
            } else {
                log("LAN export: retrying :\(defaultPort) without Bonjour (port was busy)")
            }
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
                    listenerIsReady = true
                    addressInUseRetryCount = 0
                    advertisedBaseURL = hostURL
                    advertisedIPAddressURL = ipURL
                    lock.unlock()
                    if includeBonjour {
                        log(
                            "LAN export: \(hostURL)\(ip.map { " · IP \($0)" } ?? "") — Bonjour \(bonjourServiceName)._http._tcp"
                        )
                    } else {
                        log(
                            "LAN export: \(hostURL)\(ip.map { " · IP \($0)" } ?? "") — TCP only (no Bonjour)"
                        )
                    }
                    log(
                        "LAN: Windows often cannot resolve .local — use IP above; ping may fail even when HTTP works"
                    )
                    log("LAN: HTTP + WebDAV — pcld_ios_media/ (read + auth PUT/MKCOL for scripts), loop/op_*, logs (not SMB)")
                case .failed(let error):
                    log("LAN export server failed: \(error.localizedDescription)")
                    lock.lock()
                    let retries = addressInUseRetryCount
                    lock.unlock()
                    stopOnQueue(log: nil, resetAddressInUseRetries: false)
                    scheduleListenRetryIfNeeded(log: log, error: error, priorRetries: retries)
                case .cancelled:
                    lock.lock()
                    listenerIsReady = false
                    lock.unlock()
                default:
                    break
                }
            }

            nwListener.newConnectionHandler = { connection in
                // Per-connection queue so one slow/hung request cannot wedge every LAN client
                // (serial `queue` previously blocked all HTTP while TCP still accepted).
                // Set stateUpdateHandler BEFORE start: ready is delivered on connQueue and can
                // race ahead of work still on the listener queue (TCP up, 0 HTTP bytes).
                let id = ObjectIdentifier(connection)
                let connQueue = DispatchQueue(label: "com.loopsegments.lan-conn.\(id)")
                lock.lock()
                connections[id] = connection
                lock.unlock()
                let finished: () -> Void = {
                    lock.lock()
                    connections.removeValue(forKey: id)
                    lock.unlock()
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.stateUpdateHandler = nil
                        Self.receiveRequest(on: connection, done: finished)
                    case .failed, .cancelled:
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        finished()
                    default:
                        break
                    }
                }
                connection.start(queue: connQueue)
            }

            nwListener.start(queue: queue)
        } catch {
            log("LAN export server could not start: \(error.localizedDescription)")
            lock.lock()
            let retries = addressInUseRetryCount
            lock.unlock()
            scheduleListenRetryIfNeeded(log: log, error: error, priorRetries: retries)
        }
    }

    private static func scheduleListenRetryIfNeeded(
        log: @escaping (String) -> Void,
        error: Error,
        priorRetries: Int
    ) {
        guard isEnabled, isAddressAlreadyInUse(error), priorRetries < maxAddressInUseRetries else { return }
        lock.lock()
        addressInUseRetryCount = priorRetries + 1
        let attempt = addressInUseRetryCount
        lock.unlock()
        let delay = min(2.0, 0.4 * Double(attempt))
        log(
            "LAN export: port \(defaultPort) in use — retry \(attempt)/\(maxAddressInUseRetries) in \(String(format: "%.1f", delay))s (force-quit app if this persists)"
        )
        beginListenAttempt(log: log, delaySeconds: delay)
    }

    private static func isAddressAlreadyInUse(_ error: Error) -> Bool {
        if containsAddressInUseCode(error as NSError) { return true }
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, containsAddressInUseCode(underlying) {
            return true
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("already in use")
    }

    private static func containsAddressInUseCode(_ ns: NSError) -> Bool {
        ns.code == 48
            || (ns.domain == NSPOSIXErrorDomain && ns.code == EADDRINUSE)
    }

    static func stop(log: ((String) -> Void)? = nil) {
        queue.async {
            stopOnQueue(log: log, resetAddressInUseRetries: true)
        }
    }

    private static func stopOnQueue(log: ((String) -> Void)?, resetAddressInUseRetries: Bool = true) {
        lock.lock()
        let nwListener = listener
        listener = nil
        listenerIsReady = false
        if resetAddressInUseRetries {
            addressInUseRetryCount = 0
        }
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
        case "POST":
            handlePOST(
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
        case "MOVE":
            handleMOVE(path: path, requestHeaders: requestHeaders, connection: connection, done: done)
        case "OPTIONS":
            sendOptions(connection: connection, done: done)
        case "PROPFIND":
            sendPropfind(path: path, requestHeaders: requestHeaders, connection: connection, done: done)
        case "LOCK":
            sendLock(connection: connection, done: done)
        case "UNLOCK":
            sendNoContent(connection: connection, done: done)
        default:
            sendResponse(connection: connection, status: 405, contentType: "text/plain", body: Data("Allowed: GET, HEAD, PUT, POST, MKCOL, DELETE, MOVE, OPTIONS, PROPFIND, LOCK, UNLOCK".utf8), done: done)
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
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        // Strip ?query so `/xr?mode=working` matches the same route as `/xr`.
        return splitPathAndQuery(trimmed).path
    }

    /// Auth on OPTIONS/PROPFIND/LOCK, WebDAV writes, and WebDAV `GET /`. Media GET stays open (Skybox often omits Authorization on play).
    private static func requiresLANWebDAVAuth(method: String, path: String, requestHeaders: String) -> Bool {
        switch method {
        case "OPTIONS", "PROPFIND", "LOCK", "PUT", "MKCOL", "DELETE", "MOVE":
            return true
        case "POST":
            // Quest /xr posts xr_debug.json with no Basic auth. A 401 here pops the browser
            // login sheet (seen on AR exit) and drops the debug ring.
            if normalizedGETPath(path) == "xr_debug.json" { return false }
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

    /// Protect LAN proxy endpoints (pCloud list + bookmarks) with the same Basic auth as WebDAV.
    @discardableResult
    private static func enforceLANProxyAuth(
        requestHeaders: String,
        connection: NWConnection,
        done: @escaping () -> Void
    ) -> Bool {
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

    /// `GET /` monitor HTML for any non-WebDAV client (browser, curl, tools without `Accept: text/html`).
    private static func shouldServeMinimalMonitorHTML(requestHeaders: String) -> Bool {
        !isWebDAVClient(requestHeaders: requestHeaders)
    }

    /// Chrome desktop may speculative-prefetch same-origin links on the monitor page (PotPlayer WebDAV does not).
    private static func isBrowserPrefetchRequest(requestHeaders: String) -> Bool {
        let lower = requestHeaders.lowercased()
        if lower.contains("sec-purpose: prefetch") { return true }
        if lower.contains("purpose: prefetch") { return true }
        if lower.contains("x-moz: prefetch") { return true }
        if lower.contains("sec-fetch-mode: prefetch") { return true }
        return false
    }

    /// Top-level navigation (address bar, `window.open`, `target=_blank` to media) — not speculative prefetch.
    /// Chrome sends `Sec-Fetch-Mode: navigate` on that first GET, which would otherwise hit the large file no-Range block and return 503.
    private static func isBrowserUserNavigationMediaGET(requestHeaders: String) -> Bool {
        let lower = requestHeaders.lowercased()
        if lower.contains("sec-fetch-mode: navigate") { return true }
        // Chrome adds this for user-activated navigations; helps distinguish from speculative fetches.
        if lower.contains("sec-fetch-user: ?1") { return true }
        // Fallback when Sec-Fetch headers are missing (some Chrome setups/extensions): typical on top-level navigations.
        if lower.contains("upgrade-insecure-requests: 1") { return true }
        return false
    }

    /// Block browser full-file GET of large media during export (prefetch / accidental navigation). WebDAV and Range GET stay allowed.
    private static func shouldRejectBrowserMediaGETDuringExport(
        requestHeaders: String,
        method: String,
        fileURL: URL,
        fileSize: Int64
    ) -> Bool {
        guard method == "GET" else { return false }
        if isBrowserPrefetchRequest(requestHeaders: requestHeaders) { return true }
        guard isBrowserLikeRequest(requestHeaders: requestHeaders) else { return false }
        guard !isWebDAVClient(requestHeaders: requestHeaders) else { return false }
        /// User opened the media URL in a tab (`window.open`, middle-click tab, pasted URL); allow first-byte response without forcing Range.
        if isBrowserUserNavigationMediaGET(requestHeaders: requestHeaders) { return false }
        let hasRange = requestHeaders.split(separator: "\r\n").contains { $0.lowercased().hasPrefix("range:") }
        if hasRange { return false }
        let name = fileURL.lastPathComponent.lowercased()
        if name.hasPrefix("op_") && name.hasSuffix(".mp4") { return false }
        return fileSize > 32 * 1024 * 1024
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
        let raw = path.hasPrefix("/") ? String(path.dropFirst()) : path
        // Drop ?query before route matching (`/xr?mode=working` must hit /xr, not 404).
        let (normalized, query) = splitPathAndQuery(raw)
        if normalized.isEmpty {
            if shouldServeMinimalMonitorHTML(requestHeaders: requestHeaders) {
                sendMinimalIndexHTML(connection, done: done)
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
        if normalized == "browse" {
            if isBrowserLikeRequest(requestHeaders: requestHeaders) {
                sendBrowseIndexHTML(connection, done: done)
                return
            }
            sendResponse(connection: connection, status: 404, contentType: "text/plain", body: Data("Not found".utf8), done: done)
            return
        }
        if normalized == "xr" || normalized == "chroma" {
            if isBrowserLikeRequest(requestHeaders: requestHeaders) {
                sendXRChromaPlayerHTML(connection, done: done)
                return
            }
            sendResponse(connection: connection, status: 404, contentType: "text/plain", body: Data("Not found".utf8), done: done)
            return
        }
        if normalized == "status.json" {
            sendStatusJSON(connection, done: done)
            return
        }
        if normalized == "status_lists.json" {
            sendStatusListsJSON(connection, done: done)
            return
        }
        if normalized == "wifi_www_probe.json" {
            sendJSONPayload(WifiWwwProbe.currentSnapshot().statusJSON(), connection: connection, done: done, status: 200)
            return
        }
        if normalized == "lan_throughput.json" {
            sendLANThroughputGET(connection: connection, done: done)
            return
        }
        if normalized == "xr_tunnel.json" {
            sendXRTunnelGET(connection: connection, done: done)
            return
        }
        if normalized == "xr_debug.json" {
            sendXRDebugGET(connection: connection, done: done)
            return
        }
        let resourcePath = normalized
        if resourcePath == "pcloud_list.json" {
            guard enforceLANProxyAuth(requestHeaders: requestHeaders, connection: connection, done: done) else { return }
            sendPCloudListJSON(folderPath: query["path"] ?? "/", connection: connection, done: done)
            return
        }
        if resourcePath == "pcloud_bookmarks.json" {
            guard enforceLANProxyAuth(requestHeaders: requestHeaders, connection: connection, done: done) else { return }
            sendPCloudBookmarksJSON(connection: connection, done: done)
            return
        }
        if resourcePath == "export_from_url.json" {
            sendExportFromURLUsageJSON(connection: connection, done: done)
            return
        }
        if resourcePath == "export_from_folder.json" {
            sendExportFromFolderUsageJSON(connection: connection, done: done)
            return
        }
        if resourcePath == "export_queue.json" {
            sendExportQueueUsageJSON(connection: connection, done: done)
            return
        }
        if resourcePath == "paused_exports.json" {
            sendPausedExportsUsageJSON(connection: connection, done: done)
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

    private struct LANIndexSnapshot {
        let playback: [ExportFileEntry]
        let logs: [ExportFileEntry]
        let builtAt: Date
    }

    private static var lanIndexSnapshot: LANIndexSnapshot?
    private static let lanIndexSnapshotTTLIdle: TimeInterval = 30
    private static let lanIndexSnapshotTTLExport: TimeInterval = 45
    private static let lanStatusPollMs = 60_000
    private static let lanStatusListsPollMs = 120_000
    private static var lastLANMetricsRefresh: Date?
    private static let lanMetricsRefreshMinInterval: TimeInterval = 45
    private static let lanStatusFilesCap = 48

    private static var lanIndexSnapshotTTL: TimeInterval {
        ExportPlaybackState.shared.isLANExportActive
            ? lanIndexSnapshotTTLExport
            : lanIndexSnapshotTTLIdle
    }

    private static func exportFileEntry(relativePath: String) -> ExportFileEntry? {
        guard let url = resolveExportFile(relativePath: relativePath) else { return nil }
        let fm = FileManager.default
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = attrs?[.modificationDate] as? Date
        return ExportFileEntry(name: relativePath, url: url, size: size, modified: modified)
    }

    private static func buildLANIndexSnapshot() -> LANIndexSnapshot {
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

    private static func currentLANIndexSnapshot() -> LANIndexSnapshot {
        if let cached = lanIndexSnapshot,
           Date().timeIntervalSince(cached.builtAt) < lanIndexSnapshotTTL {
            return cached
        }
        let snapshot = buildLANIndexSnapshot()
        lanIndexSnapshot = snapshot
        return snapshot
    }

    private static func statusFilesJSONArray(from index: LANIndexSnapshot) -> [[String: Any]] {
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

    private static func listExportFiles() -> [ExportFileEntry] {
        let index = currentLANIndexSnapshot()
        return index.playback + index.logs
    }

    private static let archivePlaybackPrefix = "\(ExportPaths.mediaExportFolderName)/archive/"
    private static let parkedPlaybackPrefix = "\(ExportPaths.mediaExportFolderName)/\(ExportParkedMedia.folderName)/"

    private static func isLANExportLogRelativePath(_ relativePath: String) -> Bool {
        ExportPaths.isLANExportLogRelativePath(relativePath)
            || ExportPaths.canonicalLANLogRelativePath(relativePath) != nil
    }

    /// Playback/media paths (active first, then capped `archive/` newest-first).
    private static func listExportFilesForPlaybackIndex() -> [ExportFileEntry] {
        currentLANIndexSnapshot().playback
    }

    /// `pcld_ios_media/logs/export_*.txt` (live + history) — newest first.
    private static func listExportLogEntriesForLANIndex() -> [ExportFileEntry] {
        currentLANIndexSnapshot().logs.sorted { lhs, rhs in
            exportLogSortKey(lhs) > exportLogSortKey(rhs)
        }
    }

    private static func exportLogSortKey(_ entry: ExportFileEntry) -> Date {
        let fileName = (entry.name as NSString).lastPathComponent
        if entry.name.hasPrefix("\(ExportPaths.exportLogsLANPrefix)/") {
            return ExportPaths.exportLogFileSortDate(fileName: fileName)
        }
        return entry.modified ?? .distantPast
    }

    private static func playbackArchiveSortKey(_ entry: ExportFileEntry) -> Date {
        let fileName = (entry.name as NSString).lastPathComponent
        if let stamped = ExportMediaArchive.archivedMediaSortDate(fileName: fileName) {
            return stamped
        }
        return entry.modified ?? .distantPast
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
            ExportPaths.pathRelativeToExports(ExportPaths.latestLogTextURL),
            ExportPaths.pathRelativeToExports(ExportPaths.exportProgressURL),
            "status.json",
        ]
    }

    private static func allowedServableRelativePaths() -> Set<String> {
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

    private static func mediaPropfindChildDepthLimit(from depth: Int) -> Int {
        let requested = depth >= 2 ? 2 : max(0, depth)
        if ExportPlaybackState.shared.isLANExportActive {
            return min(requested, 1)
        }
        return min(requested, 3)
    }

    /// Root PROPFIND/GET-DAV children — light path during export (no archive scan / full log sort).
    private static func propfindRootChildEntries() -> [ExportFileEntry] {
        if ExportPlaybackState.shared.isLANExportActive {
            return propfindRootChildEntriesDuringExport()
        }
        return listExportFilesForPlaybackIndex() + listExportLogEntriesForLANIndex()
    }

    private static func propfindRootChildEntriesDuringExport() -> [ExportFileEntry] {
        autoreleasepool {
            let paths = ExportPaths.listLANPlaybackIndexRelativePaths(maxArchiveEntries: 0)
                + ExportPaths.listLANLogIndexRelativePaths(maxHistoryEntries: 4)
            return paths.compactMap { exportFileEntry(relativePath: $0) }
        }
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

    private static func handlePOST(
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

    /// Local rename/relocate under writable `pcld_ios_media/` paths (no LAN download). Pipeline slots stay 403.
    private static func handleMOVE(
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

    private static func sendCreated(connection: NWConnection, done: @escaping () -> Void) {
        let header = "HTTP/1.1 201 Created\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
            connection.cancel()
            done()
        })
    }

    private static func sendOptions(connection: NWConnection, done: @escaping () -> Void) {
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

    private static func htmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Media/archive anchor during export: real `href` (copy link, middle-click) + new tab so the LAN page stays open.
    private static func lanMediaClickAnchor(relativePath: String, innerHTML: String, extraClass: String = "") -> String {
        let pathAttr = htmlEscape(relativePath)
        let cls = extraClass.isEmpty ? "lan-media-link" : "lan-media-link \(extraClass)"
        return "<a href=\"\(pathAttr)\" class=\"\(cls)\" target=\"_blank\" rel=\"noopener noreferrer\">\(innerHTML)</a>"
    }

    private static func lanMediaListUsesClickOnly(relativePath: String) -> Bool {
        ExportPlaybackState.shared.isLANExportActive
            && ExportPaths.isLANBrowsableMediaRelativePath(relativePath)
    }

    /// Playback list link — direct `href` when idle; new-tab `href` during export. Separate browser `#t=` when seek &gt; 0.
    private static func lanIndexPlaybackLinks(relativePath name: String, resumeStartSec: Int) -> String {
        let escaped = htmlEscape(name)
        if lanMediaListUsesClickOnly(relativePath: name) {
            let primary = lanMediaClickAnchor(relativePath: name, innerHTML: escaped)
            guard resumeStartSec > 0 else { return primary }
            let resumePath = "\(name)#t=\(resumeStartSec)"
            let resumeLabel = htmlEscape("browser #t=\(formatLANClock(resumeStartSec))")
            return """
                \(primary) · \(lanMediaClickAnchor(relativePath: resumePath, innerHTML: resumeLabel, extraClass: "lan-browser-resume"))
                """
        }
        let primary = "<a href=\"\(escaped)\">\(escaped)</a>"
        guard resumeStartSec > 0 else { return primary }
        return """
            \(primary) · <a href="\(escaped)#t=\(resumeStartSec)" class="lan-browser-resume">browser #t=\(formatLANClock(resumeStartSec))</a>
            """
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
        let showResume = phase == "paused"
        let actionsHidden = showResume ? "" : " style=\"display:none\""
        let phaseClass = phase == "running" ? " is-active" : (phase == "paused" ? " is-paused" : "")
        return """
        <div id="lan-export-source-wrap" class="export-source-line\(phaseClass)"\(hidden)>
          <div class="export-source-main">
            <strong id="lan-export-source-label">\(label):</strong>
            <span id="lan-export-source-name">\(name)</span>
          </div>
          <div class="export-source-actions" id="lan-export-source-actions"\(actionsHidden)>
            <button type="button" id="export-resume">Start export</button>
          </div>
        </div>
        """
    }

    private static func htmlPlaybackStatusLine(_ line: String) -> String {
        """
        <p><strong id="lan-playback-line">\(htmlEscape(line))</strong></p>
        """
    }

    /// Poll `status.json` for export source + LAN playback stats; lists on `status_lists.json`.
    /// `monitorOnly` — skip pCloud bookmark fetch on list poll. `deferAutoPoll` — `/browse` during export.
    private static func htmlLANLiveRefreshScript(
        monitorOnly: Bool = false,
        deferAutoPoll: Bool = false
    ) -> String {
        let bookmarkPoll = monitorOnly
            ? ""
            : """
            if (typeof window.refreshLANBookmarks === "function") {
              window.refreshLANBookmarks().catch(function () {});
            }
            """
        let autoPollStart = deferAutoPoll
            ? ""
            : """
            poll();
            setTimeout(pollLists, 5000);
            setInterval(poll, pollMs);
            setInterval(pollLists, listPollMs);
            """
        return """
        <script>
        (function () {
          var pollMs = \(lanStatusPollMs);
          var listPollMs = \(lanStatusListsPollMs);
          function esc(s) {
            return String(s)
              .replace(/&/g, "&amp;")
              .replace(/</g, "&lt;")
              .replace(/"/g, "&quot;");
          }
          function setMediaMaintenanceEnabled(enabled) {
            // Trim/Clear only — LAN speed test stays available during export (cellular WAN vs Wi‑Fi LAN).
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
            if (actions) actions.style.display = src.phase === "paused" ? "" : "none";
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
              var files = document.getElementById("lan-playback-files");
              if (files) files.innerHTML = j.playbackListHTML;
            }
            if (typeof j.exportLogsListHTML === "string") {
              var logs = document.getElementById("lan-export-logs");
              if (logs) logs.innerHTML = j.exportLogsListHTML;
            }
          }
          window.refreshLANPlayback = function () {
            return fetch("status.json", { cache: "no-store" })
              .then(function (r) { return r.json(); })
              .then(function (j) { applyPlaybackSection(j); return j; });
          };
          function applyLists(j) {
            if (!j) return;
            if (typeof j.playbackListHTML === "string") {
              var files = document.getElementById("lan-playback-files");
              if (files) files.innerHTML = j.playbackListHTML;
            }
            if (typeof j.exportLogsListHTML === "string") {
              var logs = document.getElementById("lan-export-logs");
              if (logs) logs.innerHTML = j.exportLogsListHTML;
            }
            if (typeof window.refreshLANLoopPlaylist === "function") {
              window.refreshLANLoopPlaylist(j.files);
            }
          }
          function pollLists() {
            fetch("status_lists.json", { cache: "no-store" })
              .then(function (r) { return r.json(); })
              .then(applyLists)
              .catch(function () {});
          }
          function poll() {
            \(bookmarkPoll)
            fetch("status.json", { cache: "no-store" })
              .then(function (r) { return r.json(); })
              .then(function (j) {
                applyExportSource(j.exportSource);
                applyLive(j.lanLive);
                applyPendingQueue(j.pendingExportQueue);
                applyPausedExports(j.pausedExports);
                if (typeof j.playbackStatusHTML === "string") {
                  var status = document.getElementById("lan-playback-status");
                  if (status) status.innerHTML = j.playbackStatusHTML;
                }
              })
              .catch(function () {});
          }
          \(htmlPendingQueueClientHelpersJS())
          wirePendingQueue();
          \(autoPollStart)
        })();
        </script>
        """
    }

    private static func refreshLANMetricsBeforeStatusResponse() {
        let now = Date()
        if let last = lastLANMetricsRefresh,
           now.timeIntervalSince(last) < lanMetricsRefreshMinInterval {
            return
        }
        lastLANMetricsRefresh = now
        // Never block the LAN connection queue on sparse/_working probes (can stall HTTP for all clients).
        DispatchQueue.global(qos: .utility).async {
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
            if FileManager.default.fileExists(atPath: ExportPaths.workingSourceURL.path) {
                WorkingSourceSparseCatalog.refreshPlaybackState(for: ExportPaths.workingSourceURL)
            }
        }
    }

    private static func playbackStatusHTMLBlock() -> String {
        let usesVanilla = ExportPlaybackState.shared.usesVanillaDownloadForLAN()
        if usesVanilla {
            let rel = ExportPlaybackState.shared.vanillaLANRelativePath()
            let line = ExportPlaybackState.shared.lanPlayableStatusLine()
            let startSec = ExportPlaybackState.shared.frozenPlaybackStartSecondsInt
            let seekNote = startSec > 0
                ? "<p><em>Export seek <code>\(formatLANClock(startSec))</code> — use the plain file link for WebDAV/PotPlayer; use <strong>browser #t=</strong> on the index for Quest-style resume (do not copy the <code>#t=</code> URL into other players). Download grows from 0:00.</em></p>"
                : ""
            return """
            \(htmlPlaybackStatusLine(line))
            \(htmlDashboardStatsBlock())
            <p><em>Vanilla download — <code>\(rel)</code> (full file, original extension; not sparse <code>_working.mp4</code>).</em></p>
            \(seekNote)
            <p>Prefer <code>loop/op_00.mp4</code> when segments exist.</p>
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
        if FileManager.default.fileExists(atPath: ExportPaths.workingSourceURL.path) {
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

    private static func playbackMediaFileListHTML() -> String {
        var items: [String] = []
        let entries = listExportFilesForPlaybackIndex()
        let limit = ExportPaths.lanPlaybackArchiveIndexLimit + 12
        let capped = entries.count > limit
        for entry in entries.prefix(limit) {
            let name = entry.name
            // Covered by the Paused section (one row per clip + optional play link).
            if name.hasPrefix(parkedPlaybackPrefix) { continue }
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
                    ? " — leftover faststart sidecar (older builds; not written anymore)"
                    : " — full vanilla WebDAV download (original extension)"
                let seekNote = startSec > 0
                    ? " — export seek \(formatLANClock(startSec)) (download from 0:00)"
                    : ""
                items.append(
                    "<li>\(lanIndexPlaybackLinks(relativePath: name, resumeStartSec: startSec))\(sizeNote)\(vanillaNote)\(seekNote)</li>"
                )
                continue
            }
            if name == ExportPaths.pathRelativeToExports(ExportPaths.workingTranscodedURL) {
                let cursorSec = Int(ExportPlaybackState.shared.exportCursorSeconds.rounded(.down))
                let link = lanMediaListUsesClickOnly(relativePath: name)
                    ? lanMediaClickAnchor(relativePath: name, innerHTML: escaped)
                    : "<a href=\"\(escaped)\">\(escaped)</a>"
                items.append(
                    "<li>\(link)\(sizeNote)" +
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
                items.append(
                    "<li>\(lanIndexPlaybackLinks(relativePath: name, resumeStartSec: startSec))\(sizeNote)\(startNote)</li>"
                )
                continue
            } else if name.hasSuffix(".mp4"),
                      name.contains("\(ExportPaths.mediaExportFolderName)/\(ExportPaths.segmentLoopFolderName)/") {
                note = " — ~60s segment in loop/ (Range supported)"
            } else if name.hasPrefix(archivePlaybackPrefix) {
                note = " — retained export (archive/)"
            } else if name.hasSuffix(".mp4") {
                note = " — sparse in-progress source (seek in player to export start)"
            }
            if lanMediaListUsesClickOnly(relativePath: name) {
                items.append(
                    "<li>\(lanMediaClickAnchor(relativePath: name, innerHTML: escaped))\(sizeNote)\(note)</li>"
                )
            } else {
            items.append("<li><a href=\"\(escaped)\">\(escaped)</a>\(sizeNote)\(note)</li>")
            }
        }
        if capped {
            items.append(
                "<li><em>… \(entries.count - limit) more file(s) on phone — use WebDAV/rclone for full tree.</em></li>"
            )
        }
        if ExportPlaybackState.shared.isLANExportActive {
            items.append(
                "<li><em>Media/archive links use real URLs and open in a new tab during export (LAN page stays open). Large browser GETs without Range are blocked during export. WebDAV unchanged.</em></li>"
            )
        }
        return items.isEmpty
            ? "<li><em>No export files yet — start export on the phone.</em></li>"
            : items.joined()
    }

    /// Same paused queue as the phone Paused tab (not only on-disk `parked/` folders).
    private static func htmlPausedExportListItems() -> [String] {
        let excludeKey = ExportPlaybackState.shared.isLANExportActive
            ? ExportRetentionSourceCatalog.read()?.fileKey
            : nil
        let paused = ResumeStore.pausedExportsForLAN(excludingFileKey: excludeKey, limit: 16)
        guard !paused.isEmpty else { return [] }
        return paused.map { entry in
            let title = entry.resolvedDisplayName.isEmpty ? "Paused export" : entry.resolvedDisplayName
            let label = htmlEscape(title)
            let play: String
            if let rel = ExportParkedMedia.primaryPlaybackRelativePath(forFileKey: entry.fileKey) {
                let linkLabel = htmlEscape(ExportParkedMedia.lanPlaybackLabel(forRelativePath: rel))
                play = lanMediaClickAnchor(relativePath: rel, innerHTML: linkLabel)
            } else if let rootRel = rootPlaybackRelativePathMatchingPaused(fileKey: entry.fileKey) {
                play = lanMediaClickAnchor(relativePath: rootRel, innerHTML: label)
            } else {
                // No on-disk media yet — filename only (Resume button has seek).
                play = "<span>\(label)</span>"
            }
            let resumeControl: String
            if entry.isSourceUnavailable {
                resumeControl = " <span class=\"muted\">\(htmlEscape(ResumeStore.pCloudSourceUnavailableMessage))</span>"
            } else {
                resumeControl = htmlResumeExportButton(for: entry)
            }
            return "<li>\(play)\(resumeControl)</li>"
        }
    }

    /// Soft-paused clip still on root (not yet parked under `parked/`).
    private static func rootPlaybackRelativePathMatchingPaused(fileKey: String) -> String? {
        guard let manifest = ExportRetentionSourceCatalog.read(),
              manifest.fileKey == fileKey else {
            return nil
        }
        if ExportPaths.vanillaPrimaryMediaExistsOnDisk() {
            let item = WebDAVItem(
                href: "",
                name: manifest.sourceFileName,
                isDirectory: false,
                contentLength: nil
            )
            let url = ExportPaths.vanillaPrimaryLocalURL(for: item)
            if FileManager.default.fileExists(atPath: url.path) {
                return ExportPaths.pathRelativeToExports(url)
            }
        }
        if FileManager.default.fileExists(atPath: ExportPaths.workingTranscodedURL.path) {
            return ExportPaths.pathRelativeToExports(ExportPaths.workingTranscodedURL)
        }
        if FileManager.default.fileExists(atPath: ExportPaths.workingSourceURL.path) {
            return ExportPaths.pathRelativeToExports(ExportPaths.workingSourceURL)
        }
        return nil
    }

    /// Resume/Export control beside a parked partial (same trigger path as Browse Export).
    private static func htmlParkedResumeExportButton(relativePath: String) -> String {
        guard let meta = ExportParkedMedia.lanResumeTrigger(forRelativePath: relativePath) else {
            return ""
        }
        return htmlResumeExportButton(
            displayName: meta.displayName,
            href: meta.href,
            folderPath: meta.folderPath,
            seekMs: meta.seekMs ?? 0
        )
    }

    private static func htmlResumeExportButton(for entry: ResumeEntry) -> String {
        htmlResumeExportButton(
            displayName: entry.resolvedDisplayName,
            href: entry.href,
            folderPath: entry.folderPath,
            seekMs: entry.effectiveResumeSeekMs
        )
    }

    private static func htmlResumeExportButton(
        displayName: String,
        href: String?,
        folderPath: String?,
        seekMs: Int64
    ) -> String {
        let name = htmlEscape(displayName)
        let hrefEsc = htmlEscape(href ?? "")
        let folder = htmlEscape(folderPath ?? "")
        let seek = ResumeSeek.clampMs(seekMs, sourceDurationMs: nil)
        let label = seek > 0
            ? "Resume export (\(formatLANClock(Int(seek / 1000))))"
            : "Resume export"
        return " <button type=\"button\" class=\"export-parked\" data-name=\"\(name)\" data-href=\"\(hrefEsc)\" data-folder-path=\"\(folder)\" data-seek-ms=\"\(seek)\">\(htmlEscape(label))</button>"
    }

    private static func htmlPendingQueueListItems(from items: [[String: Any]]) -> String {
        guard !items.isEmpty else {
            return #"<li class="muted"><em>No queued exports</em></li>"#
        }
        return items.map { row in
            let id = htmlEscape("\(row["id"] ?? "")")
            let name = htmlEscape("\(row["displayName"] ?? "")")
            var meta = ""
            if let folder = row["folderPath"] as? String, !folder.isEmpty {
                meta = " <span class=\"muted\">\(htmlEscape(folder))</span>"
            }
            return """
            <li data-id="\(id)"><span class="pending-name">\(name)</span>\(meta) \
            <button type="button" class="pending-remove" data-id="\(id)">Remove</button></li>
            """
        }.joined()
    }

    /// Queued (not-started) FIFO — same as phone Paused tab Queued section.
    private static func htmlPendingQueueSection() -> String {
        let queue = pendingExportQueueStatusPayload()
        let count = queue["count"] as? Int ?? 0
        let items = queue["items"] as? [[String: Any]] ?? []
        let actionsHidden = count == 0 ? " style=\"display:none\"" : ""
        // Collapsed by default (`<details>` without `open`); count stays visible on the summary.
        return """
        <details id="lan-pending-queue-wrap" class="lan-pending-queue">
          <summary id="lan-pending-queue-heading">Queued exports (\(count))</summary>
          <p class="muted">Not started yet. Auto-starts when idle after finish/Stop. User Pause holds the queue.</p>
          <p id="lan-pending-queue-actions"\(actionsHidden)>
            <button type="button" id="lan-pending-clear">Clear queue</button>
          </p>
          <ul id="lan-pending-queue">
          \(htmlPendingQueueListItems(from: items))
          </ul>
        </details>
        """
    }

    /// Paused checkpoints — same rows as phone Paused tab (not pending FIFO).
    private static func htmlPausedExportsSection() -> String {
        let excludeKey = ExportPlaybackState.shared.isLANExportActive
            ? ExportRetentionSourceCatalog.read()?.fileKey
            : nil
        let paused = ResumeStore.pausedExportsForLAN(excludingFileKey: excludeKey, limit: 16)
        let count = paused.count
        let actionsHidden = count == 0 ? " style=\"display:none\"" : ""
        let listHTML: String = {
            let rows = htmlPausedExportListItems()
            if rows.isEmpty {
                return #"<li class="muted"><em>No paused exports</em></li>"#
            }
            return rows.joined()
        }()
        return """
        <details id="lan-paused-wrap" class="lan-paused-exports">
          <summary id="lan-paused-heading">Paused exports (\(count))</summary>
          <p class="muted">Checkpoints from soft-pause / Pause. Unavailable rows (missing from saved pCloud folder) have no Resume — redo search / re-export from companion, or Copy name / Search in Browse on the phone. Move to queued appends available rows onto FIFO as fresh jobs (drops checkpoints / parked media; skips unavailable). Clear removes parked media; live export is kept.</p>
          <p id="lan-paused-actions"\(actionsHidden)>
            <button type="button" id="lan-paused-queue-all">Move to queued</button>
            <button type="button" id="lan-paused-clear">Clear paused</button>
          </p>
          <ul id="lan-paused-list">
          \(listHTML)
          </ul>
        </details>
        """
    }

    private static func pausedExportsStatusPayload() -> [String: Any] {
        let excludeKey = ExportPlaybackState.shared.isLANExportActive
            ? ExportRetentionSourceCatalog.read()?.fileKey
            : nil
        let paused = ResumeStore.pausedExportsForLAN(excludingFileKey: excludeKey, limit: 16)
        let rows = htmlPausedExportListItems()
        let listHTML = rows.isEmpty
            ? #"<li class="muted"><em>No paused exports</em></li>"#
            : rows.joined()
        return [
            "count": paused.count,
            "listHTML": listHTML,
        ]
    }

    /// JS helpers for queue list + Remove/Clear and paused Clear / Move to queued (Basic auth).
    private static func htmlPendingQueueClientHelpersJS() -> String {
        let user = lanWebDAVUsername
        let pass = lanWebDAVPassword
        return """
          var QUEUE_AUTH = "Basic " + btoa("\(user):\(pass)");
          function applyPendingQueue(q) {
            var ul = document.getElementById("lan-pending-queue");
            var heading = document.getElementById("lan-pending-queue-heading");
            var actions = document.getElementById("lan-pending-queue-actions");
            if (!ul) return;
            var items = (q && q.items) ? q.items : [];
            var count = (q && typeof q.count === "number") ? q.count : items.length;
            if (heading) heading.textContent = "Queued exports (" + count + ")";
            if (actions) actions.style.display = count ? "" : "none";
            if (!items.length) {
              ul.innerHTML = '<li class="muted"><em>No queued exports</em></li>';
              return;
            }
            ul.innerHTML = items.map(function (it) {
              var id = esc(it.id || "");
              var name = esc(it.displayName || "");
              var folder = it.folderPath ? (' <span class="muted">' + esc(it.folderPath) + '</span>') : "";
              return '<li data-id="' + id + '"><span class="pending-name">' + name + '</span>' + folder
                + ' <button type="button" class="pending-remove" data-id="' + id + '">Remove</button></li>';
            }).join("");
          }
          function applyPausedExports(p) {
            var ul = document.getElementById("lan-paused-list");
            var heading = document.getElementById("lan-paused-heading");
            var actions = document.getElementById("lan-paused-actions");
            if (!ul) return;
            var count = (p && typeof p.count === "number") ? p.count : 0;
            if (heading) heading.textContent = "Paused exports (" + count + ")";
            if (actions) actions.style.display = count ? "" : "none";
            if (p && typeof p.listHTML === "string") {
              ul.innerHTML = p.listHTML;
              return;
            }
            ul.innerHTML = '<li class="muted"><em>No paused exports</em></li>';
          }
          function postQueueAction(body) {
            return fetch("export_queue.json", {
              method: "POST",
              headers: { "Authorization": QUEUE_AUTH, "Content-Type": "application/json" },
              body: JSON.stringify(body),
              cache: "no-store"
            }).then(function (r) {
              return r.json().then(function (j) { return { ok: r.ok, j: j }; }).catch(function () {
                return { ok: r.ok, j: null };
              });
            });
          }
          function postPausedAction(body) {
            return fetch("paused_exports.json", {
              method: "POST",
              headers: { "Authorization": QUEUE_AUTH, "Content-Type": "application/json" },
              body: JSON.stringify(body),
              cache: "no-store"
            }).then(function (r) {
              return r.json().then(function (j) { return { ok: r.ok, j: j }; }).catch(function () {
                return { ok: r.ok, j: null };
              });
            });
          }
          function wirePendingQueue() {
            var ul = document.getElementById("lan-pending-queue");
            if (ul && !ul.getAttribute("data-ls-wired")) {
              ul.setAttribute("data-ls-wired", "1");
              ul.addEventListener("click", function (ev) {
                var t = ev.target;
                var btn = (t && t.closest) ? t.closest(".pending-remove") : null;
                if (!btn && t && t.classList && t.classList.contains("pending-remove")) btn = t;
                if (!btn) return;
                var id = btn.getAttribute("data-id") || "";
                if (!id) return;
                btn.disabled = true;
                postQueueAction({ action: "remove", id: id })
                  .then(function (res) {
                    if (res.j && res.j.pendingExportQueue) applyPendingQueue(res.j.pendingExportQueue);
                  })
                  .catch(function () {})
                  .finally(function () { btn.disabled = false; });
              });
            }
            var clearBtn = document.getElementById("lan-pending-clear");
            if (clearBtn && !clearBtn.getAttribute("data-ls-wired")) {
              clearBtn.setAttribute("data-ls-wired", "1");
              clearBtn.addEventListener("click", function () {
                if (!window.confirm("Clear all queued exports?")) return;
                clearBtn.disabled = true;
                postQueueAction({ action: "clear" })
                  .then(function (res) {
                    if (res.j && res.j.pendingExportQueue) applyPendingQueue(res.j.pendingExportQueue);
                    else applyPendingQueue({ count: 0, items: [] });
                  })
                  .catch(function () {})
                  .finally(function () { clearBtn.disabled = false; });
              });
            }
            var clearPaused = document.getElementById("lan-paused-clear");
            if (clearPaused && !clearPaused.getAttribute("data-ls-wired")) {
              clearPaused.setAttribute("data-ls-wired", "1");
              clearPaused.addEventListener("click", function () {
                if (!window.confirm("Clear all paused exports? Parked media is removed. Live export is kept.")) return;
                clearPaused.disabled = true;
                postPausedAction({ action: "clear" })
                  .then(function (res) {
                    if (res.j && res.j.pausedExports) applyPausedExports(res.j.pausedExports);
                    else applyPausedExports({ count: 0, listHTML: '<li class="muted"><em>No paused exports</em></li>' });
                    if (window.refreshLANPlayback) {
                      try { window.refreshLANPlayback(); } catch (e) {}
                    }
                  })
                  .catch(function () {})
                  .finally(function () { clearPaused.disabled = false; });
              });
            }
            var queueAllPaused = document.getElementById("lan-paused-queue-all");
            if (queueAllPaused && !queueAllPaused.getAttribute("data-ls-wired")) {
              queueAllPaused.setAttribute("data-ls-wired", "1");
              queueAllPaused.addEventListener("click", function () {
                queueAllPaused.disabled = true;
                postPausedAction({ action: "queue_all" })
                  .then(function (res) {
                    if (res.j && res.j.pausedExports) applyPausedExports(res.j.pausedExports);
                    else applyPausedExports({ count: 0, listHTML: '<li class="muted"><em>No paused exports</em></li>' });
                    if (res.j && res.j.pendingExportQueue) applyPendingQueue(res.j.pendingExportQueue);
                    if (window.refreshLANPlayback) {
                      try { window.refreshLANPlayback(); } catch (e) {}
                    }
                  })
                  .catch(function () {})
                  .finally(function () { queueAllPaused.disabled = false; });
              });
            }
          }
        """
    }

    private static func htmlLANExportLogListItems(relativePaths: [String]) -> String {
        relativePaths.map { rel in
            let escaped = htmlEscape(rel)
            return "<li><a href=\"\(escaped)\">\(escaped)</a></li>"
        }.joined()
    }

    /// During export: live log plus auxiliary traces (e.g. `search_debug.txt`) without scanning history.
    private static func htmlLANMinimalExportLogLinks() -> String {
        var paths = [ExportPaths.pathRelativeToExports(ExportPaths.latestLogTextURL)]
        for aux in ExportPaths.listLANAuxiliaryLogRelativePaths() where !paths.contains(aux) {
            paths.append(aux)
        }
        return htmlLANExportLogListItems(relativePaths: paths)
    }

    private static func htmlMonitorQuickLogLinks() -> String {
        var links = [
            #"<a href="export_latest.txt">export_latest.txt</a>"#,
            #"<a href="status.json">status.json</a>"#,
            #"<a href="wifi_www_probe.json">wifi_www_probe.json</a>"#,
            #"<a href="lan_throughput.json">lan_throughput.json</a>"#,
            #"<a href="xr_tunnel.json">xr_tunnel.json</a>"#,
            #"<a href="xr_debug.json">xr_debug.json</a>"#,
            "<a href=\"\(LANExportTriggerControl.ackRelativePath)\">export_trigger.ack.json</a>",
            #"<a href="export_from_folder.json">export_from_folder.json</a>"#,
            #"<a href="export_queue.json">export_queue.json</a>"#,
            #"<a href="paused_exports.json">paused_exports.json</a>"#,
            "<a href=\"\(PendingExportQueue.relativePath)\">export_pending_queue.json</a>",
        ]
        if FileManager.default.fileExists(atPath: ExportPaths.searchDebugLogURL.path) {
            links.append(#"<a href="search_debug.txt">search_debug.txt</a>"#)
        }
        if FileManager.default.fileExists(atPath: ExportPaths.searchCacheSnapshotURL.path) {
            links.append(#"<a href="search_cache.json">search_cache.json</a>"#)
        }
        return links.joined(separator: " · ")
    }

    private static func exportLogsFileListHTML() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var items: [String] = []
        for entry in listExportLogEntriesForLANIndex() {
            let escaped = htmlEscape(entry.name)
            var meta = ""
            if entry.size > 0 {
                meta += " (\(entry.size / 1024) KB)"
            }
            if let modified = entry.modified {
                meta += " — \(htmlEscape(formatter.string(from: modified)))"
            }
            items.append("<li><a href=\"\(escaped)\">\(escaped)</a>\(meta)</li>")
        }
        return items.isEmpty
            ? "<li><em>No export logs yet.</em></li>"
            : items.joined()
    }

    private static func htmlPlaybackStatusShell() -> String {
        """
        <p><strong id="lan-playback-line">LAN playback</strong></p>
        <ul id="lan-dashboard-stats"></ul>
        """
    }

    /// Playback line + dashboard for first paint during export (manual refresh updates thereafter).
    private static func htmlPlaybackStatusLiveShell() -> String {
        let line = ExportPlaybackState.shared.lanPlayableStatusLine()
        return """
        \(htmlPlaybackStatusLine(line))
        \(htmlDashboardStatsBlock())
        """
    }

    private static func htmlExportSourceLineShell() -> String {
        """
        <div id="lan-export-source-wrap" class="export-source-line" style="display:none">
          <div class="export-source-main">
            <strong id="lan-export-source-label">Export source:</strong>
            <span id="lan-export-source-name"></span>
          </div>
          <div class="export-source-actions" id="lan-export-source-actions" style="display:none">
            <button type="button" id="export-resume">Start export</button>
          </div>
        </div>
        """
    }

    private static func htmlMonitorStaticPlaybackLinks() -> String {
        var items: [String] = []
        let fm = FileManager.default
        for index in 0 ..< ExportPaths.segmentFileCount {
            let url = ExportPaths.segmentURL(index: index)
            guard fm.fileExists(atPath: url.path) else { continue }
            let rel = ExportPaths.pathRelativeToExports(url)
            let esc = htmlEscape(rel)
            let link = lanMediaListUsesClickOnly(relativePath: rel)
                ? lanMediaClickAnchor(relativePath: rel, innerHTML: esc)
                : "<a href=\"\(esc)\">\(esc)</a>"
            items.append("<li>\(link)</li>")
        }
        if fm.fileExists(atPath: ExportPaths.workingTranscodedURL.path) {
            let rel = ExportPaths.pathRelativeToExports(ExportPaths.workingTranscodedURL)
            let esc = htmlEscape(rel)
            let link = lanMediaListUsesClickOnly(relativePath: rel)
                ? lanMediaClickAnchor(relativePath: rel, innerHTML: esc)
                : "<a href=\"\(esc)\">\(esc)</a>"
            items.append("<li>\(link) (growing transcode)</li>")
        }
        if fm.fileExists(atPath: ExportPaths.workingSourceURL.path) {
            let rel = ExportPaths.pathRelativeToExports(ExportPaths.workingSourceURL)
            let esc = htmlEscape(rel)
            let link = lanMediaListUsesClickOnly(relativePath: rel)
                ? lanMediaClickAnchor(relativePath: rel, innerHTML: esc)
                : "<a href=\"\(esc)\">\(esc)</a>"
            items.append("<li>\(link) (sparse)</li>")
        }
        if ExportPlaybackState.shared.isLANExportActive {
            for rel in ExportPaths.listLANPlaybackIndexRelativePaths(
                maxArchiveEntries: ExportPaths.lanPlaybackArchiveIndexLimitDuringExport
            ) where rel.contains("/archive/") {
                let esc = htmlEscape(rel)
                items.append(
                    "<li>\(lanMediaClickAnchor(relativePath: rel, innerHTML: esc)) (archive)</li>"
                )
            }
        }
        return items.isEmpty
            ? "<li><em>No media files yet.</em></li>"
            : items.joined()
    }

    /// Browser Range download → POST `/lan_throughput.json` (same sidecars as Measure HTTP leg).
    /// Pass `buttonId` to auto-bind (monitor `/`); `/browse` calls `bindLANSpeedTestButton` from the export panel.
    private static func htmlLANSpeedTestScript(
        resultElementId: String? = nil,
        buttonId: String? = nil
    ) -> String {
        let minBytes = LANThroughputSidecar.minCandidateBytes
        let maxBytes = LANThroughputSidecar.maxTransferBytes
        let user = lanWebDAVUsername
        let pass = lanWebDAVPassword
        let resultIdJS = resultElementId.map { "\"\($0)\"" } ?? "null"
        let buttonIdJS = buttonId.map { "\"\($0)\"" } ?? "null"
        return """
        <script>
        (function () {
          var MIN_BYTES = \(minBytes);
          var MAX_BYTES = \(maxBytes);
          /// 10×64 MB ≈ one ~640 MB dense VR window; median damps Wi‑Fi noise.
          var RUN_COUNT = 10;
          var MIN_OK_RUNS = 5;
          var DEFAULT_AUTH = "Basic " + btoa("\(user):\(pass)");
          function isMediaName(name) {
            return /\\.(mp4|m4v|mov|mkv|webm)$/i.test(String(name || ""));
          }
          function isArchivePath(name) {
            var n = String(name || "").replace(/\\\\/g, "/");
            return n.indexOf("/archive/") >= 0 || n.indexOf("archive/") === 0;
          }
          function pickSpeedTestFile(files) {
            var list = Array.isArray(files) ? files : [];
            var eligible = list.filter(function (f) {
              var bytes = Number(f && f.bytes) || 0;
              return isMediaName(f && f.name) && bytes >= MIN_BYTES;
            });
            var archive = eligible.filter(function (f) { return isArchivePath(f.name); });
            var pool = archive.length ? archive : eligible;
            if (!pool.length) return null;
            return pool[Math.floor(Math.random() * pool.length)];
          }
          function medianMbps(samples) {
            var vals = samples.map(function (s) { return s.mbps; }).sort(function (a, b) { return a - b; });
            var mid = Math.floor(vals.length / 2);
            if (vals.length % 2) return vals[mid];
            return (vals[mid - 1] + vals[mid]) / 2;
          }
          function pickMedianSample(samples) {
            var med = medianMbps(samples);
            var best = samples[0];
            var bestDiff = Math.abs(samples[0].mbps - med);
            for (var i = 1; i < samples.length; i++) {
              var d = Math.abs(samples[i].mbps - med);
              if (d < bestDiff) {
                best = samples[i];
                bestDiff = d;
              }
            }
            return { median: med, sample: best };
          }
          function reportLANSpeed(msg, isErr, opts) {
            opts = opts || {};
            if (typeof opts.setStatus === "function") {
              opts.setStatus(msg, !!isErr);
            }
            var rid = opts.resultElementId;
            if (rid) {
              var el = document.getElementById(rid);
              if (el) {
                el.textContent = msg;
                if (window.__lanStatusColor) {
                  el.style.color = window.__lanStatusColor(!!isErr);
                } else {
                  el.style.color = isErr ? "#b00020" : "";
                }
              }
            }
          }
          async function oneRangeTransfer(url, rangeEnd) {
            var t0 = (typeof performance !== "undefined" && performance.now) ? performance.now() : Date.now();
            var resp = await fetch(url, {
              headers: { "Range": "bytes=0-" + rangeEnd },
              cache: "no-store"
            });
            if (!(resp.ok || resp.status === 206)) {
              throw new Error("Range GET HTTP " + resp.status);
            }
            var transferred = 0;
            if (resp.body && typeof resp.body.getReader === "function") {
              var reader = resp.body.getReader();
              while (true) {
                var chunk = await reader.read();
                if (chunk.done) break;
                transferred += chunk.value ? chunk.value.byteLength : 0;
              }
            } else {
              var buf = await resp.arrayBuffer();
              transferred = buf.byteLength;
              buf = null;
            }
            var t1 = (typeof performance !== "undefined" && performance.now) ? performance.now() : Date.now();
            var elapsed = Math.max((t1 - t0) / 1000, 0.001);
            if (transferred < 1024 * 1024) {
              throw new Error("Transfer too small (" + transferred + " bytes)");
            }
            return {
              mbps: (transferred * 8) / (elapsed * 1e6),
              transferredBytes: transferred,
              elapsedSeconds: elapsed
            };
          }
          async function runLANSpeedTest(opts) {
            opts = opts || {};
            var auth = opts.authHeader || DEFAULT_AUTH;
            var btn = opts.buttonId ? document.getElementById(opts.buttonId) : null;
            if (btn) btn.disabled = true;
            reportLANSpeed("LAN speed test: picking media (≥8 MB)…", false, opts);
            try {
              var listsRes = await fetch("status_lists.json", { cache: "no-store" });
              if (!listsRes.ok) throw new Error("status_lists.json HTTP " + listsRes.status);
              var lists = await listsRes.json();
              var pick = pickSpeedTestFile(lists.files);
              if (!pick) {
                throw new Error("No media file ≥ 8 MB on phone (need archive/ or other playback media).");
              }
              var rel = String(pick.name || "").replace(/^\\/+/, "");
              var url = "/" + rel;
              var fileBytes = Number(pick.bytes) || 0;
              var rangeEnd = Math.min(fileBytes, MAX_BYTES) - 1;
              if (rangeEnd < 0) throw new Error("Selected file has no readable bytes");
              var mbLabel = ((rangeEnd + 1) / (1024 * 1024)).toFixed(1);
              var samples = [];
              var failures = [];
              for (var i = 0; i < RUN_COUNT; i++) {
                reportLANSpeed(
                  "LAN speed test " + (i + 1) + "/" + RUN_COUNT + ": " + mbLabel + " MB from " + rel + "…",
                  false,
                  opts
                );
                try {
                  samples.push(await oneRangeTransfer(url, rangeEnd));
                } catch (runErr) {
                  failures.push((runErr && runErr.message) ? runErr.message : String(runErr));
                }
              }
              if (samples.length < MIN_OK_RUNS) {
                throw new Error(
                  "Need ≥" + MIN_OK_RUNS + " successful transfers (got " + samples.length + ")"
                    + (failures.length ? (": " + failures[0]) : "")
                );
              }
              var picked = pickMedianSample(samples);
              var mbps = picked.median;
              var sample = picked.sample;
              var listStr = samples.map(function (s) { return s.mbps.toFixed(1); }).join(", ");
              reportLANSpeed(
                "Median " + mbps.toFixed(1) + " Mbps of [" + listStr + "] — writing lan_throughput.json…",
                false,
                opts
              );
              var post = await fetch("lan_throughput.json", {
                method: "POST",
                headers: {
                  "Authorization": auth,
                  "Content-Type": "application/json"
                },
                body: JSON.stringify({
                  measuredMbps: mbps,
                  transferredBytes: sample.transferredBytes,
                  elapsedSeconds: sample.elapsedSeconds,
                  sourceUrl: url,
                  sourcePath: rel,
                  note: "LAN page HTTP Range ×" + samples.length
                    + " median (browser). Same sidecars as Measure HTTP leg; no mount / no other-router reboot. Samples Mbps: ["
                    + listStr + "]"
                }),
                cache: "no-store"
              });
              var bodyText = await post.text();
              var j = null;
              try { j = JSON.parse(bodyText); } catch (e) {}
              if (!post.ok) {
                throw new Error((j && (j.error || j.message)) || bodyText || ("POST HTTP " + post.status));
              }
              var rec = j && j.recommendedMaxMediaBitrateMbps != null
                ? j.recommendedMaxMediaBitrateMbps
                : "?";
              var measuredOut = j && j.measuredMbps != null ? j.measuredMbps : mbps.toFixed(2);
              reportLANSpeed(
                "LAN median " + measuredOut + " Mbps [" + listStr + "] → recommend " + rec
                  + " Mbps segment bitrate (HTTP-only; no router reboot)",
                false,
                opts
              );
            } catch (e) {
              reportLANSpeed((e && e.message) ? e.message : String(e), true, opts);
            } finally {
              if (btn && !window._exportSourcePending) btn.disabled = false;
            }
          }
          window.runLANSpeedTest = runLANSpeedTest;
          window.bindLANSpeedTestButton = function (opts) {
            opts = opts || {};
            var id = opts.buttonId;
            if (!id) return;
            var btn = document.getElementById(id);
            if (!btn) return;
            btn.onclick = function () {
              runLANSpeedTest(opts);
            };
          };
          var autoButtonId = \(buttonIdJS);
          var autoResultId = \(resultIdJS);
          if (autoButtonId) {
            window.bindLANSpeedTestButton({
              buttonId: autoButtonId,
              resultElementId: autoResultId,
              authHeader: DEFAULT_AUTH
            });
          }
        })();
        </script>
        """
    }

    private static func htmlMonitorManualRefreshScript() -> String {
        """
        <script>
        (function () {
          function esc(s) {
            return String(s)
              .replace(/&/g, "&amp;")
              .replace(/</g, "&lt;")
              .replace(/"/g, "&quot;");
          }
          function setMediaMaintenanceEnabled(enabled) {
            // Trim/Clear only — LAN speed test stays available during export (cellular WAN vs Wi‑Fi LAN).
            ["export-trim-media", "export-clear-media"].forEach(function (id) {
              var btn = document.getElementById(id);
              if (btn) btn.disabled = !enabled;
            });
          }
          function applyExportSource(src) {
            var wrap = document.getElementById("lan-export-source-wrap");
            if (!wrap || !src || !src.displayName) {
              if (wrap) wrap.style.display = "none";
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
            if (actions) actions.style.display = src.phase === "paused" ? "" : "none";
            setMediaMaintenanceEnabled(src.phase !== "running");
          }
          function applyLive(live) {
            if (!live) return;
            var line = document.getElementById("lan-playback-line");
            if (line && live.playableStatusLine) line.textContent = live.playableStatusLine;
            var stats = document.getElementById("lan-dashboard-stats");
            if (stats && live.dashboardLines && live.dashboardLines.length) {
              stats.innerHTML = live.dashboardLines.map(function (l) {
                return "<li>" + esc(l) + "</li>";
              }).join("");
            }
          }
          function applyLists(j) {
            if (!j) return;
            if (typeof j.playbackListHTML === "string") {
              var files = document.getElementById("lan-playback-files");
              if (files) files.innerHTML = j.playbackListHTML;
            }
            if (typeof j.exportLogsListHTML === "string") {
              var logs = document.getElementById("lan-export-logs");
              if (logs) logs.innerHTML = j.exportLogsListHTML;
            }
            if (typeof window.refreshLANLoopPlaylist === "function") {
              window.refreshLANLoopPlaylist(j.files);
            }
          }
          function refreshStatus() {
            var btn = document.getElementById("lan-refresh-status");
            if (btn) btn.disabled = true;
            return fetch("status.json", { cache: "no-store" })
              .then(function (r) { return r.json(); })
              .then(function (j) {
                applyExportSource(j.exportSource);
                applyLive(j.lanLive);
                applyPendingQueue(j.pendingExportQueue);
                applyPausedExports(j.pausedExports);
                if (j.wifiWwwProbe) applyWifiWwwProbe(j.wifiWwwProbe);
                if (typeof j.playbackStatusHTML === "string") {
                  var status = document.getElementById("lan-playback-status");
                  if (status) status.innerHTML = j.playbackStatusHTML;
                }
              })
              .catch(function () {})
              .finally(function () { if (btn) btn.disabled = false; });
          }
          function refreshLists() {
            var btn = document.getElementById("lan-refresh-lists");
            if (btn) btn.disabled = true;
            return fetch("status_lists.json", { cache: "no-store" })
              .then(function (r) { return r.json(); })
              .then(applyLists)
              .catch(function () {})
              .finally(function () { if (btn) btn.disabled = false; });
          }
          var statusBtn = document.getElementById("lan-refresh-status");
          var listsBtn = document.getElementById("lan-refresh-lists");
          if (statusBtn) statusBtn.onclick = refreshStatus;
          if (listsBtn) listsBtn.onclick = refreshLists;
          function applyWifiWwwProbe(j) {
            var el = document.getElementById("lan-wifi-www-probe-result");
            if (!el || !j) return;
            if (j.ok === true) {
              el.textContent = "Phone Wi‑Fi → www OK" + (j.durationMs != null ? (" (" + j.durationMs + " ms)") : "")
                + (j.statusCode != null ? (" HTTP " + j.statusCode) : "");
            } else if (j.ok === false) {
              el.textContent = "Phone Wi‑Fi → www FAIL: " + (j.error || ("HTTP " + (j.statusCode || "?")));
            } else {
              el.textContent = "Phone Wi‑Fi → www: not probed yet";
            }
          }
          function runWifiWwwProbe() {
            var btn = document.getElementById("lan-wifi-www-probe");
            var el = document.getElementById("lan-wifi-www-probe-result");
            if (btn) btn.disabled = true;
            if (el) el.textContent = "Probing Phone Wi‑Fi → www (cellular blocked)…";
            var auth = "Basic " + btoa("\(lanWebDAVUsername):\(lanWebDAVPassword)");
            return fetch("wifi_www_probe.json", {
              method: "POST",
              headers: { "Authorization": auth, "Content-Type": "application/json", "Content-Length": "2" },
              body: "{}",
              cache: "no-store"
            })
              .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
              .then(function (res) {
                if (res.j) applyWifiWwwProbe(res.j);
                else if (el) el.textContent = "Probe failed (bad JSON)";
              })
              .catch(function (e) {
                if (el) el.textContent = "Probe request failed: " + (e && e.message ? e.message : e);
              })
              .finally(function () { if (btn) btn.disabled = false; });
          }
          var probeBtn = document.getElementById("lan-wifi-www-probe");
          if (probeBtn) probeBtn.onclick = runWifiWwwProbe;
          var exportWrap = document.getElementById("lan-export-source-wrap");
          if (exportWrap && exportWrap.classList.contains("is-active")) {
            setMediaMaintenanceEnabled(false);
          }
          function uuid() {
            return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function (c) {
              var r = Math.random() * 16 | 0, v = c === "x" ? r : (r & 0x3 | 0x8);
              return v.toString(16);
            });
          }
          function putTrigger(body) {
            return fetch("\(LANExportTriggerControl.triggerRelativePath)", {
              method: "PUT",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify(body),
              cache: "no-store"
            }).then(function (r) {
              if (!r.ok) throw new Error("trigger HTTP " + r.status);
            });
          }
          function queueParkedResume(btn) {
            if (!btn) return;
            var href = (btn.getAttribute("data-href") || "").trim();
            var name = (btn.getAttribute("data-name") || "").trim();
            var folder = (btn.getAttribute("data-folder-path") || "").trim();
            var seekMs = parseInt(btn.getAttribute("data-seek-ms") || "0", 10) || 0;
            var body = { version: 1, command: "start_export", displayName: name, seekMs: seekMs, id: uuid() };
            if (href) body.href = href;
            if (folder) body.folderPath = folder;
            if (!href && !folder && !name) return;
            putTrigger(body).catch(function () {});
          }
          var playbackFiles = document.getElementById("lan-playback-files");
          if (playbackFiles) {
            playbackFiles.onclick = function (ev) {
              var parkedBtn = ev.target.closest ? ev.target.closest(".export-parked") : null;
              if (!parkedBtn && ev.target.classList && ev.target.classList.contains("export-parked")) {
                parkedBtn = ev.target;
              }
              if (parkedBtn) queueParkedResume(parkedBtn);
            };
          }
          var pausedList = document.getElementById("lan-paused-list");
          if (pausedList) {
            pausedList.onclick = function (ev) {
              var parkedBtn = ev.target.closest ? ev.target.closest(".export-parked") : null;
              if (!parkedBtn && ev.target.classList && ev.target.classList.contains("export-parked")) {
                parkedBtn = ev.target;
              }
              if (parkedBtn) queueParkedResume(parkedBtn);
            };
          }
          var resumeBtn = document.getElementById("export-resume");
          if (resumeBtn) {
            resumeBtn.onclick = function () {
              putTrigger({ version: 1, command: "resume_export", id: uuid() }).catch(function () {});
            };
          }
          \(htmlPendingQueueClientHelpersJS())
          wirePendingQueue();
        })();
        </script>
        """
    }

    /// Lightweight monitor at `/` (playback + logs + resume when paused). No embedded pCloud browser.
    /// Shared light/night CSS + Day/Night toggle script for `/` and `/browse`.
    private static func htmlLANAppearanceHeadBits() -> String {
        let appNight = AppearanceSettings.isNightModeEnabled
        let htmlClass = appNight ? "night" : ""
        let defaultAttr = appNight ? "1" : "0"
        return """
            <html lang="en" class="\(htmlClass)" data-night-default="\(defaultAttr)"><head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="color-scheme" content="dark light">
            <meta http-equiv="x-dns-prefetch-control" content="off">
            <style>
            :root {
              color-scheme: light dark;
              --bg: #f6f7f9;
              --fg: #1a1a1a;
              --muted: #666;
              --panel-bg: #ffffff;
              --panel-border: #ccc;
              --banner-bg: #e8f4fd;
              --banner-border: #5b9bd5;
              --banner-fg: #0d3a5c;
              --source-bg: #f5f8ff;
              --source-border: #c5d4f0;
              --source-active-bg: #fffbea;
              --source-active-border: #c8a415;
              --source-paused-bg: #fff5f0;
              --source-paused-border: #d08050;
              --scroll-bg: #fafafa;
              --scroll-border: #ddd;
              --pin-bg: #fffbea;
              --pin-border: #c8a415;
              --pin-fg: #c8a415;
              --link: #0b57d0;
              --btn-bg: #efefef;
              --btn-border: #bbb;
              --err: #b00020;
              --ok: #333;
              --input-bg: #fff;
              --input-border: #ccc;
            }
            html.night {
              color-scheme: dark;
              --bg: #121418;
              --fg: #e8eaed;
              --muted: #9aa0a6;
              --panel-bg: #1c1f26;
              --panel-border: #3c4048;
              --banner-bg: #1a3050;
              --banner-border: #3d6fa5;
              --banner-fg: #cfe3f7;
              --source-bg: #1a2438;
              --source-border: #3a4f75;
              --source-active-bg: #3a3218;
              --source-active-border: #c8a415;
              --source-paused-bg: #3a2418;
              --source-paused-border: #d08050;
              --scroll-bg: #181b22;
              --scroll-border: #3c4048;
              --pin-bg: #3a3218;
              --pin-border: #c8a415;
              --pin-fg: #e0c060;
              --link: #8ab4f8;
              --btn-bg: #2a2f38;
              --btn-border: #5f6368;
              --err: #ff8a80;
              --ok: #c8cdd3;
              --input-bg: #0f1115;
              --input-border: #5f6368;
            }
            body { font: -apple-system-body; margin: 1.25rem; line-height: 1.4; background: var(--bg); color: var(--fg); }
            a { color: var(--link); }
            code { font-size: 0.9em; }
            ul { padding-left: 1.25rem; }
            .lan-topbar { display: flex; flex-wrap: wrap; gap: 0.75rem; align-items: center; justify-content: space-between; margin: 0 0 0.75rem; }
            .lan-topbar h1 { margin: 0; font-size: 1.35rem; }
            .export-source-line { margin: 0.75rem 0 1rem; padding: 0.65rem 0.85rem; background: var(--source-bg); border: 1px solid var(--source-border); border-radius: 8px; display: flex; flex-wrap: wrap; gap: 0.65rem; align-items: center; justify-content: space-between; }
            .export-source-line.is-active { background: var(--source-active-bg); border-color: var(--source-active-border); }
            .export-source-line.is-paused { background: var(--source-paused-bg); border-color: var(--source-paused-border); }
            .export-source-main { flex: 1 1 12rem; min-width: 0; }
            .export-source-actions { display: flex; flex-wrap: wrap; gap: 0.5rem; flex-shrink: 0; }
            .export-source-line #lan-export-source-name { word-break: break-all; }
            .export-pending-banner { margin: 0.75rem 0 1rem; padding: 0.75rem 1rem; background: var(--banner-bg); border: 1px solid var(--banner-border); border-radius: 8px; color: var(--banner-fg); }
            .export-pending-banner strong { display: block; margin-bottom: 0.25rem; font-size: 1.05em; }
            .export-pending-banner span { font-size: 0.95em; line-height: 1.45; }
            .panel { border: 1px solid var(--panel-border); border-radius: 8px; padding: 1rem; margin: 1rem 0; background: var(--panel-bg); }
            .row { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; margin: 0.5rem 0; }
            button, .btn { font: inherit; padding: 0.35rem 0.65rem; cursor: pointer; background: var(--btn-bg); color: var(--fg); border: 1px solid var(--btn-border); border-radius: 6px; }
            a.btn { display: inline-block; text-decoration: none; color: var(--fg); }
            .lan-xr-links { display: flex; flex-wrap: wrap; gap: 0.5rem; margin: 0.35rem 0 0.75rem; }
            .lan-tunnel-row {
              display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center;
              margin: 0.35rem 0 0.75rem; max-width: 56rem;
            }
            .lan-tunnel-row label { display: flex; flex-wrap: wrap; gap: 0.4rem; align-items: center; flex: 1 1 16rem; }
            .lan-tunnel-row #lan-tunnel-domain { flex: 1 1 14rem; min-width: 12rem; font-family: ui-monospace, monospace; font-size: 0.9em; }
            .lan-tunnel-row #lan-tunnel-status { flex: 1 1 100%; }
            a.btn[data-lan-tunnel-active="1"] { border-color: #166534; }
            .lan-quest-flags {
              margin: 0.25rem 0 0.85rem; padding: 0.75rem 0.85rem; max-width: 56rem;
              border: 1px solid var(--panel-border); border-radius: 8px; background: var(--panel-bg);
            }
            .lan-quest-flags h3 { margin: 0 0 0.35rem; font-size: 1rem; }
            .lan-quest-flags p { margin: 0.35rem 0; font-size: 0.9em; line-height: 1.4; }
            .lan-quest-flags .lan-flag-row {
              display: flex; flex-wrap: wrap; gap: 0.45rem; align-items: center; margin: 0.45rem 0;
            }
            .lan-quest-flags input[readonly] {
              flex: 1 1 14rem; min-width: 12rem; font-family: ui-monospace, monospace; font-size: 0.85em;
            }
            .lan-quest-flags ol { margin: 0.35rem 0 0; padding-left: 1.25rem; font-size: 0.9em; line-height: 1.45; }
            button:disabled, .btn:disabled { opacity: 0.55; cursor: not-allowed; }
            input[type="text"], input[type="url"], input[type="search"], select, textarea {
              background: var(--input-bg); color: var(--fg); border: 1px solid var(--input-border); border-radius: 6px; padding: 0.35rem 0.5rem;
            }
            .pcloud-folders { display: flex; flex-wrap: wrap; gap: 0.5rem; margin: 0.5rem 0; }
            .pcloud-folders .pcloud-dir { flex: 1 1 9rem; max-width: 14rem; text-align: left; }
            .pcloud-pinned-wrap { margin: 0.25rem 0 0.75rem; }
            .pcloud-pinned-wrap .label { margin-bottom: 0.25rem; font-size: 0.9em; color: var(--muted); }
            .pcloud-pinned .pcloud-dir { border: 1px solid var(--pin-border); background: var(--pin-bg); }
            .folder-item { display: flex; flex: 1 1 9rem; max-width: 14rem; align-items: stretch; }
            .folder-item .pcloud-dir { flex: 1; max-width: none; border-top-right-radius: 0; border-bottom-right-radius: 0; }
            .pin-toggle { border-top-left-radius: 0; border-bottom-left-radius: 0; padding: 0.35rem 0.5rem; min-width: 2rem; }
            .pin-toggle.pinned { color: var(--pin-fg); }
            #pcloud-files { list-style: none; padding-left: 0; margin: 0.5rem 0; }
            #pcloud-files li { margin: 0.35rem 0; display: flex; flex-wrap: wrap; gap: 0.35rem; align-items: baseline; }
            .file-meta { color: var(--muted); font-size: 0.85em; }
            .muted { color: var(--muted); font-size: 0.9em; }
            .lan-playback-section { display: flex; flex-direction: column; }
            .lan-playback-media { order: 1; margin: 0 0 0.25rem; }
            .lan-playback-media ul { margin: 0; padding-left: 1.25rem; }
            .lan-playback-logs-block { order: 2; margin: 0; }
            .lan-playback-subhead { margin: 1rem 0 0.35rem; font-size: 1em; font-weight: 600; }
            .lan-playback-logs-scroll {
              max-height: calc(5 * 1.75lh);
              overflow-x: auto;
              overflow-y: auto;
              -webkit-overflow-scrolling: touch;
              overscroll-behavior: contain;
              margin: 0 0 0.5rem;
              padding: 0.2rem 0.4rem 0.2rem 0;
              border: 1px solid var(--scroll-border);
              border-radius: 6px;
              background: var(--scroll-bg);
            }
            .lan-playback-logs-scroll ul { margin: 0; padding-left: 1.25rem; }
            #lan-export-logs li { word-break: break-all; }
            #trigger-status { min-height: 1.2em; }
            .lan-pending-queue { margin: 0.75rem 0 1rem; }
            .lan-pending-queue > summary,
            .lan-paused-exports > summary {
              cursor: pointer;
              font-size: 1.17em;
              font-weight: 600;
            }
            .lan-pending-queue ul,
            .lan-paused-exports ul { margin: 0.25rem 0 0.5rem; padding-left: 1.25rem; }
            .lan-pending-queue .pending-name,
            .lan-paused-exports .pending-name { font-weight: 600; }
            .lan-pending-queue .pending-remove { margin-left: 0.45rem; }
            #lan-pending-queue-actions,
            #lan-paused-actions { margin: 0.25rem 0 0.35rem; }
            .lan-paused-exports { margin: 0.75rem 0 1rem; }
            .lan-loop-player { margin: 0.75rem 0 1rem; }
            .lan-loop-player video {
              display: block; width: 100%; max-width: 56rem; max-height: 50vh;
              background: #000; border-radius: 6px;
            }
            .lan-loop-player .lan-loop-toolbar {
              display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; margin: 0.5rem 0 0;
            }
            .lan-loop-player #lan-loop-label { font-size: 0.9em; word-break: break-all; }
            </style>
            <script>
            (function () {
              var KEY = "loopsegments-lan-night";
              function readNight() {
                var stored = null;
                try { stored = localStorage.getItem(KEY); } catch (e) {}
                if (stored === null) {
                  return document.documentElement.getAttribute("data-night-default") !== "0";
                }
                return stored === "1";
              }
              var night = readNight();
              function apply() {
                document.documentElement.classList.toggle("night", night);
                var btn = document.getElementById("lan-night-toggle");
                if (btn) btn.textContent = night ? "Day mode" : "Night mode";
              }
              window.__lanSetNight = function (v) {
                night = !!v;
                try { localStorage.setItem(KEY, night ? "1" : "0"); } catch (e) {}
                apply();
              };
              window.__lanToggleNight = function () { window.__lanSetNight(!night); };
              window.__lanStatusColor = function (isErr) {
                return isErr ? getComputedStyle(document.documentElement).getPropertyValue("--err").trim() || "#b00020"
                  : getComputedStyle(document.documentElement).getPropertyValue("--ok").trim() || "#333";
              };
              apply();
              document.addEventListener("DOMContentLoaded", apply);
            })();
            </script>
            """
    }

    private static func htmlLANNightModeToggleButton() -> String {
        """
        <button type="button" id="lan-night-toggle" onclick="__lanToggleNight()">Night mode</button>
        """
    }

    /// Quest Browser: chrome://flags insecure-origin helper + this LAN origin to paste.
    private static func htmlLANQuestFlagsBlock() -> String {
        let flagHash = "unsafely-treat-insecure-origin-as-secure"
        let flagsUrl = "chrome://flags/#\(flagHash)"
        let flagsEscaped = htmlEscape(flagsUrl)
        return """
        <details class="lan-quest-flags panel" id="lan-quest-flags" style="margin:0.75rem 0 1rem">
          <summary><strong>Quest Browser — LAN HTTP as secure</strong> <span class="muted">(required for Quest WebXR over LAN HTTP)</span></summary>
          <p class="muted" style="margin-top:0.5rem">Quest WebXR needs a secure context. Use this flag so LAN <code>http://</code> counts as secure (no www hop). Skip only if you use the Cloudflare HTTPS tunnel at the bottom instead.</p>
          <div class="lan-flag-row">
            <a class="btn" id="lan-flags-open" href="\(flagsEscaped)" target="_blank" rel="noopener">Open chrome://flags (new tab)</a>
            <button type="button" id="lan-flags-copy-url" title="Copy chrome://flags URL">Copy flags URL</button>
          </div>
          <div class="lan-flag-row">
            <label for="lan-flags-setting">Flag
              <input type="text" id="lan-flags-setting" readonly value="\(htmlEscape(flagHash))" spellcheck="false">
            </label>
            <button type="button" id="lan-flags-copy-setting">Copy flag name</button>
          </div>
          <div class="lan-flag-row">
            <label for="lan-flags-origin">LAN origin (paste into the flag)
              <input type="text" id="lan-flags-origin" readonly value="" spellcheck="false" aria-live="polite">
            </label>
            <button type="button" id="lan-flags-copy-origin">Copy LAN origin</button>
          </div>
          <ol>
            <li>On <strong>Quest Browser</strong>, open the flags link (or type <code>chrome://flags</code> in the address bar).</li>
            <li>Find <strong>Insecure origins treated as secure</strong> (<code>\(htmlEscape(flagHash))</code>).</li>
            <li>Paste the <strong>LAN origin</strong> above (scheme + host + port, e.g. <code>http://10.0.100.10:8765</code>) — exact match.</li>
            <li>Set Enabled → Relaunch → open this LAN page again → <strong>Open XR chroma</strong> over <strong>http://</strong> → <strong>Enter AR</strong>.</li>
          </ol>
          <p id="lan-flags-status" class="muted" role="status"></p>
        </details>
        """
    }

    private static func htmlLANQuestFlagsScript() -> String {
        """
        <script>
        (function () {
          var FLAG_URL = "chrome://flags/#unsafely-treat-insecure-origin-as-secure";
          var FLAG_NAME = "unsafely-treat-insecure-origin-as-secure";
          var originInput = document.getElementById("lan-flags-origin");
          var status = document.getElementById("lan-flags-status");
          var openBtn = document.getElementById("lan-flags-open");
          function setStatus(msg) {
            if (status) status.textContent = msg || "";
          }
          function lanOrigin() {
            try {
              return String(location.origin || "");
            } catch (e) {
              return "";
            }
          }
          function fillOrigin() {
            if (!originInput) return;
            originInput.value = lanOrigin();
          }
          function copyText(text, okMsg) {
            text = String(text || "");
            if (!text) {
              setStatus("Nothing to copy");
              return;
            }
            function done() { setStatus(okMsg || ("Copied: " + text)); }
            if (navigator.clipboard && navigator.clipboard.writeText) {
              navigator.clipboard.writeText(text).then(done).catch(function () {
                try {
                  originInput.focus();
                  originInput.select();
                  document.execCommand("copy");
                  done();
                } catch (e) {
                  setStatus("Copy failed — select the field manually");
                }
              });
            } else {
              try {
                var ta = document.createElement("textarea");
                ta.value = text;
                document.body.appendChild(ta);
                ta.select();
                document.execCommand("copy");
                document.body.removeChild(ta);
                done();
              } catch (e) {
                setStatus("Copy failed — select the field manually");
              }
            }
          }
          fillOrigin();
          var copyOrigin = document.getElementById("lan-flags-copy-origin");
          var copySetting = document.getElementById("lan-flags-copy-setting");
          var copyFlags = document.getElementById("lan-flags-copy-url");
          if (copyOrigin) copyOrigin.addEventListener("click", function () {
            fillOrigin();
            copyText(originInput && originInput.value, "Copied LAN origin");
          });
          if (copySetting) copySetting.addEventListener("click", function () {
            copyText(FLAG_NAME, "Copied flag name");
          });
          if (copyFlags) copyFlags.addEventListener("click", function () {
            copyText(FLAG_URL, "Copied chrome://flags URL — paste into Quest address bar if the link is blocked");
          });
          if (openBtn) {
            openBtn.addEventListener("click", function (ev) {
              // Some browsers block chrome:// from http pages; keep href for Quest when allowed.
              setStatus("If the new tab did not open, paste chrome://flags into the Quest address bar");
            });
          }
        })();
        </script>
        """
    }

    /// Optional Cloudflare HTTPS tunnel — keep at page bottom (after playback/logs).
    private static func htmlLANCloudflareTunnelBlock() -> String {
        """
        <details class="lan-cf-tunnel-advanced panel" id="lan-cf-tunnel-advanced" style="margin-top:1.5rem">
          <summary><strong>Advanced — Cloudflare HTTPS tunnel</strong> <span class="muted">(optional / slow www hop; prefer Quest flags + LAN HTTP above)</span></summary>
          <p class="muted" style="margin-top:0.5rem">Only if the insecure-origin flag is unavailable. Paste a quick-tunnel host from <code>Start-LoopSegmentsCloudflareTunnel.ps1</code>, then <strong>Update links</strong> so XR buttons open <code>https://…/xr</code> (stored on phone as <code>xr_tunnel.json</code>).</p>
          <p class="lan-tunnel-row">
            <label for="lan-tunnel-domain">Tunnel host
              <input type="text" id="lan-tunnel-domain" placeholder="xxxx.trycloudflare.com or full https://… URL" spellcheck="false" autocomplete="off" inputmode="url" aria-describedby="lan-tunnel-status">
            </label>
            <button type="button" id="lan-tunnel-apply">Update links</button>
            <button type="button" id="lan-tunnel-clear">Clear</button>
            <span id="lan-tunnel-status" class="muted" role="status"></span>
          </p>
        </details>
        \(htmlLANTunnelDomainScript())
        """
    }

    /// Paste Cloudflare quick-tunnel host; rewrite `[data-lan-tunnel-path]` links to `https://host…`.
    /// Persists to phone `xr_tunnel.json` so Quest refresh sees the same host after a PC Update links.
    private static func htmlLANTunnelDomainScript() -> String {
        let user = lanWebDAVUsername
        let pass = lanWebDAVPassword
        return """
        <script>
        (function () {
          var ENDPOINT = "xr_tunnel.json";
          var AUTH = "Basic " + btoa("\(user):\(pass)");
          var input = document.getElementById("lan-tunnel-domain");
          var applyBtn = document.getElementById("lan-tunnel-apply");
          var clearBtn = document.getElementById("lan-tunnel-clear");
          var status = document.getElementById("lan-tunnel-status");
          if (!input || !applyBtn) return;

          function setStatus(msg) {
            if (status) status.textContent = msg || "";
          }
          function tunnelLinks() {
            return document.querySelectorAll("a[data-lan-tunnel-path]");
          }
          function parseHost(raw) {
            var s = String(raw || "").trim();
            if (!s) return "";
            s = s.replace(/\\s+/g, "");
            if (!/^https?:\\/\\//i.test(s)) s = "https://" + s;
            try {
              var u = new URL(s);
              if (!u.hostname) return "";
              return u.host;
            } catch (e) {
              return "";
            }
          }
          function applyHost(host) {
            host = String(host || "").trim();
            tunnelLinks().forEach(function (a) {
              var path = a.getAttribute("data-lan-tunnel-path") || "/xr";
              if (path.charAt(0) !== "/") path = "/" + path;
              if (host) {
                a.href = "https://" + host + path;
                a.setAttribute("data-lan-tunnel-active", "1");
                a.setAttribute("title", a.href);
              } else {
                a.href = path;
                a.removeAttribute("data-lan-tunnel-active");
                a.setAttribute("title", path);
              }
            });
            if (host) {
              setStatus("XR links → https://" + host + "/xr… (saved on phone — refresh Quest to pick up)");
            } else {
              setStatus("XR links use this LAN origin (http) — phone tunnel cleared");
            }
          }
          function saveHost(host) {
            setStatus(host ? "Saving tunnel host on phone…" : "Clearing tunnel host on phone…");
            return fetch(ENDPOINT, {
              method: "POST",
              headers: {
                "Authorization": AUTH,
                "Content-Type": "application/json"
              },
              body: JSON.stringify({ host: host || "" }),
              cache: "no-store"
            }).then(function (r) {
              return r.text().then(function (t) {
                var j = null;
                try { j = JSON.parse(t); } catch (e) {}
                if (!r.ok) {
                  throw new Error((j && (j.error || j.message)) || t || ("HTTP " + r.status));
                }
                return j;
              });
            }).then(function (j) {
              var h = parseHost((j && j.host) || host || "");
              input.value = h;
              applyHost(h);
              return h;
            }).catch(function (e) {
              setStatus("Could not save on phone: " + ((e && e.message) ? e.message : String(e)));
            });
          }
          function applyFromInput() {
            var host = parseHost(input.value);
            if (input.value.trim() && !host) {
              setStatus("Could not parse domain — paste xxxx.trycloudflare.com or https://…");
              return;
            }
            input.value = host;
            applyHost(host);
            saveHost(host);
          }
          applyBtn.addEventListener("click", applyFromInput);
          input.addEventListener("keydown", function (ev) {
            if (ev.key === "Enter") {
              ev.preventDefault();
              applyFromInput();
            }
          });
          if (clearBtn) {
            clearBtn.addEventListener("click", function () {
              input.value = "";
              applyHost("");
              saveHost("");
            });
          }
          setStatus("Loading tunnel host from phone…");
          fetch(ENDPOINT, { cache: "no-store" })
            .then(function (r) { return r.json(); })
            .then(function (j) {
              var h = parseHost((j && j.host) || "");
              input.value = h;
              applyHost(h);
            })
            .catch(function () {
              applyHost("");
              setStatus("No tunnel host on phone yet — paste trycloudflare host → Update links");
            });
        })();
        </script>
        """
    }

    /// Toggle + hidden-by-default HTML5 player for `pcld_ios_media/loop/op_*.mp4`.
    private static func htmlLANLoopPlayerBlock() -> String {
        let loopPrefix = "\(ExportPaths.mediaExportFolderName)/\(ExportPaths.segmentLoopFolderName)/"
        return """
        <p>
          <button type="button" id="lan-loop-player-toggle">Show loop player</button>
        </p>
        <div id="lan-loop-player" class="lan-loop-player panel" style="display:none" hidden>
          <div class="row" style="margin-top:0">
            <strong>Loop folder player</strong>
            <span class="muted">Cycles <code>\(htmlEscape(loopPrefix))op_*.mp4</code> · rate applies to every segment</span>
          </div>
          <video id="lan-loop-video" controls playsinline preload="metadata"></video>
          <div class="lan-loop-toolbar">
            <button type="button" id="lan-loop-prev" title="Previous segment">Prev</button>
            <button type="button" id="lan-loop-play">Play</button>
            <button type="button" id="lan-loop-next" title="Next segment">Next</button>
            <label>Speed
              <select id="lan-loop-rate" aria-label="Playback speed">
                <option value="0.7">0.7×</option>
                <option value="0.8">0.8×</option>
                <option value="0.9">0.9×</option>
                <option value="1" selected>1×</option>
                <option value="1.1">1.1×</option>
                <option value="1.2">1.2×</option>
                <option value="1.3">1.3×</option>
              </select>
            </label>
            <span id="lan-loop-label" class="muted" role="status">Hidden — tap Show loop player</span>
          </div>
        </div>
        <p class="lan-xr-links">
          <a class="btn" href="/xr#loop" id="lan-xr-chroma-link" data-lan-tunnel-path="/xr#loop">Open XR chroma (loop)</a>
          <a class="btn" href="/xr#working" id="lan-xr-working-link" data-lan-tunnel-path="/xr#working">Open XR chroma (working)</a>
          <a class="btn" href="/xr#archive" id="lan-xr-archive-link" data-lan-tunnel-path="/xr#archive">Open XR chroma (archive)</a>
        </p>
        \(htmlLANQuestFlagsBlock())
        \(htmlLANQuestFlagsScript())
        \(htmlLANLoopPlayerScript(loopPrefix: loopPrefix))
        """
    }

    private static func htmlLANLoopPlayerScript(loopPrefix: String) -> String {
        let prefixJS = loopPrefix.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        <script>
        (function () {
          var LOOP_PREFIX = "\(prefixJS)";
          var RATE_KEY = "loopsegments.lan.loopPlayerRate.v1";
          var RATES = [0.7, 0.8, 0.9, 1, 1.1, 1.2, 1.3];
          var playlist = [];
          var index = 0;
          var visible = false;
          var wantPlay = false;
          var video = document.getElementById("lan-loop-video");
          var panel = document.getElementById("lan-loop-player");
          var toggleBtn = document.getElementById("lan-loop-player-toggle");
          var playBtn = document.getElementById("lan-loop-play");
          var prevBtn = document.getElementById("lan-loop-prev");
          var nextBtn = document.getElementById("lan-loop-next");
          var rateSel = document.getElementById("lan-loop-rate");
          var label = document.getElementById("lan-loop-label");
          if (!video || !panel || !toggleBtn) return;

          function setLabel(msg) {
            if (label) label.textContent = msg || "";
          }
          function snapRate(v) {
            var r = Math.round(Number(v) * 10) / 10;
            if (!isFinite(r)) return 1;
            for (var i = 0; i < RATES.length; i++) {
              if (Math.abs(RATES[i] - r) < 0.001) return RATES[i];
            }
            return 1;
          }
          function readRate() {
            var v = 1;
            try {
              var raw = localStorage.getItem(RATE_KEY);
              if (raw != null) v = parseFloat(raw);
            } catch (e) {}
            return snapRate(v);
          }
          function writeRate(v) {
            try { localStorage.setItem(RATE_KEY, String(snapRate(v))); } catch (e) {}
          }
          function applyRate() {
            var v = readRate();
            if (rateSel) rateSel.value = String(v);
            try { video.playbackRate = v; } catch (e) {}
          }
          function isLoopSegmentName(name) {
            var n = String(name || "").replace(/\\\\/g, "/");
            if (n.indexOf(LOOP_PREFIX) !== 0) return false;
            var base = n.slice(LOOP_PREFIX.length);
            if (!base || base.indexOf("/") >= 0) return false;
            if (/staging/i.test(base)) return false;
            return /^op_\\d+\\.(mp4|m4v|mov)$/i.test(base);
          }
          function cacheBust(entry) {
            var q = [];
            if (entry.bytes) q.push("b=" + encodeURIComponent(String(entry.bytes)));
            if (entry.modified) q.push("m=" + encodeURIComponent(String(entry.modified)));
            return q.length ? ("?" + q.join("&")) : "";
          }
          function buildPlaylistFromFiles(files) {
            var list = Array.isArray(files) ? files : [];
            var out = [];
            var seen = {};
            list.forEach(function (f) {
              var name = f && f.name;
              if (!isLoopSegmentName(name)) return;
              if (seen[name]) return;
              seen[name] = true;
              out.push({
                name: name,
                bytes: Number(f.bytes) || 0,
                modified: f.modified || "",
                url: "/" + String(name).replace(/^\\/+/, "") + cacheBust(f)
              });
            });
            out.sort(function (a, b) { return a.name < b.name ? -1 : a.name > b.name ? 1 : 0; });
            if (!out.length) {
              ["op_00.mp4", "op_01.mp4"].forEach(function (base) {
                var name = LOOP_PREFIX + base;
                out.push({ name: name, bytes: 0, modified: "", url: "/" + name });
              });
            }
            return out;
          }
          function stopPull() {
            wantPlay = false;
            try { video.pause(); } catch (e) {}
            try {
              video.removeAttribute("src");
              video.load();
            } catch (e) {}
            if (playBtn) playBtn.textContent = "Play";
          }
          function loadIndex(i, autoplay) {
            if (!playlist.length) {
              setLabel("No loop/op_*.mp4 yet");
              stopPull();
              return;
            }
            index = ((i % playlist.length) + playlist.length) % playlist.length;
            var item = playlist[index];
            wantPlay = !!autoplay;
            video.src = item.url;
            applyRate();
            setLabel((index + 1) + "/" + playlist.length + ": " + item.name);
            if (wantPlay) {
              var p = video.play();
              if (p && typeof p.catch === "function") {
                p.catch(function () { wantPlay = false; if (playBtn) playBtn.textContent = "Play"; });
              }
              if (playBtn) playBtn.textContent = "Pause";
            } else if (playBtn) {
              playBtn.textContent = "Play";
            }
          }
          function refreshPlaylist(files, keepPosition) {
            if (!visible) return;
            var prevName = playlist[index] && playlist[index].name;
            playlist = buildPlaylistFromFiles(files);
            if (!playlist.length) {
              setLabel("No loop/op_*.mp4 yet");
              return;
            }
            var next = 0;
            if (keepPosition && prevName) {
              for (var i = 0; i < playlist.length; i++) {
                if (playlist[i].name === prevName) { next = i; break; }
              }
            }
            var curSrc = video.currentSrc || video.src || "";
            var nextUrl = playlist[next].url;
            var sameFile = prevName && playlist[next] && playlist[next].name === prevName;
            var bustChanged = sameFile && curSrc && curSrc.indexOf(nextUrl) < 0 && nextUrl.indexOf("?") >= 0;
            if (!curSrc || !sameFile || bustChanged) {
              loadIndex(next, wantPlay && !video.paused);
            } else {
              index = next;
              setLabel((index + 1) + "/" + playlist.length + ": " + playlist[index].name);
              applyRate();
            }
          }
          window.refreshLANLoopPlaylist = function (files) {
            refreshPlaylist(files, true);
          };
          function showPlayer() {
            visible = true;
            panel.style.display = "";
            panel.removeAttribute("hidden");
            toggleBtn.textContent = "Hide loop player";
            setLabel("Loading loop playlist…");
            applyRate();
            fetch("status_lists.json", { cache: "no-store" })
              .then(function (r) { return r.json(); })
              .then(function (j) {
                refreshPlaylist(j && j.files, false);
                if (playlist.length) loadIndex(0, false);
              })
              .catch(function () {
                playlist = buildPlaylistFromFiles([]);
                loadIndex(0, false);
              });
          }
          function hidePlayer() {
            visible = false;
            stopPull();
            panel.style.display = "none";
            panel.setAttribute("hidden", "hidden");
            toggleBtn.textContent = "Show loop player";
            setLabel("Hidden — tap Show loop player");
          }
          toggleBtn.onclick = function () {
            if (visible) hidePlayer();
            else showPlayer();
          };
          if (playBtn) {
            playBtn.onclick = function () {
              if (!visible) return;
              if (!playlist.length) {
                setLabel("No loop/op_*.mp4 yet");
                return;
              }
              if (!video.src) {
                loadIndex(index, true);
                return;
              }
              if (video.paused) {
                wantPlay = true;
                var p = video.play();
                if (p && typeof p.catch === "function") p.catch(function () {});
                playBtn.textContent = "Pause";
              } else {
                wantPlay = false;
                video.pause();
                playBtn.textContent = "Play";
              }
            };
          }
          if (prevBtn) {
            prevBtn.onclick = function () {
              if (!visible || !playlist.length) return;
              loadIndex(index - 1, wantPlay || !video.paused);
            };
          }
          if (nextBtn) {
            nextBtn.onclick = function () {
              if (!visible || !playlist.length) return;
              loadIndex(index + 1, wantPlay || !video.paused);
            };
          }
          if (rateSel) {
            rateSel.value = String(readRate());
            rateSel.onchange = function () {
              var v = parseFloat(rateSel.value);
              if (!isFinite(v)) v = 1;
              writeRate(v);
              applyRate();
            };
          }
          video.addEventListener("ended", function () {
            if (!visible || !playlist.length) return;
            loadIndex(index + 1, true);
          });
          video.addEventListener("ratechange", function () {
            // Keep select in sync if browser UI changes rate.
            if (!rateSel) return;
            var v = snapRate(video.playbackRate);
            rateSel.value = String(v);
            writeRate(v);
          });
          video.addEventListener("play", function () {
            wantPlay = true;
            if (playBtn) playBtn.textContent = "Pause";
            applyRate();
          });
          video.addEventListener("pause", function () {
            if (playBtn && video.paused) playBtn.textContent = "Play";
          });
          video.addEventListener("error", function () {
            if (!visible) return;
            var item = playlist[index];
            setLabel("Could not load " + (item && item.name ? item.name : "segment")
              + (playlist.length > 1 ? " — try Next" : " (export segments first)"));
            if (playBtn) playBtn.textContent = "Play";
            wantPlay = false;
          });
        })();
        </script>
        """
    }

    /// Quest Browser WebXR page: 180° SBS + green-screen chroma over loop / media-root / `archive/` media.
    private static func sendXRChromaPlayerHTML(_ connection: NWConnection, done: @escaping () -> Void) {
        autoreleasepool {
            let mediaRoot = "\(ExportPaths.mediaExportFolderName)/"
            let loopPrefix = "\(ExportPaths.mediaExportFolderName)/\(ExportPaths.segmentLoopFolderName)/"
            let archivePrefix = "\(ExportPaths.mediaExportFolderName)/archive/"
            let html = xrChromaPlayerHTML(
                mediaRoot: mediaRoot,
                loopPrefix: loopPrefix,
                archivePrefix: archivePrefix
            )
            sendResponse(
                connection: connection,
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: Data(html.utf8),
                done: done
            )
        }
    }

    private static func xrChromaPlayerHTML(
        mediaRoot: String,
        loopPrefix: String,
        archivePrefix: String
    ) -> String {
        func jsEscape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let mediaRootJS = jsEscape(mediaRoot)
        let prefixJS = jsEscape(loopPrefix)
        let archiveJS = jsEscape(archivePrefix)
        let mediaRootHTML = htmlEscape(mediaRoot)
        return #"""
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>Loop Segments — XR chroma player</title>
          <script src="https://aframe.io/releases/1.6.0/aframe.min.js"></script>
          <script>
          (function () {
            var THREE = window.AFRAME && AFRAME.THREE ? AFRAME.THREE : window.THREE;
            if (!THREE || !window.AFRAME) return;

            // Shared video texture for left/right hemispheres (one decode).
            var __xrVideoTex = null;
            function xrEnsureVideoTexture(video) {
              if (!video || !video.videoWidth) return null;
              if (!__xrVideoTex) {
                __xrVideoTex = new THREE.VideoTexture(video);
                __xrVideoTex.minFilter = THREE.LinearFilter;
                __xrVideoTex.magFilter = THREE.LinearFilter;
                __xrVideoTex.generateMipmaps = false;
                __xrVideoTex.wrapS = THREE.ClampToEdgeWrapping;
                __xrVideoTex.wrapT = THREE.ClampToEdgeWrapping;
                if ("colorSpace" in __xrVideoTex && THREE.SRGBColorSpace) {
                  __xrVideoTex.colorSpace = THREE.SRGBColorSpace;
                } else if ("encoding" in __xrVideoTex && THREE.sRGBEncoding) {
                  __xrVideoTex.encoding = THREE.sRGBEncoding;
                }
              }
              __xrVideoTex.needsUpdate = true;
              return __xrVideoTex;
            }

            // Shared DOM canvas. A-Frame material src (not a raw CanvasTexture) — Quest 3 AR
            // drops MeshBasicMaterial maps, which blanked both clips after the 1536 downscale.
            window.__xrZoom = 1;
            window.__xrZoomSteps = [0.5, 0.6, 0.7, 0.8, 0.9, 1];
            // Skybox-style: meters to push the dome along world -Z (session forward). 0 = centered.
            window.__xrDist = 0;
            var __xrDs = { canvas: null, ctx: null, stamp: "", codecSrc: "", av1: false, suspendBlit: false, exiting: false, sawAv1Tex: false };
            // Player script (second IIFE) must see these — bare refs otherwise throw and leave
            // "Checking WebXR…" / "Loading playlists…" stuck (PC + Quest).
            window.__xrDs = __xrDs;
            var __xrLogBuf = [];
            var __xrLogFlushTimer = 0;
            function xrDebugSnapshot() {
              var v = document.getElementById("chroma-stream");
              var mode = "";
              try {
                var el = document.getElementById("chroma-sphere");
                var c = el && el.components && el.components["chroma-stereo-sbs"];
                mode = (c && c._mode) || "";
              } catch (eM) {}
              return {
                t: Date.now(),
                presenting: !!xrIsPresenting(),
                exiting: !!__xrDs.exiting,
                suspendBlit: !!__xrDs.suspendBlit,
                av1: !!__xrDs.av1,
                av1Known: !!__xrDs.av1Known,
                sawAv1Tex: !!__xrDs.sawAv1Tex,
                mode: mode,
                resolved: !!__xrDs.resolved,
                codecSrc: (__xrDs.codecSrc || "").slice(-80),
                videoSrc: v ? ((v.currentSrc || v.src || "").slice(-80)) : "",
                paused: !!(v && v.paused),
                vw: v ? (v.videoWidth || 0) : 0,
                vh: v ? (v.videoHeight || 0) : 0,
                ct: v ? (Number(v.currentTime) || 0) : 0,
                note: (typeof window.__xrTexNote === "string") ? window.__xrTexNote : ""
              };
            }
            function xrLog(msg, extra) {
              var line = new Date().toISOString() + " " + String(msg || "");
              if (extra != null) {
                try { line += " " + JSON.stringify(extra); } catch (eJ) {}
              }
              __xrLogBuf.push(line);
              if (__xrLogBuf.length > 80) __xrLogBuf.splice(0, __xrLogBuf.length - 80);
              if (__xrLogFlushTimer) return;
              __xrLogFlushTimer = setTimeout(function () {
                __xrLogFlushTimer = 0;
                var batch = __xrLogBuf.splice(0, __xrLogBuf.length);
                if (!batch.length) return;
                var body = JSON.stringify({ lines: batch, snapshot: xrDebugSnapshot() });
                try {
                  fetch("xr_debug.json", {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: body,
                    keepalive: true
                  }).catch(function () {});
                } catch (ePost) {}
              }, 400);
            }
            function xrIsPresenting() {
              try {
                var scene = document.querySelector("a-scene");
                return !!(scene && scene.renderer && scene.renderer.xr && scene.renderer.xr.isPresenting);
              } catch (e) {
                return false;
              }
            }
            function xrClearAv1Flags() {
              __xrDs.av1 = false;
              __xrDs.av1Known = false;
              __xrDs.codecSrc = "";
              __xrDs.codecPending = "";
              __xrDs.codecRetrySrc = "";
              __xrDs.codecRetryAfter = 0;
              __xrDs.resolved = null;
              __xrDs.resolvedSrc = "";
              __xrDs.stamp = "";
            }
            function xrClearComponentModes() {
              try {
                ["chroma-screen", "chroma-sphere", "chroma-sphere-right"].forEach(function (id) {
                  var el = document.getElementById(id);
                  var comp = el && el.components && el.components["chroma-stereo-sbs"];
                  if (!comp) return;
                  comp._mode = "";
                  comp._gpuSig = "";
                  comp._uvZoom = null;
                  comp._uvEyeApplied = null;
                  comp._domeGeoReady = false;
                  comp._rebuiltFor = "";
                });
              } catch (eComp) {}
            }
            // Disposing a 6K AV1 RT / VideoTexture while WebXR is still presenting freezes Quest.
            function xrDisposeAv1Gpu() {
              try { if (__xrDs.rt) __xrDs.rt.dispose(); } catch (eRt) {}
              __xrDs.rt = null;
              __xrDs.rtW = 0;
              __xrDs.rtH = 0;
              // The texture is gone. Drop the handle so Enter VR does not sample it.
              __xrDs.resolved = null;
              __xrDs.resolvedSrc = "";
              // Do not dispose __xrVideoTex here — Quest then blacks A-Frame's video map too.
              if (__xrVideoTex) {
                try { __xrVideoTex.needsUpdate = false; } catch (eStop) {}
              }
            }
            // Quest only feeds one WebGL consumer per <video>. The AV1 blit texture
            // keeps taking frames after the next clip is HEVC, so A-Frame's map stays black.
            function xrReleaseLiveVideoTexture() {
              var tex = __xrVideoTex;
              __xrVideoTex = null;
              if (!tex) return;
              try { tex.needsUpdate = false; } catch (e0) {}
              try {
                if (!__xrDs.blankCanvas) {
                  __xrDs.blankCanvas = document.createElement("canvas");
                  __xrDs.blankCanvas.width = 2;
                  __xrDs.blankCanvas.height = 2;
                }
                tex.image = __xrDs.blankCanvas;
              } catch (e1) {}
              try { tex.dispose(); } catch (e2) {}
            }
            function xrScheduleDisposeAv1Gpu() {
              var token = (__xrDs.disposeToken || 0) + 1;
              __xrDs.disposeToken = token;
              setTimeout(function () {
                if (__xrDs.disposeToken !== token) return;
                if (xrIsPresenting()) {
                  xrScheduleDisposeAv1Gpu();
                  return;
                }
                xrDisposeAv1Gpu();
                __xrDs.suspendBlit = false;
              }, 700);
            }
            // Soft stop for AR/VR exit. Keep the last blit and the codec — clearing them
            // made the next Enter VR seed the dome from a canvas (AV1 tile atlas, or empty).
            function xrSuspendAv1Pipeline() {
              __xrDs.suspendBlit = true;
              xrClearComponentModes();
            }
            // Still in XR: re-probe the new clip but keep the last RT on screen (no black hole).
            function xrPrepareNewClip() {
              __xrDs.disposeToken = (__xrDs.disposeToken || 0) + 1;
              __xrDs.suspendBlit = false;
              __xrDs.av1 = false;
              __xrDs.av1Known = false;
              __xrDs.codecSrc = "";
              __xrDs.codecPending = "";
              __xrDs.codecRetrySrc = "";
              __xrDs.codecRetryAfter = 0;
              __xrDs.lastBlitTime = -1;
              __xrDs.needsMaterialKick = true;
              // Keep __xrDs.resolved + RT until the first blit of the new clip replaces them.
              xrClearComponentModes();
              try { xrForgetStaleCanvases(document.getElementById("chroma-stream")); } catch (eBag) {}
            }
            function xrResetPlaybackPipeline() {
              __xrDs.suspendBlit = true;
              __xrDs.exiting = false;
              xrClearAv1Flags();
              xrClearComponentModes();
              try { xrForgetStaleCanvases(document.getElementById("chroma-stream")); } catch (eBag) {}
              __xrDs.lastBlitTime = -1;
              // Keep sawAv1Tex for this page load — once Quest has blitted AV1, native
              // VideoTexture stays unreliable; canvas path must continue after Files.
              if (xrIsPresenting()) {
                xrScheduleDisposeAv1Gpu();
                return;
              }
              xrDisposeAv1Gpu();
              __xrDs.suspendBlit = false;
            }
            window.xrIsPresenting = xrIsPresenting;
            window.xrLog = xrLog;
            window.xrSuspendAv1Pipeline = xrSuspendAv1Pipeline;
            window.xrScheduleDisposeAv1Gpu = xrScheduleDisposeAv1Gpu;
            window.xrPrepareNewClip = xrPrepareNewClip;
            window.xrResetPlaybackPipeline = xrResetPlaybackPipeline;
            // Quest's 2D canvas draw of an AV1 <video> copies the decoder tile atlas
            // (one wide tile on top, two tiles splitting the bottom), not the picture.
            // A GPU pass that samples the whole video texture forces every tile to update.
            function xrWatchAv1(video) {
              var src = (video && (video.currentSrc || video.src)) || "";
              if (!src) return false;
              if (__xrDs.av1Known && __xrDs.codecSrc === src) return __xrDs.av1 === true;
              var nowMs = Date.now();
              if (__xrDs.codecPending === src) return __xrDs.av1 === true;
              if (__xrDs.codecRetrySrc === src && __xrDs.codecRetryAfter && nowMs < __xrDs.codecRetryAfter) {
                return __xrDs.av1 === true;
              }
              __xrDs.codecPending = src;
              __xrDs.codecSrc = src;
              __xrDs.av1Known = false;
              // Do not keep the previous clip's AV1 flag while the new probe runs.
              // Leave __xrDs.resolved up so the dome holds the last picture until this probe finishes.
              __xrDs.av1 = false;
              function hasAv01(buf) {
                // Box type only. A raw "av01" scan false-positives inside HEVC mdat and then
                // the dome stays on the AV1 blit path (blank after a real AV1 clip).
                var u8 = new Uint8Array(buf);
                for (var i = 0; i + 8 <= u8.length; i++) {
                  var size = (u8[i] << 24) | (u8[i + 1] << 16) | (u8[i + 2] << 8) | u8[i + 3];
                  if (size < 8 || size > 16777216) continue;
                  if (u8[i + 4] === 97 && u8[i + 5] === 118 && u8[i + 6] === 48 && u8[i + 7] === 49) return true;
                }
                return false;
              }
              function finish(isAv1) {
                if (__xrDs.codecSrc !== src && __xrDs.codecPending !== src) return;
                __xrDs.codecSrc = src;
                __xrDs.av1 = !!isAv1;
                __xrDs.av1Known = true;
                __xrDs.codecPending = "";
                // HEVC must not keep sampling the previous AV1 render target.
                // Do not dispose the VideoTexture here — on Quest that poisons the same
                // <video> for A-Frame preview/AR and both stay black until a full reload.
                if (!isAv1) {
                  __xrDs.resolved = null;
                  __xrDs.lastBlitTime = -1;
                  if (__xrVideoTex) {
                    try { __xrVideoTex.needsUpdate = false; } catch (eStop) {}
                  }
                }
                __xrDs.needsMaterialKick = true;
                try { xrLog("codec", { av1: !!isAv1, sawAv1Tex: !!__xrDs.sawAv1Tex, src: (src || "").slice(-60) }); } catch (eLog) {}
              }
              function fail() {
                if (__xrDs.codecSrc !== src && __xrDs.codecPending !== src) return;
                __xrDs.av1 = false;
                __xrDs.av1Known = false;
                __xrDs.codecPending = "";
                __xrDs.codecSrc = "";
                __xrDs.codecRetrySrc = src;
                __xrDs.codecRetryAfter = Date.now() + 1200;
              }
              fetch(src, { headers: { Range: "bytes=0-524287" } }).then(function (r) {
                if (!r.ok && r.status !== 206) throw new Error("range");
                var total = 0;
                var cr = r.headers.get("Content-Range") || "";
                var m = /\/(\d+)\s*$/.exec(cr);
                if (m) total = parseInt(m[1], 10) || 0;
                return r.arrayBuffer().then(function (buf) { return { buf: buf, total: total }; });
              }).then(function (pack) {
                if (__xrDs.codecSrc !== src && __xrDs.codecPending !== src) return;
                if (hasAv01(pack.buf)) { finish(true); return; }
                var tailReq = null;
                if (pack.total > 524288) {
                  var start = pack.total - 524288;
                  tailReq = fetch(src, { headers: { Range: "bytes=" + start + "-" + (pack.total - 1) } });
                } else if (!pack.total) {
                  tailReq = fetch(src, { headers: { Range: "bytes=-524288" } });
                }
                if (!tailReq) { finish(false); return; }
                return tailReq.then(function (r2) {
                  if (!r2.ok && r2.status !== 206) throw new Error("tail");
                  return r2.arrayBuffer();
                }).then(function (tail) { finish(hasAv01(tail)); });
              }).catch(function () { fail(); });
              return __xrDs.av1 === true;
            }
            function xrBlitFullVideo(renderer, video) {
              if (!renderer || !video || !video.videoWidth) return null;
              // Never blit while exiting AR/VR or after the session has ended.
              if (__xrDs.suspendBlit) return null;
              var xr = renderer.xr;
              if (!xr || !xr.isPresenting) return null;
              if (__xrDs.blitting) return __xrDs.resolved || null;
              var tex = xrEnsureVideoTexture(video);
              if (!tex) return null;
              // Quest lenses do not need a 4K+ blit every frame — that was crushing AR fps.
              var maxW = 6144;
              var scale = Math.min(maxW / video.videoWidth, maxW / video.videoHeight, 1);
              var w = Math.max(2, Math.floor(video.videoWidth * scale / 2) * 2);
              var h = Math.max(2, Math.floor(video.videoHeight * scale / 2) * 2);
              if (!__xrDs.rt || __xrDs.rtW !== w || __xrDs.rtH !== h) {
                try { if (__xrDs.rt) __xrDs.rt.dispose(); } catch (eRt) {}
                __xrDs.rt = new THREE.WebGLRenderTarget(w, h, {
                  minFilter: THREE.LinearFilter,
                  magFilter: THREE.LinearFilter,
                  depthBuffer: false,
                  stencilBuffer: false
                });
                __xrDs.rt.texture.generateMipmaps = false;
                if (THREE.LinearSRGBColorSpace && "colorSpace" in __xrDs.rt.texture) {
                  __xrDs.rt.texture.colorSpace = THREE.LinearSRGBColorSpace;
                }
                __xrDs.rtW = w;
                __xrDs.rtH = h;
              }
              if (!__xrDs.blitCam) {
                __xrDs.blitCam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 2);
                __xrDs.blitScene = new THREE.Scene();
                // Copy the video texels unchanged. Do not flip V — that inverted AV1 in AR.
                __xrDs.blitMat = new THREE.RawShaderMaterial({
                  uniforms: { tex: { value: tex } },
                  vertexShader: [
                    "attribute vec3 position;",
                    "attribute vec2 uv;",
                    "uniform mat4 projectionMatrix;",
                    "uniform mat4 modelViewMatrix;",
                    "varying vec2 vUv;",
                    "void main(){",
                    "  vUv = uv;",
                    "  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);",
                    "}"
                  ].join("\n"),
                  fragmentShader: [
                    "precision highp float;",
                    "uniform sampler2D tex;",
                    "varying vec2 vUv;",
                    "void main(){ gl_FragColor = texture2D(tex, vUv); }"
                  ].join("\n"),
                  depthTest: false,
                  depthWrite: false
                });
                __xrDs.blitScene.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), __xrDs.blitMat));
              }
              __xrDs.blitMat.uniforms.tex.value = tex;
              tex.needsUpdate = true;
              var wasEnabled = !!xr.enabled;
              var prev = renderer.getRenderTarget();
              var prevClear = renderer.autoClear;
              if (!__xrDs.viewport) __xrDs.viewport = new THREE.Vector4();
              if (!__xrDs.scissor) __xrDs.scissor = new THREE.Vector4();
              var prevScissorTest = false;
              try { renderer.getViewport(__xrDs.viewport); } catch (eVp) {}
              try { renderer.getScissor(__xrDs.scissor); } catch (eSc) {}
              try { prevScissorTest = !!renderer.getScissorTest(); } catch (eSt) {}
              function restoreBlit() {
                try { renderer.setRenderTarget(prev); } catch (eSet) {}
                try {
                  renderer.setViewport(__xrDs.viewport.x, __xrDs.viewport.y, __xrDs.viewport.z, __xrDs.viewport.w);
                } catch (eVp2) {}
                try {
                  renderer.setScissor(__xrDs.scissor.x, __xrDs.scissor.y, __xrDs.scissor.z, __xrDs.scissor.w);
                } catch (eSc2) {}
                try { renderer.setScissorTest(prevScissorTest); } catch (eSt2) {}
                renderer.autoClear = prevClear;
                // Only restore XR if the session is still live — enabling during teardown hangs Quest.
                try {
                  if (xr.isPresenting) xr.enabled = wasEnabled;
                } catch (eXr) {}
                __xrDs.blitting = false;
              }
              __xrDs.blitting = true;
              try {
                xr.enabled = false;
                renderer.autoClear = true;
                renderer.setRenderTarget(__xrDs.rt);
                renderer.render(__xrDs.blitScene, __xrDs.blitCam);
              } catch (eBlit) {
                restoreBlit();
                return null;
              }
              restoreBlit();
              __xrDs.sawAv1Tex = true;
              return __xrDs.rt ? __xrDs.rt.texture : null;
            }
            // Quest flat preview. drawImage of AV1 is the tile atlas, and xr-chroma on a
            // video texture stays black. Blit a small keyed frame and hand A-Frame a canvas.
            function xrKeyedPreviewCanvas(renderer, video, chroma) {
              if (!renderer || !video || !video.videoWidth || !chroma) return null;
              if (__xrDs.exiting || __xrDs.suspendBlit || __xrDs.blitting) return null;
              var tex = xrEnsureVideoTexture(video);
              if (!tex) return null;
              var limit = 1280;
              var scale = Math.min(limit / video.videoWidth, limit / video.videoHeight, 1);
              var w = Math.max(2, Math.floor(video.videoWidth * scale / 2) * 2);
              var h = Math.max(2, Math.floor(video.videoHeight * scale / 2) * 2);
              var srcNow = xrVideoSrc(video);
              var bag = xrSlotBag("flat");
              var stamp = (video.currentTime || 0).toFixed(3) + "|" + w + "x" + h + "|gpuc" + (chroma.keyColor || "") + "|" + srcNow;
              if (bag.stamp === stamp && bag.canvas && bag.canvas.width === w && bag.src === srcNow) return bag.canvas;
              var nowMs = Date.now();
              if (bag.canvas && bag.src === srcNow && __xrDs.previewReadAt && (nowMs - __xrDs.previewReadAt) < 120) {
                return bag.canvas;
              }
              var key = new THREE.Color(chroma.keyColor || "#00ff00");
              var sim = (chroma.similarity == null) ? 0.3 : chroma.similarity;
              var smo = (chroma.smoothness == null) ? 0.08 : chroma.smoothness;
              if (!__xrDs.previewRt || __xrDs.previewW !== w || __xrDs.previewH !== h) {
                try { if (__xrDs.previewRt) __xrDs.previewRt.dispose(); } catch (eRt) {}
                __xrDs.previewRt = new THREE.WebGLRenderTarget(w, h, {
                  minFilter: THREE.LinearFilter,
                  magFilter: THREE.LinearFilter,
                  type: THREE.UnsignedByteType,
                  format: THREE.RGBAFormat,
                  depthBuffer: false,
                  stencilBuffer: false
                });
                __xrDs.previewRt.texture.generateMipmaps = false;
                __xrDs.previewW = w;
                __xrDs.previewH = h;
                __xrDs.previewBuf = null;
              }
              if (!__xrDs.previewMat) {
                __xrDs.previewCam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 2);
                __xrDs.previewScene = new THREE.Scene();
                __xrDs.previewMat = new THREE.RawShaderMaterial({
                  uniforms: {
                    tex: { value: tex },
                    keyColor: { value: key },
                    similarity: { value: sim },
                    smoothness: { value: smo }
                  },
                  vertexShader: [
                    "attribute vec3 position;",
                    "attribute vec2 uv;",
                    "uniform mat4 projectionMatrix;",
                    "uniform mat4 modelViewMatrix;",
                    "varying vec2 vUv;",
                    "void main(){",
                    "  vUv = vec2(uv.x, 1.0 - uv.y);",
                    "  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);",
                    "}"
                  ].join("\n"),
                  fragmentShader: [
                    "precision highp float;",
                    "uniform sampler2D tex;",
                    "uniform vec3 keyColor;",
                    "uniform float similarity;",
                    "uniform float smoothness;",
                    "varying vec2 vUv;",
                    "void main(){",
                    "  vec4 videoColor = texture2D(tex, vUv);",
                    "  float cr = 0.5 * videoColor.r - 0.4187 * videoColor.g - 0.0813 * videoColor.b;",
                    "  float cb = -0.1687 * videoColor.r - 0.3313 * videoColor.g + 0.5 * videoColor.b;",
                    "  float keyCr = 0.5 * keyColor.r - 0.4187 * keyColor.g - 0.0813 * keyColor.b;",
                    "  float keyCb = -0.1687 * keyColor.r - 0.3313 * keyColor.g + 0.5 * keyColor.b;",
                    "  float dist = sqrt((cr - keyCr) * (cr - keyCr) + (cb - keyCb) * (cb - keyCb));",
                    "  float blend = smoothstep(similarity, similarity + smoothness, dist);",
                    "  gl_FragColor = vec4(videoColor.rgb * blend, blend);",
                    "}"
                  ].join("\n"),
                  depthTest: false,
                  depthWrite: false
                });
                __xrDs.previewScene.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), __xrDs.previewMat));
              } else {
                __xrDs.previewMat.uniforms.tex.value = tex;
                __xrDs.previewMat.uniforms.keyColor.value.copy(key);
                __xrDs.previewMat.uniforms.similarity.value = sim;
                __xrDs.previewMat.uniforms.smoothness.value = smo;
              }
              tex.needsUpdate = true;
              var prevTarget = renderer.getRenderTarget();
              var prevClear = renderer.autoClear;
              var xr = renderer.xr;
              var wasEnabled = !!(xr && xr.enabled);
              if (!__xrDs.viewport) __xrDs.viewport = new THREE.Vector4();
              if (!__xrDs.scissor) __xrDs.scissor = new THREE.Vector4();
              var prevScissorTest = false;
              try { renderer.getViewport(__xrDs.viewport); } catch (eVp) {}
              try { renderer.getScissor(__xrDs.scissor); } catch (eSc) {}
              try { prevScissorTest = !!renderer.getScissorTest(); } catch (eSt) {}
              function restorePreview() {
                try { renderer.setRenderTarget(prevTarget); } catch (eSet) {}
                try {
                  renderer.setViewport(__xrDs.viewport.x, __xrDs.viewport.y, __xrDs.viewport.z, __xrDs.viewport.w);
                } catch (eVp2) {}
                try {
                  renderer.setScissor(__xrDs.scissor.x, __xrDs.scissor.y, __xrDs.scissor.z, __xrDs.scissor.w);
                } catch (eSc2) {}
                try { renderer.setScissorTest(prevScissorTest); } catch (eSt2) {}
                renderer.autoClear = prevClear;
                try { if (xr && xr.isPresenting) xr.enabled = wasEnabled; } catch (eXr) {}
                __xrDs.blitting = false;
              }
              __xrDs.blitting = true;
              try {
                if (xr && xr.isPresenting) xr.enabled = false;
                renderer.autoClear = true;
                renderer.setRenderTarget(__xrDs.previewRt);
                renderer.render(__xrDs.previewScene, __xrDs.previewCam);
                if (!__xrDs.previewBuf || __xrDs.previewBuf.length !== w * h * 4) {
                  __xrDs.previewBuf = new Uint8Array(w * h * 4);
                }
                renderer.readRenderTargetPixels(__xrDs.previewRt, 0, 0, w, h, __xrDs.previewBuf);
              } catch (ePreview) {
                restorePreview();
                return null;
              }
              restorePreview();
              var canvas = bag.canvas || document.getElementById("xr-ds-canvas");
              if (!canvas) {
                canvas = document.createElement("canvas");
                canvas.id = "xr-ds-canvas";
                canvas.width = 16;
                canvas.height = 16;
                document.body.appendChild(canvas);
              }
              if (canvas.width !== w || canvas.height !== h) {
                canvas.width = w;
                canvas.height = h;
                bag.ctx = null;
              }
              if (!bag.ctx) bag.ctx = canvas.getContext("2d", { alpha: true });
              var img = bag.ctx.createImageData(w, h);
              img.data.set(__xrDs.previewBuf);
              bag.ctx.putImageData(img, 0, 0);
              bag.canvas = canvas;
              bag.src = srcNow;
              bag.stamp = stamp;
              bag.pendingUpload = true;
              __xrDs.previewReadAt = Date.now();
              __xrDs.sawAv1Tex = true;
              return canvas;
            }
            function xrApplyChromaKey(ctx, cw, ch, keyHex, similarity, smoothness) {
              var img = ctx.getImageData(0, 0, cw, ch);
              var d = img.data;
              var key = new THREE.Color(keyHex || "#00ff00");
              var keyCr = 0.5 * key.r - 0.4187 * key.g - 0.0813 * key.b;
              var keyCb = -0.1687 * key.r - 0.3313 * key.g + 0.5 * key.b;
              var sim = (similarity == null) ? 0.3 : similarity;
              var smo = (smoothness == null) ? 0.08 : smoothness;
              if (smo < 0.0001) smo = 0.0001;
              var edge = sim + smo;
              for (var i = 0; i < d.length; i += 4) {
                var r = d[i] / 255;
                var g = d[i + 1] / 255;
                var b = d[i + 2] / 255;
                var cr = 0.5 * r - 0.4187 * g - 0.0813 * b;
                var cb = -0.1687 * r - 0.3313 * g + 0.5 * b;
                var dist = Math.sqrt((cr - keyCr) * (cr - keyCr) + (cb - keyCb) * (cb - keyCb));
                var blend = dist <= sim ? 0 : (dist >= edge ? 1 : (dist - sim) / smo);
                d[i + 3] = (blend * 255) | 0;
              }
              ctx.putImageData(img, 0, 0);
            }
            function xrSlotBag(slot) {
              var key = slot === "ar" ? "ar" : "flat";
              if (!__xrDs.bags) __xrDs.bags = {};
              if (!__xrDs.bags[key]) {
                __xrDs.bags[key] = { canvas: null, ctx: null, stamp: "", src: "", readFreq: false, pendingUpload: false };
              }
              return __xrDs.bags[key];
            }
            function xrVideoSrc(video) {
              return (video && (video.currentSrc || video.src)) || "";
            }
            function xrClearBagPixels(bag) {
              if (!bag) return;
              bag.stamp = "";
              bag.src = "";
              bag.pendingUpload = false;
              try {
                if (bag.ctx && bag.canvas) bag.ctx.clearRect(0, 0, bag.canvas.width, bag.canvas.height);
              } catch (e) {}
            }
            // Clip changes must not leave the previous picture in the dome canvas.
            function xrForgetStaleCanvases(video) {
              var src = xrVideoSrc(video);
              if (!__xrDs.bags) return;
              ["flat", "ar"].forEach(function (key) {
                var bag = __xrDs.bags[key];
                if (!bag || !bag.src || bag.src === src) return;
                xrClearBagPixels(bag);
              });
            }
            // Enter VR often cannot draw the <video> yet. Copy the live preview canvas
            // so the dome does not keep the previous attempt's frame.
            function xrSeedArFromFlat(video) {
              var src = xrVideoSrc(video);
              var flat = xrSlotBag("flat");
              if (!flat.canvas || !flat.canvas.width || !flat.src || flat.src !== src) return null;
              var ar = xrSlotBag("ar");
              var canvas = ar.canvas || document.getElementById("xr-ds-ar");
              if (!canvas) {
                canvas = document.createElement("canvas");
                canvas.id = "xr-ds-ar";
                canvas.width = 16;
                canvas.height = 16;
                document.body.appendChild(canvas);
              }
              if (canvas.width !== flat.canvas.width || canvas.height !== flat.canvas.height) {
                canvas.width = flat.canvas.width;
                canvas.height = flat.canvas.height;
                ar.ctx = null;
              }
              if (!ar.ctx) ar.ctx = canvas.getContext("2d", { alpha: true, willReadFrequently: !!ar.readFreq });
              try { ar.ctx.drawImage(flat.canvas, 0, 0); } catch (e) { return null; }
              ar.canvas = canvas;
              ar.src = src;
              ar.stamp = "";
              ar.pendingUpload = true;
              return canvas;
            }
            function xrDrawDownscale(video, limit, chroma, slot) {
              if (!video || !video.videoWidth) return null;
              // CPU chroma reads every pixel. The headset keys on the GPU; this cap is the
              // flat preview and the blit-failure fallback. Preview stays smaller so the page does not hitch.
              if (chroma && slot !== "ar" && limit > 1280) limit = 1280;
              if (chroma && limit > 2048) limit = 2048;
              var bag = xrSlotBag(slot);
              var canvasId = slot === "ar" ? "xr-ds-ar" : "xr-ds-canvas";
              var canvas = bag.canvas || document.getElementById(canvasId);
              if (!canvas) {
                canvas = document.createElement("canvas");
                canvas.id = canvasId;
                canvas.width = 16;
                canvas.height = 16;
                document.body.appendChild(canvas);
              }
              var wantRead = !!chroma;
              if (!bag.ctx || (wantRead && !bag.readFreq)) {
                if (bag.ctx && wantRead && !bag.readFreq) {
                  var fresh = document.createElement("canvas");
                  fresh.id = canvasId;
                  if (canvas.parentNode) canvas.parentNode.replaceChild(fresh, canvas);
                  else document.body.appendChild(fresh);
                  canvas = fresh;
                  bag.ctx = null;
                }
                bag.ctx = canvas.getContext("2d", { alpha: true, willReadFrequently: wantRead });
                bag.readFreq = wantRead;
              }
              bag.canvas = canvas;
              var srcNow = xrVideoSrc(video);
              if (bag.src && bag.src !== srcNow) xrClearBagPixels(bag);
              bag.canvas = canvas;
              var scale = Math.min(limit / video.videoWidth, limit / video.videoHeight, 1);
              var cw = Math.max(2, Math.floor(video.videoWidth * scale / 2) * 2);
              var ch = Math.max(2, Math.floor(video.videoHeight * scale / 2) * 2);
              var stamp = (video.currentTime || 0).toFixed(3) + "|" + cw + "x" + ch + "|" + (chroma ? ("c" + (chroma.keyColor || "")) : "o") + "|" + srcNow;
              if (bag.stamp === stamp && canvas.width === cw && bag.src === srcNow) return canvas;
              if (canvas.width !== cw || canvas.height !== ch) {
                canvas.width = cw;
                canvas.height = ch;
              }
              try {
                bag.ctx.drawImage(video, 0, 0, cw, ch);
              } catch (e1) {
                return null;
              }
              if (chroma) {
                xrApplyChromaKey(bag.ctx, cw, ch, chroma.keyColor, chroma.similarity, chroma.smoothness);
              }
              bag.stamp = stamp;
              bag.src = srcNow;
              bag.pendingUpload = true;
              return canvas;
            }

            function xrMakeChromaMaterial(videoTex, data, uvOffsetX) {
              return new THREE.ShaderMaterial({
                uniforms: {
                  textureMap: { value: videoTex },
                  uvOffset: { value: new THREE.Vector2(uvOffsetX || 0, 0) },
                  keyColor: { value: new THREE.Color(data.keyColor) },
                  similarity: { value: data.similarity },
                  smoothness: { value: data.smoothness },
                  chromaEnabled: { value: data.chroma ? 1.0 : 0.0 },
                  sbsEnabled: { value: data.sbs ? 1.0 : 0.0 }
                },
                vertexShader: [
                  "varying vec2 vUv;",
                  "void main() {",
                  "  vUv = uv;",
                  "  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);",
                  "}"
                ].join("\n"),
                fragmentShader: [
                  "uniform sampler2D textureMap;",
                  "uniform vec2 uvOffset;",
                  "uniform vec3 keyColor;",
                  "uniform float similarity;",
                  "uniform float smoothness;",
                  "uniform float chromaEnabled;",
                  "uniform float sbsEnabled;",
                  "varying vec2 vUv;",
                  "void main() {",
                  "  vec2 eyeUv = (sbsEnabled > 0.5) ? (vUv * vec2(0.5, 1.0) + uvOffset) : vUv;",
                  "  vec4 videoColor = texture2D(textureMap, eyeUv);",
                  "  float blend = 1.0;",
                  "  if (chromaEnabled > 0.5) {",
                  "    float chromaSCr = 0.5000 * videoColor.r - 0.4187 * videoColor.g - 0.0813 * videoColor.b;",
                  "    float chromasCb = -0.1687 * videoColor.r - 0.3313 * videoColor.g + 0.5000 * videoColor.b;",
                  "    float keyCr = 0.5000 * keyColor.r - 0.4187 * keyColor.g - 0.0813 * keyColor.b;",
                  "    float keyCb = -0.1687 * keyColor.r - 0.3313 * keyColor.g + 0.5000 * keyColor.b;",
                  "    float distance = sqrt(pow(chromaSCr - keyCr, 2.0) + pow(chromasCb - keyCb, 2.0));",
                  "    blend = smoothstep(similarity, similarity + smoothness, distance);",
                  "  }",
                  "  gl_FragColor = vec4(videoColor.rgb, videoColor.a * blend);",
                  "}"
                ].join("\n"),
                transparent: !!data.chroma,
                depthWrite: !data.chroma,
                side: THREE.DoubleSide,
                toneMapped: false
              });
            }

            /**
             * GPU chroma key. A-Frame owns the video texture (a hand-made VideoTexture shader stays black on Quest).
             * No canvas readback — that read was stalling AR playback and Enter VR.
             */
            AFRAME.registerShader("xr-chroma", {
              schema: {
                src: { type: "map", is: "uniform" },
                keyColor: { type: "color", is: "uniform", default: "#00ff00" },
                similarity: { type: "number", is: "uniform", default: 0.3 },
                smoothness: { type: "number", is: "uniform", default: 0.08 }
              },
              vertexShader: [
                "varying vec2 vUv;",
                "void main() {",
                "  vUv = uv;",
                "  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);",
                "}"
              ].join("\n"),
              fragmentShader: [
                "uniform sampler2D src;",
                "uniform vec3 keyColor;",
                "uniform float similarity;",
                "uniform float smoothness;",
                "varying vec2 vUv;",
                "void main() {",
                "  vec4 videoColor = texture2D(src, vUv);",
                "  float cr = 0.5 * videoColor.r - 0.4187 * videoColor.g - 0.0813 * videoColor.b;",
                "  float cb = -0.1687 * videoColor.r - 0.3313 * videoColor.g + 0.5 * videoColor.b;",
                "  float keyCr = 0.5 * keyColor.r - 0.4187 * keyColor.g - 0.0813 * keyColor.b;",
                "  float keyCb = -0.1687 * keyColor.r - 0.3313 * keyColor.g + 0.5 * keyColor.b;",
                "  float dist = sqrt((cr - keyCr) * (cr - keyCr) + (cb - keyCb) * (cb - keyCb));",
                "  float blend = smoothstep(similarity, similarity + smoothness, dist);",
                "  gl_FragColor = vec4(videoColor.rgb, blend);",
                "}"
              ].join("\n")
            });
            (function () {
              var shader = AFRAME.shaders && AFRAME.shaders["xr-chroma"];
              if (!shader || !shader.prototype || !shader.prototype.init) return;
              var baseInit = shader.prototype.init;
              shader.prototype.init = function (data) {
                baseInit.call(this, data);
                if (!this.material) return;
                this.material.transparent = true;
                this.material.depthWrite = false;
                this.material.toneMapped = false;
                this.material.side = THREE.DoubleSide;
                this.material.alphaTest = 0.08;
              };
            })();

            /**
             * eye: "left" | "right" | "both"
             * SBS VR (Quest and PC): left dome on layer 1, right dome on layer 2. three.js WebXR
             * renders layer 1 only in the left eye and layer 2 only in the right eye, so no
             * per-draw eye detection is needed. AR and mono stay on layer 0 (left dome only).
             */
            AFRAME.registerComponent("chroma-stereo-sbs", {
              schema: {
                keyColor: { type: "color", default: "#00ff00" },
                similarity: { type: "number", default: 0.3 },
                smoothness: { type: "number", default: 0.08 },
                chroma: { type: "boolean", default: false },
                sbs: { type: "boolean", default: true },
                eye: { type: "string", default: "both" },
                // desktop = flat a-video for PC/magic-window; dome = immersive 180° hemisphere
                role: { type: "string", default: "dome" }
              },
              init: function () {
                this.video = document.querySelector("#chroma-stream");
                this.shaderMaterial = null;
                this._canvasMat = null;
                this._dsCanvas = null;
                this._dsCtx = null;
                this._dsTex = null;
                this._retries = 0;
                this._onApply = this.applyMaterial.bind(this);
                this._onEnterVr = function () {
                  var self = this;
                  self._yawLocked = false;
                  self._poseFrames = 0;
                  __xrDs.disposeToken = (__xrDs.disposeToken || 0) + 1;
                  __xrDs.exiting = false;
                  __xrDs.suspendBlit = false;
                  // Drop the blit only when it belongs to another clip. Clearing it on every
                  // Enter VR left the dome with no frame until the next blit landed.
                  var srcNow = xrVideoSrc(self.video);
                  if (__xrDs.resolvedSrc && __xrDs.resolvedSrc !== srcNow) {
                    __xrDs.resolved = null;
                    __xrDs.resolvedSrc = "";
                    __xrDs.lastBlitTime = -1;
                  }
                  var keepRt = !!(__xrDs.resolved && __xrDs.resolvedSrc === srcNow);
                  var seeded = null;
                  try { xrForgetStaleCanvases(self.video); } catch (eBag) {}
                  // A canvas copy of AV1 is the decoder tile atlas. Keep the blit instead.
                  if (!keepRt) {
                    try { seeded = xrSeedArFromFlat(self.video); } catch (eSeed) {}
                  }
                  if (seeded && !self.isDesktopRole()) {
                    self._dsCanvas = seeded;
                    self._dsSrc = srcNow;
                  }
                  if (__xrDs.resumeAfterExit && self.video) {
                    __xrDs.resumeAfterExit = false;
                    try {
                      var rp = self.video.play();
                      if (rp && rp.catch) rp.catch(function () {});
                    } catch (ePlay) {}
                  }
                  if (__xrVideoTex && (keepRt || (__xrDs.av1Known && __xrDs.av1 === true) || !!self.data.chroma)) {
                    try { __xrVideoTex.needsUpdate = true; } catch (eTex) {}
                  }
                  self._mode = "";
                  self._gpuSig = "";
                  self._uvZoom = null;
                  self._uvEyeApplied = null;
                  try { xrLog("enter-vr", { eye: self.data.eye, role: self.data.role, ar: self.isArMode(), seeded: !!seeded, rt: keepRt }); } catch (eL) {}
                  function kick() {
                    try { self.applySbsUVs(); } catch (eUv) {}
                    self.applyMaterial();
                    self.syncEyeLayers();
                  }
                  // Quest AR session startup often resets layers/materials — re-bind a few times.
                  kick();
                  setTimeout(kick, 50);
                  setTimeout(kick, 250);
                  setTimeout(kick, 800);
                }.bind(this);
                this._onExitVr = function () {
                  // Stop AV1/canvas GPU work first. Never applyMaterial / dispose RT while
                  // WebXR is still tearing down — that kills Quest Browser after AV1→HEVC.
                  __xrDs.exiting = true;
                  __xrDs.suspendBlit = true;
                  try { xrLog("exit-vr begin", { eye: this.data.eye, sawAv1: !!__xrDs.sawAv1Tex }); } catch (eL0) {}
                  xrSuspendAv1Pipeline();
                  __xrDs.exiting = true;
                  __xrDs.suspendBlit = true;
                  this._seated = false;
                  this._yawLocked = false;
                  this._poseFrames = 0;
                  this._mode = "";
                  this._gpuSig = "";
                  // Pause only through teardown. The blit stays alive for the next Enter VR.
                  if (__xrDs.sawAv1Tex && this.video && !this.video.paused) {
                    __xrDs.resumeAfterExit = true;
                    try { this.video.pause(); } catch (eP) {}
                  }
                  try { this.syncEyeLayers(); } catch (eLay) {}
                  var self = this;
                  setTimeout(function () {
                    if (xrIsPresenting()) return;
                    __xrDs.exiting = false;
                    __xrDs.suspendBlit = false;
                    try { xrLog("exit-vr settled"); } catch (eL1) {}
                    if (__xrDs.resumeAfterExit && self.video) {
                      __xrDs.resumeAfterExit = false;
                      try {
                        var rp = self.video.play();
                        if (rp && rp.catch) rp.catch(function () {});
                      } catch (eR) {}
                    }
                    try { self.applyMaterial(); } catch (eMat) {}
                  }, 900);
                }.bind(this);
                this.el.addEventListener("object3dset", this._onApply);
                this.el.addEventListener("materialtextureloaded", this._onApply);
                if (this.el.sceneEl) {
                  this.el.sceneEl.addEventListener("loaded", this._onApply);
                  this.el.sceneEl.addEventListener("enter-vr", this._onEnterVr);
                  this.el.sceneEl.addEventListener("exit-vr", this._onExitVr);
                }
                if (this.video) {
                  this.video.addEventListener("loadeddata", this._onApply);
                  this.video.addEventListener("loadedmetadata", this._onApply);
                  this.video.addEventListener("play", this._onApply);
                }
                this.ensureDomeGeometry();
                this.applyMaterial();
              },
              update: function () {
                this.ensureDomeGeometry();
                this.applyMaterial();
                this.syncEyeLayers();
              },
              remove: function () {
                this.el.removeEventListener("object3dset", this._onApply);
                this.el.removeEventListener("materialtextureloaded", this._onApply);
                if (this.el.sceneEl) {
                  this.el.sceneEl.removeEventListener("enter-vr", this._onEnterVr);
                  this.el.sceneEl.removeEventListener("exit-vr", this._onExitVr);
                }
                try { if (this._dsTex) this._dsTex.dispose(); } catch (e) {}
              },
              tick: function () {
                var quest = this.isQuestBrowser();
                // Uploading the video texture on the flat page steals Quest's only WebGL consumer,
                // so the preview element stays blank while the shader draws nothing.
                if (__xrVideoTex && this.isImmersiveStereo() && !__xrDs.suspendBlit && !__xrDs.exiting
                    && ((__xrDs.av1Known && __xrDs.av1 === true) || (quest && !!this.data.chroma))) {
                  __xrVideoTex.needsUpdate = true;
                }
                var flatOverlay = false;
                if (this.isDesktopRole()) {
                  if (this.isImmersiveStereo()) {
                    if (this.video) this.video.classList.remove("xr-flat-preview");
                    var offCanvas = document.getElementById("xr-ds-canvas");
                    if (offCanvas) {
                      offCanvas.classList.remove("xr-keyed-preview");
                      offCanvas.style.cssText = "";
                    }
                  } else {
                    var showKeyed = quest && !!this.data.chroma;
                    var showVideo = quest && !showKeyed && __xrDs.av1Known && __xrDs.av1 === true;
                    flatOverlay = !!(showKeyed || showVideo);
                    if (!showKeyed) {
                      var offKeyed = document.getElementById("xr-ds-canvas");
                      if (offKeyed) {
                        offKeyed.classList.remove("xr-keyed-preview");
                        offKeyed.style.cssText = "";
                      }
                    }
                    if (this.video && !showKeyed) this.video.classList.toggle("xr-flat-preview", !!showVideo);
                    if (showVideo) this._mode = "flat-video";
                    if (this.el.object3D) this.el.object3D.visible = !flatOverlay;
                  }
                }
                // Probe AV1 even with Chroma on — keyed AV1 still needs the full-frame blit.
                if (quest && this.video) xrWatchAv1(this.video);
                this.followHead();
                if (__xrDs.needsMaterialKick) {
                  // The flat player ticks first. Leave the flag for a dome or the kick never reaches AR.
                  if (!this.isDesktopRole()) __xrDs.needsMaterialKick = false;
                  try { this.applyMaterial(); } catch (eKick) {}
                }
                var av1Immersive = quest && this.isImmersiveStereo()
                  && !__xrDs.suspendBlit
                  && __xrDs.av1Known && __xrDs.av1 === true;
                // HEVC chroma uses the same blit. The canvas readback stuttered, and the
                // video-texture chroma shader stays black on Quest (preview and AR).
                var questGpu = av1Immersive || (
                  quest && this.isImmersiveStereo() && !__xrDs.suspendBlit && !__xrDs.exiting && !!this.data.chroma
                );
                var flatChroma = quest && this.isDesktopRole() && !this.isImmersiveStereo() && this.data.chroma
                  && this.drawsSharedFrame() && !__xrDs.exiting && !__xrDs.suspendBlit;
                if (flatChroma) {
                  var prevRenderer = this.el.sceneEl && this.el.sceneEl.renderer;
                  var previewFrame = xrKeyedPreviewCanvas(prevRenderer, this.video, this.chromaArgs());
                  if (!previewFrame && !(__xrDs.av1Known && __xrDs.av1 === true)) {
                    previewFrame = xrDrawDownscale(this.video, this.downscaleTarget(), this.chromaArgs(), "flat");
                  }
                  var keyedEl = document.getElementById("xr-ds-canvas");
                  if (previewFrame && keyedEl && keyedEl.width > 16) {
                    keyedEl.classList.add("xr-keyed-preview");
                    keyedEl.style.position = "fixed";
                    keyedEl.style.left = "0";
                    keyedEl.style.top = "0";
                    keyedEl.style.width = "100vw";
                    keyedEl.style.height = "calc(100vh - 6.5rem)";
                    keyedEl.style.maxHeight = "none";
                    keyedEl.style.opacity = "1";
                    keyedEl.style.zIndex = "2";
                    keyedEl.style.objectFit = "contain";
                    keyedEl.style.background = "#111";
                    if (this.video) this.video.classList.remove("xr-flat-preview");
                    this._mode = "canvas";
                  } else {
                    if (keyedEl) {
                      keyedEl.classList.remove("xr-keyed-preview");
                      keyedEl.style.cssText = "";
                    }
                    if (this.video) this.video.classList.add("xr-flat-preview");
                    try { if (__xrVideoTex) __xrVideoTex.needsUpdate = false; } catch (eHold) {}
                    this._mode = "flat-video";
                  }
                } else if (questGpu && this.drawsSharedFrame()) {
                  var renderer = this.el.sceneEl && this.el.sceneEl.renderer;
                  var v = this.video;
                  var t = v ? v.currentTime : -1;
                  var blitSrc = xrVideoSrc(v);
                  // Blit only when the decoder advances — tick is faster than the video.
                  if (__xrDs.resolved && __xrDs.resolvedSrc === blitSrc && __xrDs.lastBlitTime === t) {
                    this.applyAv1Resolve(__xrDs.resolved);
                  } else {
                    var resolved = xrBlitFullVideo(renderer, v);
                    if (resolved) {
                      __xrDs.resolved = resolved;
                      __xrDs.resolvedSrc = blitSrc;
                      __xrDs.lastBlitTime = t;
                      this.applyAv1Resolve(resolved);
                    } else if (__xrDs.resolved && __xrDs.resolvedSrc === blitSrc) {
                      this.applyAv1Resolve(__xrDs.resolved);
                    } else if (this.data.chroma) {
                      var fallback = xrDrawDownscale(v, this.downscaleTarget(), this.chromaArgs(), "ar");
                      if (fallback) this.applyPostAv1Canvas(fallback);
                      else this.holdPreviewCanvas();
                    }
                  }
                } else if (questGpu && this.data.eye === "right" && __xrDs.resolved) {
                  this.applyAv1Resolve(__xrDs.resolved);
                } else if (!flatOverlay && this.needsPostAv1Canvas() && this.drawsSharedFrame()) {
                  var postSlot = this.isDesktopRole() ? "flat" : "ar";
                  var postCanvas = xrDrawDownscale(this.video, this.downscaleTarget(), this.chromaArgs(), postSlot);
                  if (postCanvas) this.applyPostAv1Canvas(postCanvas);
                  else if (this._dsCanvas && this._dsSrc === xrVideoSrc(this.video)) this.applyPostAv1Canvas(this._dsCanvas);
                } else if (!flatOverlay && this._mode === "canvas" && this.drawsSharedFrame()) {
                  this.refreshDownscaleCanvas(true);
                }
                try {
                  var mesh = this.el.getObject3D("mesh");
                  var frameBag = xrSlotBag(this.isDesktopRole() ? "flat" : "ar");
                  var mat = mesh && mesh.material;
                  var tex = (mat && mat.uniforms && mat.uniforms.src && mat.uniforms.src.value) || (mat && mat.map);
                  var upload = this._mode === "canvas" ? true : (this._mode !== "av1rt" && this._mode !== "gpu");
                  if (this._mode === "gpu" && tex) upload = true;
                  if (this.video && this.video.classList.contains("xr-flat-preview")) upload = false;
                  if (upload && tex) {
                    tex.needsUpdate = true;
                    if (this._mode === "canvas") frameBag.pendingUpload = false;
                  }
                  if (this.isDesktopRole() && this.el.object3D && !this.isImmersiveStereo()) {
                    var keyedOn = false;
                    try {
                      var keyedNode = document.getElementById("xr-ds-canvas");
                      keyedOn = !!(keyedNode && keyedNode.classList.contains("xr-keyed-preview"));
                    } catch (eKeyVis) {}
                    var videoOn = !!(this.video && this.video.classList.contains("xr-flat-preview"));
                    this.el.object3D.visible = !(keyedOn || videoOn);
                  }
                } catch (eTick) {}
                // Eye layers change only with the session, a material bind, or the dome mesh.
                // Those paths call syncEyeLayers; it is not polled here.
              },
              followHead: function () {
                if (this.isDesktopRole() || !this.isImmersiveStereo()) return;
                var sceneEl = this.el.sceneEl;
                var cam = sceneEl && sceneEl.camera;
                var obj = this.el.object3D;
                if (!cam || !obj) return;
                try {
                  if (!this._seatPos) this._seatPos = new THREE.Vector3();
                  cam.getWorldPosition(this._seatPos);
                  obj.position.copy(this._seatPos);
                  // AR's reference yaw is not VR's. Lock once to the headset heading so the
                  // 180 opening is in front of the user instead of the previous session's -Z.
                  if (!this.isArMode() && !this._yawLocked) {
                    var xrRef = sceneEl.renderer && sceneEl.renderer.xr;
                    var head = xrRef && xrRef.getCamera && xrRef.getCamera();
                    var stereo = !!(xrRef && xrRef.isPresenting && head && head.cameras && head.cameras.length >= 2);
                    if (stereo) {
                      this._poseFrames = (this._poseFrames || 0) + 1;
                      if (this._poseFrames >= 8) {
                        if (!this._yawEuler) this._yawEuler = new THREE.Euler(0, 0, 0, "YXZ");
                        this._yawEuler.setFromQuaternion(head.quaternion, "YXZ");
                        this._lockedYaw = this._yawEuler.y;
                        this._yawLocked = true;
                        try {
                          xrLog("dome-yaw", {
                            yaw: Math.round(this._lockedYaw * 180 / Math.PI),
                            frames: this._poseFrames
                          });
                        } catch (eYaw) {}
                      }
                    }
                  }
                  var yaw = (!this.isArMode() && this._yawLocked) ? (this._lockedYaw || 0) : 0;
                  obj.rotation.set(0, yaw, 0);
                  var dist = this.domeDistance();
                  if (dist > 0) obj.translateZ(-dist);
                } catch (eFollow) {}
              },
              isDesktopRole: function () {
                return this.data.role === "desktop" || this.data.eye === "both";
              },
              drawsSharedFrame: function () {
                if (this.data.eye === "right") return false;
                if (this.isImmersiveStereo() && this.isDesktopRole()) return false;
                if (!this.isImmersiveStereo() && !this.isDesktopRole()) return false;
                return true;
              },
              chromaArgs: function () {
                if (!this.data.chroma) return null;
                var key = "#00ff00";
                try { key = "#" + new THREE.Color(this.data.keyColor).getHexString(); } catch (eKey) {}
                return { keyColor: key, similarity: this.data.similarity, smoothness: this.data.smoothness };
              },
              // Show the current preview canvas until an AV1 blit exists. Returning with no
              // material is what left Enter VR black.
              holdPreviewCanvas: function () {
                var now = xrVideoSrc(this.video);
                if (__xrDs.resolved && __xrDs.resolvedSrc === now) {
                  this.applyAv1Resolve(__xrDs.resolved);
                  return true;
                }
                // drawImage of an AV1 <video> is the tile atlas, not the picture.
                if (__xrDs.av1Known && __xrDs.av1 === true) return false;
                var hold = (this._dsSrc === now) ? this._dsCanvas : null;
                if (!hold) {
                  var flat = xrSlotBag("flat");
                  if (flat.src === now && flat.canvas) hold = flat.canvas;
                }
                if (!hold) return false;
                this._dsCanvas = hold;
                this._dsSrc = now;
                this.applyCanvasVideo();
                return true;
              },
              isQuestBrowser: function () {
                try {
                  return /OculusBrowser|Quest|Pacific/i.test(navigator.userAgent || "");
                } catch (e) {
                  return false;
                }
              },
              wantsShader: function () {
                // Custom VideoTexture shader goes black on Quest, including chroma. Key on the canvas instead.
                return false;
              },
              domeZoom: function () {
                var z = Number(window.__xrZoom);
                if (!(z > 0)) z = 1;
                return Math.max(0.4, Math.min(1, z));
              },
              domeDistance: function () {
                var d = Number(window.__xrDist);
                if (!(d > 0)) return 0;
                return Math.max(0, Math.min(12, d));
              },
              // Arc Zoom packs the whole frame onto a shorter FOV. Dist (Skybox-style)
              // leaves the 180° shell alone and only moves it farther from the head.
              domeAngles: function () {
                var zoom = this.isDesktopRole() ? 1 : this.domeZoom();
                var span = Math.PI * zoom;
                return {
                  phiLen: span,
                  thetaLen: span,
                  phiStart: (Math.PI * 1.5) - span / 2,
                  thetaStart: (Math.PI - span) / 2
                };
              },
              // A-Frame videosphere ignored phi-length → VR180 stretched to 360. Own the BufferGeometry.
              ensureDomeGeometry: function () {
                if (this.isDesktopRole()) return;
                var mesh = this.el.getObject3D("mesh");
                if (!mesh) return;
                var zoom = this.domeZoom();
                var ready = mesh.geometry && mesh.geometry.userData && mesh.geometry.userData._xrHemi;
                if (ready && this._domeGeoReady && this._domeZoom === zoom) return;
                try {
                  var old = mesh.geometry;
                  // Zoom 1 is a 180° hemisphere. Lower values pack the full frame into a smaller arc.
                  var ang = this.domeAngles();
                  var phiLen = ang.phiLen;
                  var thetaLen = ang.thetaLen;
                  var phiStart = ang.phiStart;
                  var thetaStart = ang.thetaStart;
                  var geo = new THREE.SphereGeometry(20, 80, 60, phiStart, phiLen, thetaStart, thetaLen);
                  geo.userData._xrHemi = true;
                  mesh.geometry = geo;
                  if (old && old !== geo) {
                    try { old.dispose(); } catch (e0) {}
                  }
                  // Keep A-Frame's geometry component in sync so it does not regenerate a 360° sphere.
                  try {
                    if (this.el.components.geometry) {
                      this.el.components.geometry.geometry = geo;
                      var gd = this.el.components.geometry.data;
                      gd.phiStart = phiStart * 180 / Math.PI;
                      gd.phiLength = phiLen * 180 / Math.PI;
                      gd.thetaStart = thetaStart * 180 / Math.PI;
                      gd.thetaLength = thetaLen * 180 / Math.PI;
                      gd.radius = 20;
                    }
                  } catch (eSync) {}
                  // Negative X = inward-facing + correct equirect UV orientation for VR180.
                  this.el.object3D.scale.set(-1, 1, 1);
                  try { this.el.setAttribute("scale", "-1 1 1"); } catch (eAttr) {}
                  this._domeGeoReady = true;
                  this._domeZoom = zoom;
                  this._seated = false;
                  mesh.traverse(function (node) {
                    if (node.geometry && node.geometry.userData) {
                      delete node.geometry.userData._xrBaseUv;
                    }
                  });
                  this.applySbsUVs();
                } catch (e) {}
              },
              maxWebGLTextureSize: function () {
                var maxTex = 4096;
                try {
                  var r = this.el.sceneEl && this.el.sceneEl.renderer;
                  if (r && r.capabilities && r.capabilities.maxTextureSize) {
                    maxTex = r.capabilities.maxTextureSize;
                  }
                } catch (e) {}
                // Headroom — drivers often fail video uploads at the exact max.
                var limit = Math.max(512, maxTex - 64);
                // Quest 3 max texture is 8192+. 6K SBS already plays natively; only 8K needs a shrink.
                // Cap the native path at 6144 so 6K stays a video texture (AR can show it).
                if (this.isQuestBrowser()) limit = Math.min(limit, 6144);
                return limit;
              },
              downscaleTarget: function () {
                var maxTex = 4096;
                try {
                  var r = this.el.sceneEl && this.el.sceneEl.renderer;
                  if (r && r.capabilities && r.capabilities.maxTextureSize) {
                    maxTex = r.capabilities.maxTextureSize;
                  }
                } catch (e) {}
                // Quest 3 can upload a 4096 canvas in AR. 1536 was crushing both clips and still blanked AR.
                var cap = this.isQuestBrowser() ? 4096 : Math.max(512, maxTex - 64);
                return Math.min(cap, Math.max(512, maxTex - 64));
              },
              setTexNote: function (msg) {
                try { window.__xrTexNote = msg || ""; } catch (e) {}
                var el = document.getElementById("xr-tex-note");
                if (!el) return;
                if (msg) {
                  el.hidden = false;
                  el.textContent = msg;
                } else {
                  el.hidden = true;
                  el.textContent = "";
                }
              },
              // Quest/PC: huge SBS exceeds reliable WebGL video tex size → shared canvas texture.
              refreshDownscaleCanvas: function (onlyUpdate) {
                var video = this.video;
                if (!video) return null;
                if (!video.videoWidth) {
                  if (!onlyUpdate && video.readyState >= 1) {
                    this.setTexNote("No decoded frames yet — codec may be unsupported here");
                  }
                  return null;
                }
                var slot = this.isDesktopRole() ? "flat" : "ar";
                var limit = this.maxWebGLTextureSize();
                var needsScale = video.videoWidth > limit || video.videoHeight > limit;
                // Chroma is a GPU key. This canvas is only a size shrink, never a pixel readback.
                if (!needsScale) {
                  if (!onlyUpdate) this.setTexNote("");
                  try { if (video) video.classList.remove("xr-pip"); } catch (e0) {}
                  return null;
                }
                var srcNow = xrVideoSrc(video);
                if (!this.drawsSharedFrame()) {
                  var existingBag = xrSlotBag(slot);
                  var existing = (existingBag.src === srcNow) ? existingBag.canvas : null;
                  if (!existing && slot === "ar") {
                    var flatBag = xrSlotBag("flat");
                    if (flatBag.src === srcNow) existing = flatBag.canvas;
                  }
                  this._dsCanvas = existing || null;
                  this._dsSrc = existing ? srcNow : "";
                  return this._dsCanvas;
                }
                var target = this.downscaleTarget();
                var canvas = xrDrawDownscale(video, target, this.chromaArgs(), slot);
                if (!canvas && slot === "ar") {
                  var flatOk = xrSlotBag("flat");
                  if (flatOk.src === srcNow && flatOk.canvas) {
                    canvas = flatOk.canvas;
                    // Dome samples the live preview canvas when the immersive copy fails.
                    xrSlotBag("ar").pendingUpload = true;
                  }
                }
                if (canvas) {
                  this._dsCanvas = canvas;
                  this._dsSrc = srcNow;
                } else if (this._dsSrc !== srcNow) {
                  this._dsCanvas = null;
                  this._dsSrc = "";
                }
                if (!canvas) {
                  try { video.classList.add("xr-pip"); } catch (e2) {}
                  if (!onlyUpdate) this.setTexNote("8K WebGL downscale failed — HTML preview");
                  return null;
                }
                if (!onlyUpdate) {
                  try { video.classList.remove("xr-pip"); } catch (e5) {}
                  this.setTexNote(
                    "Downscaling "
                    + video.videoWidth + "×" + video.videoHeight
                    + " → " + canvas.width + "×" + canvas.height
                  );
                }
                return canvas;
              },
              applyCanvasVideo: function () {
                this.ensureDomeGeometry();
                this.applySbsUVs();
                var canvas = this._dsCanvas;
                var src = (canvas && canvas.id) ? ("#" + canvas.id) : (this.isDesktopRole() ? "#xr-ds-canvas" : "#xr-ds-ar");
                var sizeKey = canvas ? (canvas.width + "x" + canvas.height) : "";
                var chromaOn = !!this.data.chroma;
                if (this._mode === "canvas" && this._canvasSrc === src && this._canvasSize === sizeKey) return true;
                this._mode = "canvas";
                this._canvasSrc = src;
                this._canvasSize = sizeKey;
                // A-Frame canvas material. Chroma alpha is punched in the canvas (the VideoTexture shader stays black on Quest).
                try {
                  this.el.setAttribute("material", {
                    shader: "flat",
                    src: src,
                    color: "#ffffff",
                    side: "double",
                    transparent: chromaOn,
                    opacity: 1,
                    depthWrite: !chromaOn,
                    alphaTest: chromaOn ? 0.08 : 0,
                    npot: true
                  });
                } catch (e) {}
                try {
                  var mesh = this.el.getObject3D("mesh");
                  if (mesh && mesh.material && mesh.material.map) mesh.material.map.needsUpdate = true;
                } catch (e2) {}
                this.restoreAFrameMaterial();
                if (this.isDesktopRole() && this.el.object3D && !this.isImmersiveStereo()) {
                  this.el.object3D.visible = true;
                }
                this.syncEyeLayers();
                return true;
              },
              needsPostAv1Canvas: function () {
                // After an AV1 blit, Quest VideoTexture stays black for the rest of the page.
                // Use a 2D canvas copy (A-Frame flat/chroma material) for flat + immersive.
                if (!this.isQuestBrowser() || !__xrDs.sawAv1Tex) return false;
                if (__xrDs.exiting || __xrDs.suspendBlit) return false;
                if (__xrDs.av1Known && __xrDs.av1 === true) return false;
                // Immersive chroma is the blit shader. A per-frame canvas readback is what stuttered HEVC.
                if (this.data.chroma && this.isImmersiveStereo()) return false;
                if (this.isDesktopRole()) return !this.isImmersiveStereo();
                return this.isImmersiveStereo();
              },
              applyPostAv1Canvas: function (canvas) {
                if (!canvas) return false;
                this._dsCanvas = canvas;
                // A-Frame canvas material — ShaderMaterial on the flat preview was black on Quest.
                this.applyCanvasVideo();
                var video = this.video;
                var src = (video && (video.currentSrc || video.src)) || "";
                if (video && video.videoWidth) {
                  this.setTexNote("post-AV1 canvas " + video.videoWidth + "×" + video.videoHeight
                    + (this.data.chroma ? " + chroma" : ""));
                }
                // Tick calls this every frame. One line per role/eye/size/clip, or the ring
                // fills with duplicates and drops enter-vr.
                var sig = (this.data.role || "") + "|" + (this.data.eye || "") + "|"
                  + canvas.width + "x" + canvas.height + "|" + (this.data.chroma ? "1" : "0") + "|" + src;
                if (this._postAv1Log === sig) return true;
                this._postAv1Log = sig;
                try { xrLog("post-av1-canvas", { role: this.data.role, eye: this.data.eye, w: canvas.width, h: canvas.height }); } catch (eL) {}
                return true;
              },
              applyAv1Resolve: function (tex) {
                this.ensureDomeGeometry();
                var zoom = this.isDesktopRole() ? 1 : this.domeZoom();
                if (this._uvZoom !== zoom || this._uvEyeApplied !== this.data.eye) {
                  this.applySbsUVs();
                  this._uvZoom = zoom;
                  this._uvEyeApplied = this.data.eye;
                }
                var mesh = this.el.getObject3D("mesh");
                if (!mesh || !tex) return;
                // Sample the blitted full frame (not the Quest AV1 tile atlas). Optional GPU key.
                var chromaOn = !!this.data.chroma;
                var keyCol = new THREE.Color("#00ff00");
                try { keyCol = new THREE.Color(this.data.keyColor); } catch (eKey) {}
                if (!this._av1Mat) {
                  this._av1Mat = new THREE.ShaderMaterial({
                    uniforms: {
                      tex: { value: tex },
                      keyColor: { value: keyCol },
                      similarity: { value: this.data.similarity },
                      smoothness: { value: this.data.smoothness },
                      chromaEnabled: { value: chromaOn ? 1.0 : 0.0 }
                    },
                    vertexShader: "varying vec2 vUv; void main(){ vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }",
                    fragmentShader: [
                      "uniform sampler2D tex;",
                      "uniform vec3 keyColor;",
                      "uniform float similarity;",
                      "uniform float smoothness;",
                      "uniform float chromaEnabled;",
                      "varying vec2 vUv;",
                      "void main(){",
                      "  vec4 videoColor = texture2D(tex, vUv);",
                      "  if (chromaEnabled < 0.5) { gl_FragColor = videoColor; return; }",
                      "  float cr = 0.5 * videoColor.r - 0.4187 * videoColor.g - 0.0813 * videoColor.b;",
                      "  float cb = -0.1687 * videoColor.r - 0.3313 * videoColor.g + 0.5 * videoColor.b;",
                      "  float keyCr = 0.5 * keyColor.r - 0.4187 * keyColor.g - 0.0813 * keyColor.b;",
                      "  float keyCb = -0.1687 * keyColor.r - 0.3313 * keyColor.g + 0.5 * keyColor.b;",
                      "  float dist = sqrt((cr - keyCr) * (cr - keyCr) + (cb - keyCb) * (cb - keyCb));",
                      "  float blend = smoothstep(similarity, similarity + smoothness, dist);",
                      "  gl_FragColor = vec4(videoColor.rgb * blend, blend);",
                      "}"
                    ].join("\n"),
                    side: THREE.DoubleSide,
                    toneMapped: false,
                    transparent: chromaOn,
                    premultipliedAlpha: chromaOn,
                    depthWrite: !chromaOn,
                    alphaTest: 0
                  });
                } else {
                  this._av1Mat.uniforms.tex.value = tex;
                  this._av1Mat.uniforms.keyColor.value.copy(keyCol);
                  this._av1Mat.uniforms.similarity.value = this.data.similarity;
                  this._av1Mat.uniforms.smoothness.value = this.data.smoothness;
                  this._av1Mat.uniforms.chromaEnabled.value = chromaOn ? 1.0 : 0.0;
                  this._av1Mat.transparent = chromaOn;
                  this._av1Mat.premultipliedAlpha = chromaOn;
                  this._av1Mat.depthWrite = !chromaOn;
                  this._av1Mat.alphaTest = 0;
                }
                var mat = this._av1Mat;
                this._gpuSig = "";
                if (this._mode !== "av1rt" || mesh.material !== mat) {
                  mesh.traverse(function (node) {
                    if (!node.isMesh) return;
                    node.material = mat;
                  });
                }
                if (this._mode !== "av1rt") {
                  var video = this.video;
                  this.setTexNote("AV1 full frame " + (video && video.videoWidth ? video.videoWidth : "?")
                    + "×" + (video && video.videoHeight ? video.videoHeight : "?")
                    + (chromaOn ? " + chroma" : ""));
                  this._mode = "av1rt";
                  this.syncEyeLayers();
                } else {
                  this._mode = "av1rt";
                }
              },
              eyeLayer: function () {
                if (this.data.eye === "left") return 1;
                if (this.data.eye === "right") return 2;
                return 0;
              },
              isImmersiveStereo: function () {
                var sceneEl = this.el.sceneEl;
                if (!sceneEl) return false;
                try {
                  if (sceneEl.is && (sceneEl.is("vr-mode") || sceneEl.is("ar-mode"))) return true;
                } catch (e) {}
                try {
                  var xr = sceneEl.renderer && sceneEl.renderer.xr;
                  if (xr && xr.isPresenting) return true;
                } catch (e2) {}
                return false;
              },
              applySbsUVs: function (eyeOverride) {
                var mesh = this.el.getObject3D("mesh");
                if (!mesh) return;
                var eye = eyeOverride || this.data.eye;
                var sbs = !!(this.data.sbs && !this.isDesktopRole());
                mesh.traverse(function (node) {
                  if (!node.isMesh || !node.geometry || !node.geometry.attributes || !node.geometry.attributes.uv) return;
                  var geo = node.geometry;
                  if (!geo.userData) geo.userData = {};
                  var uv = geo.attributes.uv;
                  if (!geo.userData._xrBaseUv) {
                    geo.userData._xrBaseUv = Float32Array.from(uv.array);
                  }
                  var base = geo.userData._xrBaseUv;
                  var arr = uv.array;
                  var u0 = 0;
                  var uSpan = 1;
                  if (sbs && eye === "left") uSpan = 0.5;
                  else if (sbs && eye === "right") { u0 = 0.5; uSpan = 0.5; }
                  for (var i = 0; i < arr.length; i += 2) {
                    var u = base[i];
                    var v = base[i + 1];
                    arr[i] = u0 + uSpan * u;
                    arr[i + 1] = v;
                  }
                  uv.needsUpdate = true;
                });
              },
              isArMode: function () {
                try {
                  var sceneEl = this.el.sceneEl;
                  return !!(sceneEl && sceneEl.is && sceneEl.is("ar-mode"));
                } catch (e) {
                  return false;
                }
              },
              syncEyeLayers: function () {
                // Stereo VR: left dome on layer 1, right dome on layer 2. three.js WebXR enables
                // layer 1 only on the left eye camera and layer 2 only on the right one, so each
                // eye draws its own dome. The XR cameras are never edited here; their defaults
                // are what makes this work, and nothing carries over from an AR session.
                // AR, mono and not-yet-presenting: layer 0, left dome only (left half, both eyes).
                var mesh = this.el.getObject3D("mesh");
                var immersive = this.isImmersiveStereo();
                var desktop = this.isDesktopRole();
                var isAR = this.isArMode();
                var presenting = false;
                try {
                  var sceneEl = this.el.sceneEl;
                  presenting = !!(sceneEl && sceneEl.renderer && sceneEl.renderer.xr && sceneEl.renderer.xr.isPresenting);
                } catch (e0) {}
                var stereo = !desktop && immersive && presenting && !isAR && !!this.data.sbs;
                var layerBit = stereo ? this.eyeLayer() : 0;
                if (mesh) {
                  mesh.traverse(function (node) {
                    if (node && node.layers) node.layers.set(layerBit);
                  });
                }
                if (this.el.object3D) this.el.object3D.layers.set(layerBit);
                var show;
                if (desktop) {
                  // Flat a-video: PC / magic-window only. The HTML preview covers the page except
                  // the bottom strip; leaving the plane on paints a second copy in that strip.
                  show = !immersive;
                  if (show && this.isQuestBrowser()) {
                    var flatVid = !!(this.video && this.video.classList.contains("xr-flat-preview"));
                    var keyedPrev = false;
                    try {
                      var keyedNode = document.getElementById("xr-ds-canvas");
                      keyedPrev = !!(keyedNode && keyedNode.classList.contains("xr-keyed-preview"));
                    } catch (ePlane) {}
                    if (flatVid || keyedPrev) show = false;
                  }
                } else if (this.data.eye === "right") {
                  show = stereo;
                } else {
                  // Domes are immersive only (an always-on left dome overlays the flat screen).
                  show = immersive;
                }
                if (this.el.object3D) this.el.object3D.visible = show;
                var sig = layerBit + "|" + (show ? 1 : 0) + "|" + (isAR ? 1 : 0);
                if (!desktop && this._eyeLayerSig !== sig) {
                  this._eyeLayerSig = sig;
                  try { xrLog("eye-layers", { eye: this.data.eye, layer: layerBit, visible: show, ar: isAR }); } catch (eLog) {}
                }
              },
              bindMaterial: function (mat) {
                var mesh = this.el.getObject3D("mesh");
                if (!mesh || !mat) return false;
                mesh.traverse(function (node) {
                  if (!node.isMesh) return;
                  node.material = mat;
                  try { delete node.onBeforeRender; } catch (eHook) {}
                });
                if (this.el.components.material) {
                  this.el.components.material.material = mat;
                }
                this.syncEyeLayers();
                return true;
              },
              // AV1 puts a ShaderMaterial on the mesh directly. A later setAttribute("material")
              // with the same flat/chroma schema is a no-op, so the dome stays on the blit RT
              // and the next HEVC clip looks blank. Put A-Frame's material back on the mesh.
              restoreAFrameMaterial: function () {
                if (!(__xrDs.av1Known && __xrDs.av1 === false)) return false;
                var comp = this.el.components && this.el.components.material;
                var mat = comp && comp.material;
                if (!mat || mat === this._av1Mat) return false;
                var mesh = this.el.getObject3D("mesh");
                if (!mesh) return false;
                var av1Mat = this._av1Mat;
                var stuck = this._mode === "av1rt";
                mesh.traverse(function (node) {
                  if (node.isMesh && av1Mat && node.material === av1Mat) stuck = true;
                });
                if (!stuck && mesh.material !== av1Mat) return false;
                try { if (mat.map) mat.map.needsUpdate = true; } catch (eMap) {}
                return this.bindMaterial(mat);
              },
              // New VideoTexture after AV1. Reusing the pre-AV1 map stays black on Quest.
              rebuildLiveVideoMaterial: function () {
                var srcNow = (this.video && (this.video.currentSrc || this.video.src)) || "";
                var chromaOn = !!this.data.chroma;
                var key = "#00ff00";
                try { key = "#" + new THREE.Color(this.data.keyColor).getHexString(); } catch (eK) {}
                try { this.el.removeAttribute("material"); } catch (eRm) {}
                try {
                  if (chromaOn) {
                    this.el.setAttribute("material", {
                      shader: "xr-chroma",
                      src: "#chroma-stream",
                      keyColor: key,
                      similarity: this.data.similarity,
                      smoothness: this.data.smoothness,
                      side: "double",
                      transparent: true,
                      opacity: 1,
                      depthWrite: false,
                      alphaTest: 0.08,
                      npot: true
                    });
                  } else {
                    this.el.setAttribute("material", {
                      shader: "flat",
                      src: "#chroma-stream",
                      color: "#ffffff",
                      side: "double",
                      transparent: false,
                      npot: true
                    });
                  }
                } catch (eSet) {}
                var comp = this.el.components && this.el.components.material;
                var mat = comp && comp.material;
                if (!mat) return false;
                try { if (mat.map) mat.map.needsUpdate = true; } catch (eMap) {}
                this._mode = chromaOn ? "gpu" : "native";
                this._gpuSig = "";
                this._rebuiltFor = srcNow;
                return this.bindMaterial(mat);
              },
              applyNativeVideo: function () {
                this._mode = "native";
                this._gpuSig = "";
                this.ensureDomeGeometry();
                this.applySbsUVs();
                // Desktop: keep A-Frame's own video material (VideoTexture MeshBasic was black on PC).
                // Domes (immersive-only callers): same attribute path once session starts.
                try {
                  this.el.setAttribute("material", {
                    shader: "flat",
                    src: "#chroma-stream",
                    color: "#ffffff",
                    side: "double",
                    transparent: false,
                    npot: true
                  });
                } catch (e) {}
                this.restoreAFrameMaterial();
                // Ensure flat screen is on after material bind (dome thrash used to leave it hidden/black).
                if (this.isDesktopRole() && this.el.object3D && !this.isImmersiveStereo()) {
                  this.el.object3D.visible = true;
                }
                this.syncEyeLayers();
                return true;
              },
              applyGpuChroma: function (canvas) {
                this.ensureDomeGeometry();
                this.applySbsUVs();
                var src = (canvas && canvas.id) ? ("#" + canvas.id) : "#chroma-stream";
                var sizeKey = canvas ? (canvas.width + "x" + canvas.height) : "video";
                var key = "#00ff00";
                try { key = "#" + new THREE.Color(this.data.keyColor).getHexString(); } catch (eK) {}
                var sig = src + "|" + sizeKey + "|" + key + "|" + this.data.similarity + "|" + this.data.smoothness;
                if (this._gpuSig === sig && (this._mode === "gpu" || (canvas && this._mode === "canvas"))) return true;
                this._gpuSig = sig;
                this._dsCanvas = canvas || null;
                this._mode = canvas ? "canvas" : "gpu";
                this._canvasSrc = src;
                this._canvasSize = sizeKey;
                try {
                  this.el.setAttribute("material", {
                    shader: "xr-chroma",
                    src: src,
                    keyColor: key,
                    similarity: this.data.similarity,
                    smoothness: this.data.smoothness,
                    side: "double",
                    transparent: true,
                    opacity: 1,
                    depthWrite: false,
                    alphaTest: 0.08,
                    npot: true
                  });
                } catch (e) {}
                try {
                  var mesh = this.el.getObject3D("mesh");
                  if (mesh && mesh.material) {
                    mesh.material.transparent = true;
                    mesh.material.depthWrite = false;
                    mesh.material.toneMapped = false;
                    if ("alphaTest" in mesh.material) mesh.material.alphaTest = 0.08;
                  }
                } catch (e2) {}
                if (!canvas) this.setTexNote("");
                this.restoreAFrameMaterial();
                if (this.isDesktopRole() && this.el.object3D && !this.isImmersiveStereo()) {
                  this.el.object3D.visible = true;
                }
                this.syncEyeLayers();
                return true;
              },
              applyShaderVideo: function (videoTex) {
                var data = this.data;
                var uvX = data.eye === "right" ? 0.5 : 0;
                if (this.isDesktopRole()) uvX = 0;
                var sbsOn = !!(data.sbs && !this.isDesktopRole());
                if (!this.shaderMaterial) {
                  this.shaderMaterial = xrMakeChromaMaterial(videoTex, data, uvX);
                } else {
                  this.shaderMaterial.uniforms.textureMap.value = videoTex;
                  this.shaderMaterial.uniforms.uvOffset.value.set(uvX, 0);
                  this.shaderMaterial.uniforms.keyColor.value.set(data.keyColor);
                  this.shaderMaterial.uniforms.similarity.value = data.similarity;
                  this.shaderMaterial.uniforms.smoothness.value = data.smoothness;
                  this.shaderMaterial.uniforms.chromaEnabled.value = data.chroma ? 1.0 : 0.0;
                  this.shaderMaterial.uniforms.sbsEnabled.value = sbsOn ? 1.0 : 0.0;
                  this.shaderMaterial.transparent = !!data.chroma;
                  this.shaderMaterial.depthWrite = !data.chroma;
                }
                this._mode = "shader";
                return this.bindMaterial(this.shaderMaterial);
              },
              applyMaterial: function () {
                // Domes must not touch A-Frame's shared video material until immersive.
                // Otherwise they thrash #chroma-stream and the PC flat a-video goes black.
                if (!this.isDesktopRole() && !this.isImmersiveStereo()) {
                  this.syncEyeLayers();
                  return;
                }
                this.ensureDomeGeometry();
                var mesh = this.el.getObject3D("mesh");
                if (!mesh) {
                  if (this._retries++ < 100) setTimeout(this._onApply, 50);
                  return;
                }
                this.syncEyeLayers();
                // Flat AV1 preview is the <video> element. A canvas copy is the tile atlas,
                // and a WebGL upload here blanks that element.
                if (this.isDesktopRole() && !this.isImmersiveStereo() && this.isQuestBrowser()
                    && __xrDs.av1Known && __xrDs.av1 === true && !this.data.chroma) {
                  return;
                }
                if (this.isDesktopRole() && !this.isImmersiveStereo() && this.isQuestBrowser()
                    && this.data.chroma && this.drawsSharedFrame()) {
                  var rendererP = this.el.sceneEl && this.el.sceneEl.renderer;
                  var preview = xrKeyedPreviewCanvas(rendererP, this.video, this.chromaArgs());
                  if (!preview && !(__xrDs.av1Known && __xrDs.av1 === true)) {
                    preview = xrDrawDownscale(this.video, this.downscaleTarget(), this.chromaArgs(), "flat");
                  }
                  if (preview) this.applyPostAv1Canvas(preview);
                  return;
                }
                // Quest dome: AV1, and HEVC when chroma is on, sample the blit (GPU key).
                var srcNowMat = xrVideoSrc(this.video);
                var questDomeGpu = this.isQuestBrowser() && !this.isDesktopRole() && !__xrDs.suspendBlit
                  && ((__xrDs.av1Known && __xrDs.av1 === true) || !!this.data.chroma);
                if (questDomeGpu && __xrDs.resolved && __xrDs.resolvedSrc === srcNowMat) {
                  this.applyAv1Resolve(__xrDs.resolved);
                  return;
                }
                if (questDomeGpu) {
                  this.holdPreviewCanvas();
                  return;
                }
                // Quest VideoTexture stays black once this session has blitted AV1.
                if (this.needsPostAv1Canvas()) {
                  if (this.drawsSharedFrame()) {
                    var postSlot2 = this.isDesktopRole() ? "flat" : "ar";
                    var postCanvas = xrDrawDownscale(this.video, this.downscaleTarget(), this.chromaArgs(), postSlot2);
                    if (postCanvas && this.applyPostAv1Canvas(postCanvas)) return;
                    if (this._dsCanvas && this._dsSrc === xrVideoSrc(this.video) && this.applyPostAv1Canvas(this._dsCanvas)) return;
                  } else {
                    this.holdPreviewCanvas();
                  }
                  return;
                }
                if (this.data.chroma) {
                  if (this.isQuestBrowser()) {
                    // xr-chroma on a Quest video texture stays black. Key into a canvas
                    // and bind A-Frame's flat material. The headset already returned above.
                    if (this.drawsSharedFrame()) {
                      var keyed = xrDrawDownscale(this.video, this.downscaleTarget(), this.chromaArgs(), this.isDesktopRole() ? "flat" : "ar");
                      if (keyed && this.applyPostAv1Canvas(keyed)) return;
                    } else if (this.holdPreviewCanvas()) return;
                    this.applyNativeVideo();
                    return;
                  }
                  var scaled = null;
                  var video = this.video;
                  if (video && video.videoWidth) {
                    var limit = this.maxWebGLTextureSize();
                    if (video.videoWidth > limit || video.videoHeight > limit) {
                      scaled = this.refreshDownscaleCanvas(false);
                    }
                  }
                  this.applyGpuChroma(scaled);
                  return;
                }
                // 8K / huge SBS: downscale into canvas so WebGL can upload (native video tex → black).
                var dsTex = this.refreshDownscaleCanvas(false);
                if (dsTex) {
                  this.applyCanvasVideo();
                  return;
                }
                if (!this.wantsShader()) {
                  this.applyNativeVideo();
                  return;
                }
                var videoTex = xrEnsureVideoTexture(this.video);
                if (!videoTex) {
                  this.applyNativeVideo();
                  if (this._retries++ < 100) setTimeout(this._onApply, 100);
                  return;
                }
                this.applyShaderVideo(videoTex);
              },
              applyShader: function () {
                this.applyMaterial();
              }
            });

            // Quest often re-injects a gaze fuse ring (center donut). Strip it on load / enter-VR.
            AFRAME.registerComponent("no-gaze-cursor", {
              init: function () {
                var sceneEl = this.el;
                function kill() {
                  try {
                    sceneEl.querySelectorAll("a-cursor, [cursor]").forEach(function (el) {
                      if (el.parentNode) el.parentNode.removeChild(el);
                    });
                    var camEl = sceneEl.camera && sceneEl.camera.el;
                    if (camEl) {
                      camEl.querySelectorAll("a-cursor, [cursor]").forEach(function (el) {
                        if (el.parentNode) el.parentNode.removeChild(el);
                      });
                      if (camEl.components && camEl.components.cursor) {
                        try { camEl.removeAttribute("cursor"); } catch (e) {}
                      }
                    }
                  } catch (e) {}
                }
                this._kill = kill;
                sceneEl.addEventListener("loaded", kill);
                sceneEl.addEventListener("enter-vr", kill);
                sceneEl.addEventListener("exit-vr", kill);
                setTimeout(kill, 0);
                setTimeout(kill, 500);
              },
              tick: function () {
                // Cheap: only act if a cursor node crept back in.
                if (this.el.querySelector("a-cursor, [cursor]")) this._kill();
              },
              remove: function () {
                var sceneEl = this.el;
                if (!this._kill) return;
                sceneEl.removeEventListener("loaded", this._kill);
                sceneEl.removeEventListener("enter-vr", this._kill);
                sceneEl.removeEventListener("exit-vr", this._kill);
              }
            });

            AFRAME.registerComponent("env-toggle", {
              init: function () {
                var sky = document.querySelector("#virtual-sky");
                var sceneEl = this.el.sceneEl;
                var hudEl = this.el;
                var isPassthrough = false;
                function immersiveNow() {
                  try {
                    return !!(sceneEl && sceneEl.is && (sceneEl.is("vr-mode") || sceneEl.is("ar-mode")));
                  } catch (e) {
                    return false;
                  }
                }
                function syncHudVisible() {
                  var ar = false;
                  try { ar = !!(sceneEl && sceneEl.is && sceneEl.is("ar-mode")); } catch (e) {}
                  // Enter AR is already passthrough — hide the green toggle there (VR-only).
                  var on = immersiveNow() && !ar;
                  try { hudEl.setAttribute("visible", on ? "true" : "false"); } catch (e2) {}
                  if (hudEl.object3D) hudEl.object3D.visible = on;
                }
                function applyPassthrough(on) {
                  isPassthrough = !!on;
                  if (isPassthrough) {
                    if (sky) sky.setAttribute("visible", "false");
                    if (sceneEl) {
                      try { sceneEl.setAttribute("background", "transparent: true"); } catch (e) {}
                      if (sceneEl.renderer) sceneEl.renderer.setClearColor("#000", 0);
                    }
                    var t1 = document.querySelector("#btn-text");
                    if (t1) t1.setAttribute("value", "VR Void");
                  } else {
                    if (sky) sky.setAttribute("visible", "true");
                    if (sceneEl) {
                      try { sceneEl.setAttribute("background", "color: #0a0a0a; transparent: false"); } catch (e) {}
                      if (sceneEl.renderer) sceneEl.renderer.setClearColor("#000", 1);
                    }
                    var t0 = document.querySelector("#btn-text");
                    if (t0) t0.setAttribute("value", "Passthrough");
                  }
                }
                var lastToggleMs = 0;
                function toggle() {
                  if (!immersiveNow()) return;
                  var now = Date.now();
                  if (now - lastToggleMs < 280) return;
                  lastToggleMs = now;
                  applyPassthrough(!isPassthrough);
                }
                this.el.addEventListener("click", toggle);
                this.el.addEventListener("triggerdown", toggle);
                if (sceneEl) {
                  sceneEl.addEventListener("enter-vr", function () {
                    syncHudVisible();
                    function apply() {
                      var ar = !!(sceneEl.is && sceneEl.is("ar-mode"));
                      applyPassthrough(ar);
                    }
                    // The first VR session after AR can run before the clear color flips back.
                    apply();
                    setTimeout(apply, 50);
                    setTimeout(apply, 300);
                  });
                  sceneEl.addEventListener("exit-vr", function () {
                    applyPassthrough(false);
                    syncHudVisible();
                  });
                }
                syncHudVisible();
                window.__xrSetPassthrough = applyPassthrough;
                window.__xrSyncPassthroughHud = syncHudVisible;
              }
            });
          })();
          </script>
          <style>
            body { margin: 0; font-family: system-ui, sans-serif; background: #111; color: #eee; }
            .play-overlay {
              position: fixed; inset: 0; background: #111; color: #fff;
              display: flex; flex-direction: column; justify-content: center; align-items: center;
              z-index: 9999; padding: 1.25rem; text-align: center; box-sizing: border-box;
            }
            .play-overlay h1 { margin: 0 0 0.35rem; font-size: 1.35rem; }
            .play-overlay .muted { color: #aaa; margin: 0 0 0.75rem; max-width: 36rem; line-height: 1.4; }
            .play-overlay .warn {
              color: #fbbf24; max-width: 36rem; margin: 0 0 1rem; font-size: 0.92rem; line-height: 1.4;
            }
            .toolbar { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; justify-content: center; margin: 0.5rem 0 0.75rem; }
            .play-btn {
              padding: 0.9rem 1.6rem; font-size: 1.15rem; background: #22c55e; border: none;
              border-radius: 999px; color: #fff; cursor: pointer; font-weight: 700;
            }
            .toolbar button, .toolbar select {
              padding: 0.45rem 0.75rem; font-size: 0.95rem; border-radius: 6px; border: 1px solid #444;
              background: #222; color: #eee;
            }
            #xr-label { font-size: 0.9rem; color: #9ca3af; word-break: break-all; max-width: 40rem; }
            a.back { color: #93c5fd; margin-top: 0.75rem; }
            .toolbar button.active { background: #166534; border-color: #22c55e; }
            .xr-file-panel {
              width: min(40rem, 100%); max-height: min(42vh, 22rem); overflow: auto;
              text-align: left; border: 1px solid #333; border-radius: 8px; background: #1a1a1a;
              margin: 0.25rem 0 0.75rem;
            }
            .xr-file-group {
              padding: 0.45rem 0.75rem 0.2rem; font-size: 0.75rem; letter-spacing: 0.04em;
              text-transform: uppercase; color: #9ca3af; position: sticky; top: 0; background: #1a1a1a;
            }
            .xr-file-item {
              display: block; width: 100%; box-sizing: border-box; text-align: left;
              padding: 0.55rem 0.75rem; border: 0; border-top: 1px solid #2a2a2a;
              background: transparent; color: #eee; cursor: pointer; font-size: 0.9rem;
            }
            .xr-file-item:hover { background: #262626; }
            .xr-file-item.selected { background: #14532d; }
            .xr-file-item .xr-file-name { display: block; word-break: break-all; }
            .xr-file-item .xr-file-meta { display: block; color: #9ca3af; font-size: 0.78rem; margin-top: 0.15rem; }
            .xr-file-empty { padding: 0.85rem 0.75rem; color: #9ca3af; font-size: 0.9rem; }
            /* Archive: compact current-selection chip → centered top dropdown (above a-scene). */
            .xr-archive-pick-wrap {
              width: min(40rem, 100%); margin: 0.25rem 0 0.75rem; text-align: left;
            }
            .xr-archive-pick {
              display: flex; align-items: center; gap: 0.5rem; width: 100%; box-sizing: border-box;
              padding: 0.7rem 0.85rem; border-radius: 10px; border: 1px solid #3f3f46;
              background: #14532d; color: #f8fafc; font: inherit; font-size: 0.95rem;
              cursor: pointer; text-align: left;
            }
            .xr-archive-pick .xr-archive-pick-label {
              flex: 1 1 auto; min-width: 0; word-break: break-all;
            }
            .xr-archive-pick .xr-archive-pick-chevron { flex: 0 0 auto; opacity: 0.85; }
            #xr-archive-dd {
              display: none; position: fixed; inset: 0; z-index: 10060;
              align-items: flex-start; justify-content: center;
              padding: max(0.75rem, env(safe-area-inset-top, 0px) + 0.5rem) 0.75rem 1rem;
              box-sizing: border-box;
              background: rgba(0, 0, 0, 0.55);
            }
            #xr-archive-dd.open { display: flex; }
            #xr-archive-dd .xr-archive-dd-panel {
              width: min(36rem, 100%); max-height: min(70vh, 28rem);
              overflow: auto; border-radius: 12px; border: 1px solid #334155;
              background: #0f172a; box-shadow: 0 16px 48px rgba(0,0,0,0.55);
              margin-top: 0.25rem;
            }
            #xr-archive-dd .xr-archive-dd-head {
              position: sticky; top: 0; z-index: 1;
              display: flex; align-items: center; gap: 0.5rem;
              padding: 0.65rem 0.75rem; background: #0f172a; border-bottom: 1px solid #1e293b;
              font-size: 0.8rem; letter-spacing: 0.04em; text-transform: uppercase; color: #94a3b8;
            }
            #xr-archive-dd .xr-archive-dd-close {
              margin-left: auto; padding: 0.35rem 0.65rem; border-radius: 6px;
              border: 1px solid #475569; background: #1e293b; color: #f8fafc; cursor: pointer; font: inherit;
            }
            #xr-archive-dd .xr-file-item { border-top-color: #1e293b; }
            #xr-archive-float {
              display: none; position: fixed; left: 50%; top: max(0.65rem, env(safe-area-inset-top, 0px) + 0.35rem);
              transform: translateX(-50%); z-index: 10040; width: min(36rem, calc(100vw - 1.5rem));
            }
            #xr-archive-float .xr-archive-pick {
              box-shadow: 0 8px 28px rgba(0,0,0,0.45);
            }
            #xr-reopen {
              display: none; position: fixed; right: 1rem; bottom: 1rem; z-index: 10000;
              padding: 0.7rem 1rem; border-radius: 999px; border: 1px solid #444;
              background: #166534; color: #fff; font-weight: 700; cursor: pointer;
            }
            #xr-transport {
              /* Same bottom row as Enter AR / Enter VR. Stop short of that column
                 (AR sits near right: 60px, about 15rem wide with VR). A full-width
                 bar paints over the buttons because a-scene is its own stacking context. */
              display: none; position: fixed; left: 0.75rem; right: 15.5rem; bottom: 0.45rem;
              z-index: 10050; width: auto; overflow: hidden;
              padding: 0.55rem 0.75rem; border-radius: 12px; border: 1px solid #333;
              background: rgba(15, 23, 42, 0.92); color: #f8fafc;
              box-shadow: 0 8px 28px rgba(0,0,0,0.45); backdrop-filter: blur(6px);
              pointer-events: auto;
            }
            #xr-transport .xr-transport-row {
              display: flex; flex-wrap: nowrap; gap: 0.45rem; align-items: center;
            }
            #xr-transport .xr-transport-row + .xr-transport-row { margin-top: 0.45rem; }
            #xr-transport .xr-view-row label {
              flex: 1 1 0; min-width: 0;
              display: flex; align-items: center; gap: 0.35rem; font-size: 0.85rem;
            }
            #xr-transport .xr-view-row input[type="range"] {
              flex: 1 1 auto; width: auto; min-width: 0; height: 1.65rem;
            }
            #xr-transport button {
              padding: 0.4rem 0.65rem; border-radius: 6px; border: 1px solid #444;
              background: #1e293b; color: #f8fafc; cursor: pointer; font: inherit;
              pointer-events: auto;
            }
            #xr-transport #xr-seek {
              flex: 1 1 auto; width: 1px; min-width: 6rem; height: 1.65rem;
              accent-color: #22c55e; touch-action: none; pointer-events: auto; cursor: pointer;
            }
            #xr-transport #xr-time {
              font-variant-numeric: tabular-nums; font-size: 0.85rem; color: #cbd5e1;
              min-width: 7.5rem; text-align: right;
            }
            #xr-transport #xr-tex-note {
              width: 100%; font-size: 0.75rem; color: #fbbf24; margin: 0.35rem 0 0;
            }
            /* Texture source — must stay in layout with tiny opacity (opacity:0 / display:none → black VideoTexture on Quest/PC). */
            #chroma-stream {
              position: fixed; left: 0; top: 0; width: 16px; height: 16px;
              opacity: 0.01; pointer-events: none; z-index: 0; overflow: hidden;
            }
            /* Last-resort PC preview when even canvas downscale fails (rare). */
            #xr-ds-canvas, #xr-ds-ar {
              position: fixed; left: 0; top: 0; width: 16px; height: 16px;
              opacity: 0.01; pointer-events: none; z-index: 0;
            }
            #chroma-stream.xr-pip {
              left: auto; right: 1rem; top: auto; bottom: 5.5rem; z-index: 10045;
              width: min(480px, 46vw); height: auto; max-height: 36vh;
              opacity: 1; background: #000; border: 2px solid #22c55e; border-radius: 8px;
            }
            /* Quest flat preview. One full picture, above the Enter AR / Enter VR row.
               The WebGL plane stays hidden so it does not tile a second copy in that gap. */
            #chroma-stream.xr-flat-preview,
            #xr-ds-canvas.xr-keyed-preview {
              left: 0; top: 0; width: 100vw; height: calc(100vh - 6.5rem); max-height: none;
              opacity: 1; z-index: 2; object-fit: contain; background: #111; border: 0; border-radius: 0;
            }
            a-scene { z-index: 1; }
            /* Hide gaze fuse reticle (center donut) if A-Frame / Quest re-injects it. */
            a-cursor, .a-cursor, [cursor] {
              display: none !important;
              visibility: hidden !important;
              opacity: 0 !important;
              pointer-events: none !important;
            }
            /* A-Frame HTTPS / sensor gate — default white-on-light is unreadable on Quest. */
            .a-dialog,
            .a-modal,
            .a-enter-vr-modal {
              background: #0f172a !important;
              border: 2px solid #fbbf24 !important;
              border-radius: 12px !important;
              color: #f8fafc !important;
              box-shadow: 0 12px 40px rgba(0,0,0,0.75) !important;
              max-width: min(92vw, 28rem) !important;
              padding: 1.25rem 1.35rem !important;
              z-index: 10050 !important;
            }
            .a-dialog-text-container,
            .a-dialog-text,
            .a-dialog p,
            .a-modal p,
            .a-enter-vr-modal p {
              color: #f8fafc !important;
              font-size: 1.2rem !important;
              line-height: 1.45 !important;
              font-weight: 600 !important;
              text-shadow: 0 1px 2px #000 !important;
            }
            .a-dialog-ok-button,
            .a-dialog-allow-button,
            .a-dialog-deny-button,
            .a-dialog button,
            .a-modal button {
              background: #22c55e !important;
              color: #052e16 !important;
              border: none !important;
              border-radius: 8px !important;
              font-weight: 700 !important;
              font-size: 1.05rem !important;
              padding: 0.55rem 1.1rem !important;
              margin: 0.35rem !important;
            }
            .a-dialog-deny-button {
              background: #334155 !important;
              color: #f8fafc !important;
            }
          </style>
        </head>
        <body>
          <button type="button" id="xr-reopen" aria-label="Show file list">Files</button>
          <div id="xr-archive-float" hidden></div>
          <div id="xr-archive-dd" aria-hidden="true">
            <div class="xr-archive-dd-panel" role="listbox" aria-label="Archive folder videos">
              <div class="xr-archive-dd-head">
                <span>Archive folder</span>
                <button type="button" class="xr-archive-dd-close" id="xr-archive-dd-close">Close</button>
              </div>
              <div id="xr-archive-dd-list"></div>
            </div>
          </div>
          <div id="xr-transport" role="group" aria-label="Playback controls" hidden>
            <div class="xr-transport-row">
              <button type="button" id="xr-playpause" title="Play / Pause">Play</button>
              <button type="button" id="xr-seek-back" title="Back 10 seconds">−10s</button>
              <button type="button" id="xr-seek-fwd" title="Forward 10 seconds">+10s</button>
              <input type="range" id="xr-seek" min="0" max="0" step="0.1" value="0" aria-label="Seek">
              <span id="xr-time">0:00 / 0:00</span>
              <label style="display:flex;align-items:center;gap:0.35rem;font-size:0.85rem">Key
                <input type="color" id="xr-chroma-key-play" value="#00ff00" aria-label="Chroma key color">
              </label>
              <label style="display:flex;align-items:center;gap:0.35rem;font-size:0.85rem">Vol
                <input type="range" id="xr-volume" min="0" max="1" step="0.1" value="1" style="width:7rem" aria-label="Volume">
              </label>
            </div>
            <div class="xr-transport-row xr-view-row">
              <label title="How many degrees the shell covers (180° → 90°). Packs the full frame onto a shorter arc.">FOV
                <input type="range" id="xr-zoom" min="0.5" max="1" step="0.1" value="1" aria-label="Field of view degrees">
              </label>
              <label title="Skybox / PLAY’A style. Left = zoom in (dome closer). Right = zoom out (dome farther, face smaller).">Zoom
                <span>In</span>
                <input type="range" id="xr-dist" min="0" max="12" step="0.5" value="0" aria-label="Zoom: in on the left, out on the right">
                <span>Out</span>
              </label>
            </div>
            <p id="xr-tex-note" hidden></p>
          </div>
          <div id="overlay" class="play-overlay">
            <h1>3D Chroma Key 180° Player</h1>
            <p class="muted">Three playlists: <strong>Loop</strong> = <code>\#(mediaRootHTML)loop/op_*.mp4</code> · <strong>Working</strong> = any playable file in the media root next to <code>_working.mp4</code> · <strong>Archive</strong> = <code>\#(mediaRootHTML)archive/</code> folder</p>
            <p class="warn">Quest WebXR needs a <strong>secure context</strong>: prefer Quest <code>chrome://flags</code> insecure-origin + LAN <code>http://</code> (see LAN page). Cloudflare tunnel is optional (slow). Passthrough = <strong>Enter AR</strong> (not Enter VR). A-Frame CDN needs internet on the headset once.</p>
            <p id="xr-webxr-status" class="muted" style="font-size:0.85rem;max-width:36rem" role="status">Checking WebXR…</p>
            <div class="toolbar" role="group" aria-label="Playlist">
              <button type="button" id="xr-mode-loop" class="active">Loop</button>
              <button type="button" id="xr-mode-working">Working</button>
              <button type="button" id="xr-mode-archive">Archive folder</button>
              <button type="button" id="xr-refresh-list">Refresh list</button>
            </div>
            <div id="xr-file-list" class="xr-file-panel" role="listbox" aria-label="Media files"></div>
            <div class="toolbar">
              <button type="button" id="xr-prev">Prev</button>
              <button type="button" id="xr-next">Next</button>
              <label>Speed
                <select id="xr-rate" aria-label="Playback speed">
                  <option value="0.7">0.7×</option>
                  <option value="0.8">0.8×</option>
                  <option value="0.9">0.9×</option>
                  <option value="1" selected>1×</option>
                  <option value="1.1">1.1×</option>
                  <option value="1.2">1.2×</option>
                  <option value="1.3">1.3×</option>
                </select>
              </label>
              <label>Vol
                <input type="range" id="xr-volume-launch" min="0" max="1" step="0.1" value="1" style="width:7rem" aria-label="Volume">
              </label>
              <label><input type="checkbox" id="xr-chroma-toggle"> Chroma</label>
              <label>Key
                <input type="color" id="xr-chroma-key" value="#00ff00" aria-label="Chroma key color">
              </label>
              <label><input type="checkbox" id="xr-sbs-toggle" checked> SBS 3D (VR180)</label>
            </div>
            <p class="muted" style="font-size:0.85rem;max-width:36rem">After Launch: <strong>180° hemisphere</strong> + SBS eye-split (left/right halves). PC: mouse look / WASD. Prefer <strong>Loop</strong> for tests — <code>_working.mp4</code> is often huge/sparse/6K HEVC. Enable <strong>Chroma</strong> for green-screen over passthrough.</p>
            <p id="xr-label" role="status">Loading playlists…</p>
            <p style="margin: 1rem 0 0">
              <button type="button" class="play-btn" id="xr-launch">Launch Engine</button>
            </p>
            <p class="muted" style="margin-top:1rem;font-size:0.85rem">
              Chroma key color is the picker next to <strong>Chroma</strong>. Similarity 0.3, smoothness 0.08.
            </p>
            <a class="back" href="/">← LAN monitor</a>
            ·
            <a class="back" href="/browse">LAN browse</a>
          </div>

          <!-- Outside a-assets; tiny opacity — feeds VideoTexture (avoid display:none / opacity:0). -->
          <video id="chroma-stream" playsinline webkit-playsinline preload="auto"></video>
          <canvas id="xr-ds-canvas" width="16" height="16"></canvas>

          <a-scene
            background="color: #0a0a0a"
            no-gaze-cursor
            webxr="requiredFeatures: local-floor; optionalFeatures: bounded-floor, layers"
            xr-mode-ui="enabled: true; XRMode: xr; enterVREnabled: true; enterAREnabled: true"
            device-orientation-permission-ui="enabled: true; httpsMessage: Use Quest chrome://flags insecure-origin for this LAN http:// origin (see LAN page), or optional Cloudflare tunnel at page bottom; cancelButtonText: OK">
            <!-- PC / magic-window: native flat a-video (custom VideoTexture shader was black on desktop). -->
            <a-video
              id="chroma-screen"
              src="#chroma-stream"
              width="16"
              height="9"
              position="0 1.6 -4"
              material="shader: flat; src: #chroma-stream; side: double; npot: true"
              chroma-stereo-sbs="keyColor: #00ff00; similarity: 0.3; smoothness: 0.08; chroma: false; sbs: true; eye: both; role: desktop">
            </a-video>
            <!-- Immersive VR180: placeholder sphere; chroma-stereo-sbs replaces BufferGeometry with a true
                 THREE hemisphere (A-Frame phiLength / a-videosphere still stretch 180→360). Hidden until XR. -->
            <a-entity
              id="chroma-sphere"
              visible="false"
              geometry="primitive: sphere; radius: 20; segmentsWidth: 64; segmentsHeight: 40; phiStart: 180; phiLength: 180; thetaLength: 180"
              scale="-1 1 1"
              position="0 1.6 0"
              material="shader: flat; color: #ffffff; side: double"
              chroma-stereo-sbs="keyColor: #00ff00; similarity: 0.3; smoothness: 0.08; chroma: false; sbs: true; eye: left; role: dome">
            </a-entity>
            <a-entity
              id="chroma-sphere-right"
              visible="false"
              geometry="primitive: sphere; radius: 20; segmentsWidth: 64; segmentsHeight: 40; phiStart: 180; phiLength: 180; thetaLength: 180"
              scale="-1 1 1"
              position="0 1.6 0"
              material="shader: flat; color: #ffffff; side: double"
              chroma-stereo-sbs="keyColor: #00ff00; similarity: 0.3; smoothness: 0.08; chroma: false; sbs: true; eye: right; role: dome">
            </a-entity>

            <a-sky id="virtual-sky" color="#0a0a0a"></a-sky>
            <!-- No gaze button. Enter AR still clears the sky so keyed pixels show the room. -->
            <a-entity env-toggle visible="false"></a-entity>

            <a-entity camera look-controls wasd-controls position="0 1.6 0"></a-entity>
          </a-scene>

          <script>
          (function () {
            var MEDIA_ROOT = "\#(mediaRootJS)";
            var LOOP_PREFIX = "\#(prefixJS)";
            var ARCHIVE_PREFIX = "\#(archiveJS)";
            var RATE_KEY = "loopsegments.lan.xrChromaRate.v1";
            var VOL_KEY = "loopsegments.lan.xrVolume.v1";
            var KEY_KEY = "loopsegments.lan.xrChromaKey.v1";
            var MODE_KEY = "loopsegments.lan.xrChromaMode.v2";
            var RATES = [0.7, 0.8, 0.9, 1, 1.1, 1.2, 1.3];
            var loopPlaylist = [];
            var workingPlaylist = [];
            var archivePlaylist = [];
            var mode = "loop";
            var index = 0;
            var wantPlay = false;
            var video = document.getElementById("chroma-stream");
            var overlay = document.getElementById("overlay");
            var label = document.getElementById("xr-label");
            var rateSel = document.getElementById("xr-rate");
            var volumeEl = document.getElementById("xr-volume");
            var volumeLaunchEl = document.getElementById("xr-volume-launch");
            var launchBtn = document.getElementById("xr-launch");
            var prevBtn = document.getElementById("xr-prev");
            var nextBtn = document.getElementById("xr-next");
            var modeLoopBtn = document.getElementById("xr-mode-loop");
            var modeWorkingBtn = document.getElementById("xr-mode-working");
            var modeArchiveBtn = document.getElementById("xr-mode-archive");
            var fileListEl = document.getElementById("xr-file-list");
            var refreshBtn = document.getElementById("xr-refresh-list");
            var reopenBtn = document.getElementById("xr-reopen");
            var transport = document.getElementById("xr-transport");
            var playPauseBtn = document.getElementById("xr-playpause");
            var seekEl = document.getElementById("xr-seek");
            var seekBackBtn = document.getElementById("xr-seek-back");
            var seekFwdBtn = document.getElementById("xr-seek-fwd");
            var timeEl = document.getElementById("xr-time");
            var chromaToggle = document.getElementById("xr-chroma-toggle");
            var chromaKeyEl = document.getElementById("xr-chroma-key");
            var chromaKeyPlayEl = document.getElementById("xr-chroma-key-play");
            var sbsToggle = document.getElementById("xr-sbs-toggle");
            var seekDragging = false;
            if (!video || !overlay) return;
            // Same-origin LAN files must not use crossOrigin=anonymous (no CORS headers → black WebGL + audio OK).
            try {
              video.crossOrigin = null;
              video.removeAttribute("crossorigin");
            } catch (e) {}

            function sphereEls() {
              return [
                document.getElementById("chroma-screen"),
                document.getElementById("chroma-sphere"),
                document.getElementById("chroma-sphere-right")
              ].filter(Boolean);
            }
            function sphereComponent() {
              var sphere = document.getElementById("chroma-screen")
                || document.getElementById("chroma-sphere");
              return sphere && sphere.components && sphere.components["chroma-stereo-sbs"];
            }
            function refreshSphereShader() {
              sphereEls().forEach(function (el) {
                var comp = el.components && el.components["chroma-stereo-sbs"];
                if (comp) try { comp.applyShader(); } catch (e) {}
              });
            }
            function chromaKeyColor() {
              var raw = (chromaKeyEl && chromaKeyEl.value) || "#00ff00";
              if (!/^#[0-9a-fA-F]{6}$/.test(raw)) return "#00ff00";
              return raw.toLowerCase();
            }
            function syncShaderToggles() {
              var chromaOn = !!(chromaToggle && chromaToggle.checked);
              var sbsOn = !sbsToggle || !!sbsToggle.checked;
              var key = chromaKeyColor();
              sphereEls().forEach(function (el) {
                try {
                  el.setAttribute("chroma-stereo-sbs", "chroma", chromaOn);
                  el.setAttribute("chroma-stereo-sbs", "sbs", sbsOn);
                  el.setAttribute("chroma-stereo-sbs", "keyColor", key);
                } catch (e) {}
              });
            }
            function applyChromaKey(hex) {
              if (!/^#[0-9a-fA-F]{6}$/.test(hex || "")) hex = "#00ff00";
              hex = hex.toLowerCase();
              if (chromaKeyEl) chromaKeyEl.value = hex;
              if (chromaKeyPlayEl) chromaKeyPlayEl.value = hex;
              try { localStorage.setItem(KEY_KEY, hex); } catch (e) {}
              syncShaderToggles();
              refreshSphereShader();
            }

            function setLabel(msg) {
              if (label) label.textContent = msg || "";
            }
            function normalizeMode(m) {
              if (m === "working" || m === "archive" || m === "loop") return m;
              if (m === "media") return "working";
              return "loop";
            }
            function activePlaylist() {
              if (mode === "working") return workingPlaylist;
              if (mode === "archive") return archivePlaylist;
              return loopPlaylist;
            }
            function emptyLabel() {
              if (mode === "working") {
                return "No playable media in the media root yet — export or copy a file next to _working.mp4, then Refresh list";
              }
              if (mode === "archive") {
                return "No archive/ videos yet — finish an export, then Refresh list";
              }
              return "No loop/op_*.mp4 yet";
            }
            function modeTag() {
              if (mode === "working") return "working";
              if (mode === "archive") return "archive";
              return "loop";
            }
            function listGroupTitle() {
              if (mode === "working") return "Working (media root videos, outside archive/)";
              if (mode === "archive") return "Archive folder";
              return "Loop segments";
            }
            function leafName(path) {
              var n = normPath(path);
              var i = n.lastIndexOf("/");
              return i >= 0 ? n.slice(i + 1) : n;
            }
            function formatBytes(n) {
              var b = Number(n) || 0;
              if (b <= 0) return "";
              if (b < 1024) return b + " B";
              if (b < 1024 * 1024) return Math.round(b / 1024) + " KB";
              return (b / (1024 * 1024)).toFixed(1) + " MB";
            }
            function formatClock(sec) {
              var s = Math.max(0, Math.floor(Number(sec) || 0));
              var h = Math.floor(s / 3600);
              var m = Math.floor((s % 3600) / 60);
              var r = s % 60;
              var mm = (h > 0 ? String(m).padStart(2, "0") : String(m));
              var ss = String(r).padStart(2, "0");
              return h > 0 ? (h + ":" + mm + ":" + ss) : (mm + ":" + ss);
            }
            function syncPlayPauseLabel() {
              if (!playPauseBtn) return;
              playPauseBtn.textContent = video.paused ? "Play" : "Pause";
            }
            function mediaDuration() {
              var dur = Number(video.duration);
              if (isFinite(dur) && dur > 0) return dur;
              try {
                if (video.seekable && video.seekable.length > 0) {
                  var end = video.seekable.end(video.seekable.length - 1);
                  if (isFinite(end) && end > 0) return end;
                }
              } catch (e) {}
              return 0;
            }
            function clampSeekTime(t) {
              t = Number(t);
              if (!isFinite(t) || t < 0) t = 0;
              var dur = mediaDuration();
              if (dur > 0) t = Math.min(dur, t);
              try {
                if (video.seekable && video.seekable.length > 0) {
                  for (var i = 0; i < video.seekable.length; i++) {
                    var a = video.seekable.start(i);
                    var b = video.seekable.end(i);
                    if (t >= a && t <= b) return t;
                  }
                  // Snap to nearest seekable edge (sparse _working holes, partial buffers).
                  var best = video.seekable.start(0);
                  var bestDist = Math.abs(t - best);
                  for (var j = 0; j < video.seekable.length; j++) {
                    var s = video.seekable.start(j);
                    var e = video.seekable.end(j);
                    if (Math.abs(t - s) < bestDist) { best = s; bestDist = Math.abs(t - s); }
                    if (Math.abs(t - e) < bestDist) { best = e; bestDist = Math.abs(t - e); }
                  }
                  return best;
                }
              } catch (e) {}
              return t;
            }
            function applySeekTime(t) {
              t = clampSeekTime(t);
              if (!isFinite(t)) return;
              try {
                if (typeof video.fastSeek === "function") video.fastSeek(t);
                else video.currentTime = t;
              } catch (e) {
                try { video.currentTime = t; } catch (e2) {}
              }
              try {
                if (typeof __xrVideoTex !== "undefined" && __xrVideoTex && __xrDs.av1Known && __xrDs.av1 === true) __xrVideoTex.needsUpdate = true;
              } catch (e3) {}
              try { refreshSphereShader(); } catch (e4) {}
              syncTransportUI();
            }
            function endSeekDrag() {
              if (!seekDragging) return;
              seekDragging = false;
              if (seekEl) applySeekTime(parseFloat(seekEl.value));
              else syncTransportUI();
            }
            function syncTransportUI() {
              if (!seekEl || !timeEl) return;
              var dur = mediaDuration();
              var cur = Number(video.currentTime) || 0;
              var max = dur > 0 ? dur : Math.max(cur, 1);
              // Keep max current even while dragging so the thumb can travel the full bar.
              seekEl.min = "0";
              seekEl.max = String(max);
              if (!seekDragging) {
                seekEl.value = String(Math.min(cur, max));
              }
              timeEl.textContent = formatClock(seekDragging ? (parseFloat(seekEl.value) || cur) : cur)
                + " / " + formatClock(dur);
              syncPlayPauseLabel();
            }
            function showTransport(show) {
              if (!transport) return;
              transport.style.display = show ? "block" : "none";
              if (show) transport.removeAttribute("hidden");
              else transport.setAttribute("hidden", "");
              if (show) syncTransportUI();
            }
            function exitImmersiveIfNeeded() {
              try {
                var scene = document.querySelector("a-scene");
                if (scene && scene.is && (scene.is("vr-mode") || scene.is("ar-mode")) && scene.exitVR) {
                  scene.exitVR();
                }
              } catch (e) {}
            }
            function stopPlaybackForHome() {
              // Pause alone can leave Quest WebXR decoding / audio running under the overlay.
              // Suspend AV1 first, exit XR, then dispose GPU — never dispose while presenting.
              wantPlay = false;
              try { xrSuspendAv1Pipeline(); } catch (eSus) {}
              __xrDs.exiting = false;
              try { video.pause(); } catch (e) {}
              exitImmersiveIfNeeded();
              try {
                video.removeAttribute("src");
                video.load();
              } catch (e2) {}
              try { syncPlayPauseLabel(); } catch (e3) {}
              try { refreshSphereShader(); } catch (e4) {}
              try { xrScheduleDisposeAv1Gpu(); } catch (eDisp) {}
              try { xrLog("files-home", { sawAv1Tex: !!__xrDs.sawAv1Tex }); } catch (eL) {}
            }
            function showOverlay(show) {
              overlay.style.display = show ? "flex" : "none";
              if (reopenBtn) reopenBtn.style.display = show ? "none" : "block";
              showTransport(!show);
              if (show) {
                stopPlaybackForHome();
              } else {
                closeArchiveDropdown();
                __xrDs.exiting = false;
                __xrDs.suspendBlit = false;
                try { refreshSphereShader(); } catch (eKick) {}
                try { xrLog("launch-engine", { sawAv1Tex: !!__xrDs.sawAv1Tex }); } catch (eL) {}
              }
              syncArchiveFloat();
            }
            function seekBy(delta) {
              applySeekTime((Number(video.currentTime) || 0) + delta);
            }
            var workingSeekSec = 0;
            function refreshWorkingSeek() {
              return fetch("status.json", { cache: "no-store" })
                .then(function (r) { return r.json(); })
                .then(function (j) {
                  var w = j && j.workingSourcePlayback;
                  var s = w && Number(w.playbackStartSeconds);
                  workingSeekSec = isFinite(s) && s > 0 ? s : 0;
                })
                .catch(function () { workingSeekSec = 0; });
            }
            function applyWorkingSeekIfNeeded(item) {
              if (!item || !isSparseWorkingName(item.name) || !(workingSeekSec > 0)) return;
              var target = workingSeekSec;
              var apply = function () {
                try {
                  if (Math.abs((video.currentTime || 0) - target) > 0.5) video.currentTime = target;
                } catch (e) {}
              };
              if (video.readyState >= 1) apply();
              else {
                var onMeta = function () {
                  video.removeEventListener("loadedmetadata", onMeta);
                  apply();
                };
                video.addEventListener("loadedmetadata", onMeta);
              }
            }
            var archiveDd = document.getElementById("xr-archive-dd");
            var archiveDdList = document.getElementById("xr-archive-dd-list");
            var archiveDdClose = document.getElementById("xr-archive-dd-close");
            var archiveFloat = document.getElementById("xr-archive-float");
            function archiveSelectionLabel() {
              var playlist = archivePlaylist;
              if (!playlist.length) return emptyLabel();
              var item = playlist[index] || playlist[0];
              var sz = formatBytes(item.bytes);
              return (index + 1) + "/" + playlist.length + " · " + leafName(item.name)
                + (sz ? " · " + sz : "");
            }
            function closeArchiveDropdown() {
              if (!archiveDd) return;
              archiveDd.classList.remove("open");
              archiveDd.setAttribute("aria-hidden", "true");
            }
            function openArchiveDropdown() {
              if (!archiveDd || !archiveDdList) return;
              archiveDdList.innerHTML = "";
              var playlist = archivePlaylist;
              if (!playlist.length) {
                var empty = document.createElement("div");
                empty.className = "xr-file-empty";
                empty.textContent = emptyLabel();
                archiveDdList.appendChild(empty);
              } else {
                playlist.forEach(function (item, idx) {
                  var btn = document.createElement("button");
                  btn.type = "button";
                  btn.className = "xr-file-item" + (idx === index ? " selected" : "");
                  btn.setAttribute("role", "option");
                  btn.setAttribute("aria-selected", idx === index ? "true" : "false");
                  var nameEl = document.createElement("span");
                  nameEl.className = "xr-file-name";
                  nameEl.textContent = leafName(item.name);
                  var meta = document.createElement("span");
                  meta.className = "xr-file-meta";
                  var bits = [];
                  var sz = formatBytes(item.bytes);
                  if (sz) bits.push(sz);
                  bits.push(item.name);
                  meta.textContent = bits.join(" · ");
                  btn.appendChild(nameEl);
                  btn.appendChild(meta);
                  btn.onclick = function () {
                    closeArchiveDropdown();
                    loadIndex(idx, wantPlay && !video.paused);
                  };
                  archiveDdList.appendChild(btn);
                });
              }
              archiveDd.classList.add("open");
              archiveDd.setAttribute("aria-hidden", "false");
            }
            function makeArchivePickButton() {
              var btn = document.createElement("button");
              btn.type = "button";
              btn.className = "xr-archive-pick";
              btn.setAttribute("aria-haspopup", "listbox");
              btn.setAttribute("aria-expanded", "false");
              var labelEl = document.createElement("span");
              labelEl.className = "xr-archive-pick-label";
              labelEl.textContent = archiveSelectionLabel();
              var chev = document.createElement("span");
              chev.className = "xr-archive-pick-chevron";
              chev.textContent = "▾";
              btn.appendChild(labelEl);
              btn.appendChild(chev);
              btn.onclick = function (e) {
                e.preventDefault();
                e.stopPropagation();
                openArchiveDropdown();
              };
              return btn;
            }
            function syncArchiveFloat() {
              if (!archiveFloat) return;
              // Floater belongs on the Launch Engine picker page — not over playback.
              var overlayOpen = overlay && overlay.style.display !== "none";
              var show = mode === "archive" && overlayOpen;
              archiveFloat.style.display = show ? "block" : "none";
              if (show) {
                archiveFloat.removeAttribute("hidden");
                archiveFloat.innerHTML = "";
                archiveFloat.appendChild(makeArchivePickButton());
              } else {
                archiveFloat.setAttribute("hidden", "");
                archiveFloat.innerHTML = "";
              }
            }
            function renderFileList() {
              if (!fileListEl) return;
              fileListEl.innerHTML = "";
              var playlist = activePlaylist();
              if (mode === "archive") {
                var wrap = document.createElement("div");
                wrap.className = "xr-archive-pick-wrap";
                if (!playlist.length) {
                  var empty = document.createElement("div");
                  empty.className = "xr-file-empty";
                  empty.textContent = emptyLabel();
                  wrap.appendChild(empty);
                } else {
                  wrap.appendChild(makeArchivePickButton());
                }
                fileListEl.appendChild(wrap);
                syncArchiveFloat();
                return;
              }
              if (!playlist.length) {
                var empty2 = document.createElement("div");
                empty2.className = "xr-file-empty";
                empty2.textContent = emptyLabel();
                fileListEl.appendChild(empty2);
                syncArchiveFloat();
                return;
              }
              function addGroup(title) {
                var g = document.createElement("div");
                g.className = "xr-file-group";
                g.textContent = title;
                fileListEl.appendChild(g);
              }
              function addItem(item, idx, groupHint) {
                var btn = document.createElement("button");
                btn.type = "button";
                btn.className = "xr-file-item" + (idx === index ? " selected" : "");
                btn.setAttribute("role", "option");
                btn.setAttribute("aria-selected", idx === index ? "true" : "false");
                btn.dataset.index = String(idx);
                var nameEl = document.createElement("span");
                nameEl.className = "xr-file-name";
                nameEl.textContent = leafName(item.name);
                var meta = document.createElement("span");
                meta.className = "xr-file-meta";
                var bits = [];
                if (groupHint) bits.push(groupHint);
                var sz = formatBytes(item.bytes);
                if (sz) bits.push(sz);
                bits.push(item.name);
                meta.textContent = bits.join(" · ");
                btn.appendChild(nameEl);
                btn.appendChild(meta);
                btn.onclick = function () {
                  loadIndex(idx, wantPlay && !video.paused);
                };
                fileListEl.appendChild(btn);
              }
              addGroup(listGroupTitle());
              playlist.forEach(function (item, idx) { addItem(item, idx, modeTag()); });
              syncArchiveFloat();
            }
            if (archiveDdClose) archiveDdClose.onclick = function () { closeArchiveDropdown(); };
            if (archiveDd) {
              archiveDd.addEventListener("click", function (e) {
                if (e.target === archiveDd) closeArchiveDropdown();
              });
            }
            document.addEventListener("keydown", function (e) {
              if (e.key === "Escape") closeArchiveDropdown();
            });
            function snapRate(v) {
              var r = Math.round(Number(v) * 10) / 10;
              if (!isFinite(r)) return 1;
              for (var i = 0; i < RATES.length; i++) {
                if (Math.abs(RATES[i] - r) < 0.001) return RATES[i];
              }
              return 1;
            }
            function readRate() {
              var v = 1;
              try {
                var raw = localStorage.getItem(RATE_KEY);
                if (raw != null) v = parseFloat(raw);
              } catch (e) {}
              return snapRate(v);
            }
            function writeRate(v) {
              try { localStorage.setItem(RATE_KEY, String(snapRate(v))); } catch (e) {}
            }
            function readMode() {
              try {
                return normalizeMode(localStorage.getItem(MODE_KEY));
              } catch (e) {}
              return "loop";
            }
            function writeMode(m) {
              try { localStorage.setItem(MODE_KEY, normalizeMode(m)); } catch (e) {}
            }
            function applyRate() {
              var v = readRate();
              if (rateSel) rateSel.value = String(v);
              try { video.playbackRate = v; } catch (e) {}
            }
            function readVolume() {
              var v = 1;
              try {
                var raw = localStorage.getItem(VOL_KEY);
                if (raw != null) v = parseFloat(raw);
              } catch (e) {}
              if (!isFinite(v)) v = 1;
              return Math.max(0, Math.min(1, Math.round(v * 10) / 10));
            }
            function applyVolume(v) {
              v = Math.max(0, Math.min(1, Math.round(Number(v) * 10) / 10));
              if (!isFinite(v)) v = 1;
              try { localStorage.setItem(VOL_KEY, String(v)); } catch (e) {}
              try {
                video.volume = v;
                video.muted = v <= 0;
              } catch (e2) {}
              if (volumeEl) volumeEl.value = String(v);
              if (volumeLaunchEl) volumeLaunchEl.value = String(v);
              var label = document.getElementById("xr-vol-label");
              if (label) label.setAttribute("value", Math.round(v * 100) + "%");
              window.__xrVolume = v;
            }
            window.__xrStepVolume = function (delta) {
              applyVolume(readVolume() + Number(delta || 0));
            };
            function syncModeButtons() {
              if (modeLoopBtn) modeLoopBtn.classList.toggle("active", mode === "loop");
              if (modeWorkingBtn) modeWorkingBtn.classList.toggle("active", mode === "working");
              if (modeArchiveBtn) modeArchiveBtn.classList.toggle("active", mode === "archive");
            }
            function normPath(name) {
              return String(name || "").replace(/\\/g, "/");
            }
            function isVideoExt(name) {
              return /\.(mp4|m4v|mov|webm|mkv)$/i.test(name);
            }
            function isLoopSegmentName(name) {
              var n = normPath(name);
              if (n.indexOf(LOOP_PREFIX) !== 0) return false;
              var base = n.slice(LOOP_PREFIX.length);
              if (!base || base.indexOf("/") >= 0) return false;
              if (/staging/i.test(base)) return false;
              return /^op_\d+\.(mp4|m4v|mov)$/i.test(base);
            }
            function isSparseWorkingName(name) {
              var n = normPath(name);
              if (n.indexOf(MEDIA_ROOT) !== 0) return false;
              var leaf = n.slice(MEDIA_ROOT.length);
              if (!leaf || leaf.indexOf("/") >= 0) return false;
              return /^_working/i.test(leaf) && isVideoExt(leaf);
            }
            // Working tab: any playable file in the media root (alongside `_working.mp4`), not loop/ or archive/.
            function isMediaRootPlayableName(name) {
              var n = normPath(name);
              if (n.indexOf(MEDIA_ROOT) !== 0) return false;
              var leaf = n.slice(MEDIA_ROOT.length);
              if (!leaf || leaf.indexOf("/") >= 0) return false;
              if (/staging/i.test(leaf) || /\.sparse\.json$/i.test(leaf)) return false;
              return isVideoExt(leaf);
            }
            function isArchiveMediaName(name) {
              var n = normPath(name);
              if (n.indexOf(ARCHIVE_PREFIX) !== 0) return false;
              var rest = n.slice(ARCHIVE_PREFIX.length);
              if (!rest || rest.indexOf("/") >= 0) return false;
              if (/staging/i.test(rest)) return false;
              return isVideoExt(rest);
            }
            function cacheBust(entry) {
              var q = [];
              if (entry.bytes) q.push("b=" + encodeURIComponent(String(entry.bytes)));
              if (entry.modified) q.push("m=" + encodeURIComponent(String(entry.modified)));
              return q.length ? ("?" + q.join("&")) : "";
            }
            function entryFromFile(f) {
              var name = f && f.name;
              return {
                name: name,
                bytes: Number(f.bytes) || 0,
                modified: f.modified || "",
                url: "/" + String(name).replace(/^\/+/, "") + cacheBust(f)
              };
            }
            function buildLoopPlaylist(files) {
              var list = Array.isArray(files) ? files : [];
              var out = [];
              var seen = {};
              list.forEach(function (f) {
                var name = f && f.name;
                if (!isLoopSegmentName(name) || seen[name]) return;
                seen[name] = true;
                out.push(entryFromFile(f));
              });
              out.sort(function (a, b) {
                return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
              });
              if (!out.length) {
                ["op_00.mp4", "op_01.mp4"].forEach(function (base) {
                  var name = LOOP_PREFIX + base;
                  out.push({ name: name, bytes: 0, modified: "", url: "/" + name });
                });
              }
              return out;
            }
            function buildWorkingPlaylist(files) {
              var list = Array.isArray(files) ? files : [];
              var out = [];
              var seen = {};
              list.forEach(function (f) {
                var name = f && f.name;
                if (!name || seen[name] || !isMediaRootPlayableName(name)) return;
                seen[name] = true;
                out.push(entryFromFile(f));
              });
              out.sort(function (a, b) {
                function rank(n) {
                  if (/_working\.mp4$/i.test(n)) return 0;
                  if (/_working/i.test(n)) return 1;
                  return 2;
                }
                var ar = rank(a.name);
                var br = rank(b.name);
                if (ar !== br) return ar - br;
                return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
              });
              return out;
            }
            function buildArchivePlaylist(files) {
              var list = Array.isArray(files) ? files : [];
              var out = [];
              var seen = {};
              list.forEach(function (f) {
                var name = f && f.name;
                if (!name || seen[name] || !isArchiveMediaName(name)) return;
                seen[name] = true;
                out.push(entryFromFile(f));
              });
              out.sort(function (a, b) {
                if (a.modified && b.modified && a.modified !== b.modified) {
                  return a.modified > b.modified ? -1 : 1;
                }
                return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
              });
              return out;
            }
            function loadIndex(i, autoplay) {
              var playlist = activePlaylist();
              if (!playlist.length) {
                setLabel(emptyLabel());
                renderFileList();
                return;
              }
              index = ((i % playlist.length) + playlist.length) % playlist.length;
              var item = playlist[index];
              wantPlay = !!autoplay;
              // New clip: soft reset in XR (keep last frame); hard reset only outside XR.
              try {
                if (xrIsPresenting()) xrPrepareNewClip();
                else xrResetPlaybackPipeline();
              } catch (eReset) {}
              try { xrLog("loadIndex", { i: index, name: item.name, presenting: !!xrIsPresenting(), sawAv1Tex: !!__xrDs.sawAv1Tex }); } catch (eLog) {}
              video.src = item.url;
              applyRate();
              setLabel("[" + modeTag() + "] " + (index + 1) + "/" + playlist.length + ": " + item.name);
              renderFileList();
              syncShaderToggles();
              applyWorkingSeekIfNeeded(item);
              var onReady = function () {
                applyWorkingSeekIfNeeded(item);
                refreshSphereShader();
              };
              var onLoaded = function () {
                video.removeEventListener("loadeddata", onLoaded);
                onReady();
              };
              video.addEventListener("loadeddata", onLoaded);
              if (video.readyState >= 2) onReady();
              if (wantPlay) {
                var p = video.play();
                if (p && typeof p.then === "function") {
                  p.then(function () {
                    applyWorkingSeekIfNeeded(item);
                    refreshSphereShader();
                  }).catch(function () {
                    wantPlay = false;
                    setLabel("Play blocked — tap Launch Engine");
                  });
                } else {
                  refreshSphereShader();
                }
              } else {
                refreshSphereShader();
              }
            }
            function setMode(next, keepPlay) {
              mode = normalizeMode(next);
              writeMode(mode);
              syncModeButtons();
              index = 0;
              if (activePlaylist().length) loadIndex(0, !!(keepPlay && wantPlay));
              else {
                try {
                  video.removeAttribute("src");
                  video.load();
                } catch (e) {}
                setLabel(emptyLabel());
                renderFileList();
              }
            }
            function applyFiles(files) {
              loopPlaylist = buildLoopPlaylist(files);
              workingPlaylist = buildWorkingPlaylist(files);
              archivePlaylist = buildArchivePlaylist(files);
              applyRate();
              if (activePlaylist().length) loadIndex(Math.min(index, activePlaylist().length - 1), false);
              else {
                setLabel(emptyLabel());
                renderFileList();
              }
            }
            function refreshPlaylists() {
              setLabel("Refreshing file list…");
              return fetch("status_lists.json", { cache: "no-store" })
                .then(function (r) { return r.json(); })
                .then(function (j) { applyFiles(j && j.files); })
                .catch(function () {
                  applyFiles([]);
                  setLabel("Could not refresh status_lists.json");
                });
            }
            function initializePlayer() {
              var playlist = activePlaylist();
              if (!playlist.length) {
                setLabel(emptyLabel());
                return;
              }
              wantPlay = true;
              if (!video.src) loadIndex(index, true);
              else {
                applyRate();
                var p = video.play();
                if (p && typeof p.then === "function") {
                  p.then(function () { refreshSphereShader(); }).catch(function () {});
                } else {
                  refreshSphereShader();
                }
              }
              showOverlay(false);
              // Give the mesh a moment after overlay hide / first paint.
              setTimeout(refreshSphereShader, 200);
              setTimeout(refreshSphereShader, 800);
            }
            if (launchBtn) launchBtn.onclick = initializePlayer;
            if (modeLoopBtn) modeLoopBtn.onclick = function () { setMode("loop", false); };
            if (modeWorkingBtn) modeWorkingBtn.onclick = function () { setMode("working", false); };
            if (modeArchiveBtn) modeArchiveBtn.onclick = function () { setMode("archive", false); };
            if (refreshBtn) refreshBtn.onclick = function () { refreshPlaylists(); };
            var zoomEl = document.getElementById("xr-zoom");
            if (zoomEl) {
              window.__xrZoom = Number(zoomEl.value) || 1;
              zoomEl.addEventListener("input", function () {
                window.__xrZoom = Number(zoomEl.value) || 1;
                var lab = document.getElementById("xr-zoom-label");
                if (lab) lab.setAttribute("value", Math.round(window.__xrZoom * 180) + "°");
                sphereEls().forEach(function (el) {
                  var comp = el.components && el.components["chroma-stereo-sbs"];
                  if (!comp) return;
                  comp._domeGeoReady = false;
                  try { comp.ensureDomeGeometry(); comp.syncEyeLayers(); } catch (eZ) {}
                });
              });
            }
            var distEl = document.getElementById("xr-dist");
            if (distEl) {
              window.__xrDist = Number(distEl.value) || 0;
              distEl.addEventListener("input", function () {
                window.__xrDist = Number(distEl.value) || 0;
                // followHead reads __xrDist every immersive frame; nudge once for immediate feedback.
                sphereEls().forEach(function (el) {
                  var comp = el.components && el.components["chroma-stereo-sbs"];
                  if (comp) try { comp.followHead(); } catch (eD) {}
                });
              });
            }
            if (chromaToggle) chromaToggle.onchange = function () { syncShaderToggles(); refreshSphereShader(); };
            if (chromaKeyEl) chromaKeyEl.oninput = function () { applyChromaKey(chromaKeyEl.value); };
            if (chromaKeyPlayEl) chromaKeyPlayEl.oninput = function () { applyChromaKey(chromaKeyPlayEl.value); };
            try {
              var savedKey = localStorage.getItem(KEY_KEY);
              if (savedKey && /^#[0-9a-fA-F]{6}$/.test(savedKey)) applyChromaKey(savedKey);
            } catch (eKey) {}
            if (sbsToggle) sbsToggle.onchange = function () { syncShaderToggles(); refreshSphereShader(); };
            if (reopenBtn) {
              reopenBtn.onclick = function () {
                showOverlay(true);
                setLabel("Stopped — pick a file, then Launch Engine");
                renderFileList();
              };
            }
            function togglePlayPause() {
              if (!video || !video.src) return;
              if (video.paused) {
                wantPlay = true;
                var p = video.play();
                if (p && typeof p.then === "function") {
                  p.then(function () { refreshSphereShader(); syncPlayPauseLabel(); }).catch(function () {});
                } else {
                  refreshSphereShader();
                  syncPlayPauseLabel();
                }
              } else {
                video.pause();
                wantPlay = false;
                syncPlayPauseLabel();
              }
            }
            function isXrChromeTarget(el) {
              if (!el || !el.closest) return false;
              return !!el.closest(
                "#xr-transport, #xr-reopen, #overlay, #xr-archive-float, #xr-archive-dd,"
                + " .a-enter-vr, .a-enter-ar, .a-dialog, .a-modal, button, input, select, a, label"
              );
            }
            if (playPauseBtn) playPauseBtn.onclick = function () { togglePlayPause(); };
            // Click / tap the scene (not chrome) toggles play/pause during playback.
            document.addEventListener("click", function (e) {
              if (overlay && overlay.style.display !== "none") return;
              if (isXrChromeTarget(e.target)) return;
              togglePlayPause();
            });
            // Quest controller trigger (WebXR select) toggles play/pause in AR/VR.
            (function wireXrTriggerPlayPause() {
              var lastMs = 0;
              var boundSession = null;
              function onSelect(ev) {
                try {
                  if (ev && ev.inputSource && ev.inputSource.targetRayMode === "gaze") return;
                } catch (eGaze) {}
                if (overlay && overlay.style.display !== "none") return;
                var now = Date.now();
                if (now - lastMs < 280) return;
                lastMs = now;
                togglePlayPause();
              }
              function unbind() {
                if (!boundSession) return;
                try { boundSession.removeEventListener("select", onSelect); } catch (eOff) {}
                boundSession = null;
              }
              function bind() {
                unbind();
                var session = null;
                try {
                  var scene = document.querySelector("a-scene");
                  session = scene && scene.renderer && scene.renderer.xr && scene.renderer.xr.getSession
                    ? scene.renderer.xr.getSession()
                    : null;
                } catch (eSess) {}
                if (!session) return;
                boundSession = session;
                try { session.addEventListener("select", onSelect); } catch (eOn) {}
              }
              var sceneEl = document.querySelector("a-scene");
              if (sceneEl) {
                sceneEl.addEventListener("enter-vr", function () { setTimeout(bind, 0); setTimeout(bind, 200); });
                sceneEl.addEventListener("exit-vr", unbind);
              }
            })();
            if (seekBackBtn) seekBackBtn.onclick = function () { seekBy(-10); };
            if (seekFwdBtn) seekFwdBtn.onclick = function () { seekBy(10); };
            if (seekEl) {
              function beginSeekDrag() { seekDragging = true; }
              // Always seek on input — do not require pointerdown (Quest/PC often skip it on range).
              seekEl.addEventListener("pointerdown", beginSeekDrag);
              seekEl.addEventListener("mousedown", beginSeekDrag);
              seekEl.addEventListener("touchstart", beginSeekDrag, { passive: true });
              seekEl.addEventListener("input", function () {
                seekDragging = true;
                applySeekTime(parseFloat(seekEl.value));
              });
              seekEl.addEventListener("change", function () {
                applySeekTime(parseFloat(seekEl.value));
                seekDragging = false;
              });
              window.addEventListener("pointerup", endSeekDrag);
              window.addEventListener("pointercancel", endSeekDrag);
              window.addEventListener("mouseup", endSeekDrag);
              window.addEventListener("touchend", endSeekDrag);
              window.addEventListener("blur", endSeekDrag);
            }
            if (prevBtn) prevBtn.onclick = function () {
              if (!activePlaylist().length) return;
              loadIndex(index - 1, wantPlay && !video.paused);
            };
            if (nextBtn) nextBtn.onclick = function () {
              if (!activePlaylist().length) return;
              loadIndex(index + 1, wantPlay && !video.paused);
            };
            if (rateSel) {
              rateSel.value = String(readRate());
              rateSel.onchange = function () {
                var v = parseFloat(rateSel.value);
                if (!isFinite(v)) v = 1;
                writeRate(v);
                applyRate();
              };
            }
            function onVolumeInput(e) {
              applyVolume(e && e.target ? e.target.value : readVolume());
            }
            if (volumeEl) {
              volumeEl.value = String(readVolume());
              volumeEl.addEventListener("input", onVolumeInput);
            }
            if (volumeLaunchEl) {
              volumeLaunchEl.value = String(readVolume());
              volumeLaunchEl.addEventListener("input", onVolumeInput);
            }
            applyVolume(readVolume());
            video.addEventListener("loadedmetadata", function () { applyVolume(readVolume()); });
            video.addEventListener("timeupdate", syncTransportUI);
            video.addEventListener("durationchange", syncTransportUI);
            video.addEventListener("loadedmetadata", syncTransportUI);
            video.addEventListener("seeked", function () {
              try {
                if (typeof __xrVideoTex !== "undefined" && __xrVideoTex && __xrDs.av1Known && __xrDs.av1 === true) __xrVideoTex.needsUpdate = true;
              } catch (e) {}
              try { refreshSphereShader(); } catch (e2) {}
              syncTransportUI();
            });
            video.addEventListener("progress", syncTransportUI);
            video.addEventListener("play", syncPlayPauseLabel);
            video.addEventListener("pause", syncPlayPauseLabel);
            video.addEventListener("ended", function () {
              if (!activePlaylist().length) return;
              loadIndex(index + 1, true);
            });
            video.addEventListener("error", function () {
              var playlist = activePlaylist();
              var item = playlist[index];
              setLabel("Could not load " + (item && item.name ? item.name : "media")
                + (playlist.length > 1 ? " — pick another from the list" : " (export on phone first)"));
              wantPlay = false;
              showOverlay(true);
              renderFileList();
            });
            mode = readMode();
            syncModeButtons();
            showOverlay(true);
            try {
              var params = new URLSearchParams(window.location.search || "");
              var qMode = params.get("mode");
              var hashMode = String(window.location.hash || "").replace(/^#/, "");
              if (qMode) mode = normalizeMode(qMode);
              else if (hashMode) mode = normalizeMode(hashMode);
              writeMode(mode);
              syncModeButtons();
            } catch (e) {}
            (function probeWebXR() {
              var el = document.getElementById("xr-webxr-status");
              if (!el) return;
              var secure = !!(window.isSecureContext);
              var origin = String(location.origin || "");
              function setStatus(msg) { el.textContent = msg; }
              if (!navigator.xr) {
                setStatus("WebXR API missing — origin " + origin
                  + (secure ? " (secure context OK)" : " (NOT a secure context — need https:// tunnel or Quest flags)"));
                return;
              }
              var done = false;
              function finish(vr, ar) {
                if (done) return;
                done = true;
                setStatus("WebXR @ " + origin
                  + " — immersive-vr: " + (vr ? "yes" : "no")
                  + ", immersive-ar (passthrough): " + (ar ? "yes — use Enter AR" : "no")
                  + (secure ? "" : " — insecure context"));
              }
              var timeout = setTimeout(function () {
                if (done) return;
                done = true;
                setStatus("WebXR probe timed out @ " + origin
                  + (secure ? "" : " — insecure context; PC preview still works after Launch"));
              }, 2500);
              Promise.all([
                navigator.xr.isSessionSupported("immersive-vr").catch(function () { return false; }),
                navigator.xr.isSessionSupported("immersive-ar").catch(function () { return false; })
              ]).then(function (bits) {
                clearTimeout(timeout);
                finish(!!bits[0], !!bits[1]);
              }).catch(function () {
                clearTimeout(timeout);
                finish(false, false);
              });
            })();
            refreshWorkingSeek().finally(function () {
              refreshPlaylists();
            });
          })();
          </script>
        </body>
        </html>
        """#
    }

    private static func sendMinimalIndexHTML(_ connection: NWConnection, done: @escaping () -> Void) {
        autoreleasepool {
            let exportActive = ExportPlaybackState.shared.isLANExportActive
            let playbackStatusInitial = exportActive
                ? htmlPlaybackStatusLiveShell()
                : htmlPlaybackStatusShell()
            let html = """
                <!DOCTYPE html>
                \(htmlLANAppearanceHeadBits())
                <title>Loop Segments — LAN monitor</title>
                </head><body>
                <div class="lan-topbar">
                  <h1>Loop Segments — LAN monitor</h1>
                  \(htmlLANNightModeToggleButton())
                </div>
                <p><a href="/browse">Open pCloud browser &amp; export controls</a> · \(htmlMonitorQuickLogLinks())</p>
                <div id="lan-export-pending" class="export-pending-banner" style="display:none" role="status">
                  <strong id="lan-export-pending-title">Processing export request</strong>
                  <span id="lan-export-pending-detail">Keep Loop Segments open in the foreground on the phone.</span>
                </div>
                \(htmlExportSourceLineShell())
                \(htmlPendingQueueSection())
                \(htmlPausedExportsSection())
                <div id="lan-playback-status">\(playbackStatusInitial)</div>
                <p class="muted">No auto-refresh (tap buttons). Use direct log link while export runs.</p>
                <p>
                  <button type="button" id="lan-refresh-status">Refresh status</button>
                  <button type="button" id="lan-refresh-lists">Refresh file list</button>
                  <button type="button" id="lan-wifi-www-probe">Probe Phone Wi‑Fi → www</button>
                  <button type="button" id="lan-speed-test">LAN speed test</button>
                </p>
                <p id="lan-wifi-www-probe-result" class="muted" role="status"></p>
                <p id="lan-speed-test-result" class="muted" role="status"></p>
                \(htmlLANSpeedTestScript(resultElementId: "lan-speed-test-result", buttonId: "lan-speed-test"))
                \(htmlLANLoopPlayerBlock())
                <h2>On phone (playback)</h2>
                <ul id="lan-playback-files">
                \(htmlMonitorStaticPlaybackLinks())
                </ul>
                <h3>Export logs (newest first)</h3>
                <div class="lan-playback-logs-scroll"><ul id="lan-export-logs">
                \(exportActive ? htmlLANMinimalExportLogLinks() : exportLogsFileListHTML())
                </ul></div>
                \(htmlLANCloudflareTunnelBlock())
                \(htmlMonitorManualRefreshScript())
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
    }

    /// Full LAN page with pCloud folder browser — use `/browse` during large exports.
    private static func sendBrowseIndexHTML(_ connection: NWConnection, done: @escaping () -> Void) {
        let exportActive = ExportPlaybackState.shared.isLANExportActive
        if !exportActive {
        refreshLANMetricsBeforeStatusResponse()
        }
        let playbackStatusBlock = exportActive ? htmlPlaybackStatusLiveShell() : playbackStatusHTMLBlock()
        let mediaList: String
        let logList: String
        if exportActive {
            mediaList = "<li><em>File list deferred during export — tap Refresh file list or use WebDAV.</em></li>"
            logList = htmlLANMinimalExportLogLinks()
        } else {
            mediaList = playbackMediaFileListHTML()
            logList = exportLogsFileListHTML()
        }
        let html = """
            <!DOCTYPE html>
            \(htmlLANAppearanceHeadBits())
            <title>Loop Segments — LAN export</title>
            </head><body>
            <div class="lan-topbar">
              <h1>Loop Segments — LAN export</h1>
              \(htmlLANNightModeToggleButton())
            </div>
            <div id="lan-export-pending" class="export-pending-banner" style="display:none" role="status" aria-live="polite">
              <strong id="lan-export-pending-title">Processing export request</strong>
              <span id="lan-export-pending-detail">Please wait — keep Loop Segments open in the foreground on the phone.</span>
            </div>
            \(htmlExportSourceLineBlock())
            \(htmlPendingQueueSection())
            \(htmlPausedExportsSection())
            <p>Serving on port \(defaultPort): logs and media under <code>pcld_ios_media/</code> (private on phone, not in Files app). Legacy URLs <code>/export_latest.txt</code>, <code>/logs/export_*.txt</code>, and <code>/loop_segments_ok.txt</code> still work.</p>
            <p>JSON: \(htmlMonitorQuickLogLinks())</p>
            <p>PC: <code>Mount-LoopSegmentsRclone.ps1</code> (maps <code>pcld_ios_media/</code> and logs).</p>
            <p><strong>Playback:</strong> <code>pcld_ios_media/loop/op_00.mp4</code> / <code>pcld_ios_media/loop/op_01.mp4</code> (DLNA can loop the <code>loop/</code> folder). In-progress: <code>_working.mp4</code> (sparse original) or <code>_working_pcloud_transcode.mp4</code> (pCloud HLS transcode — labeled on index when active).</p>
            <div id="lan-playback-status">\(playbackStatusBlock)</div>
            \(exportActive ? """
            <p class="muted">Auto-refresh off during export (tap Refresh or use <a href="/">monitor</a>).</p>
            <p>
              <button type="button" id="lan-refresh-status">Refresh status</button>
              <button type="button" id="lan-refresh-lists">Refresh file list</button>
              <button type="button" id="lan-wifi-www-probe">Probe Phone Wi‑Fi → www</button>
            </p>
            <p id="lan-wifi-www-probe-result" class="muted" role="status"></p>
            """ : "")
            \(htmlLANLoopPlayerBlock())
            <h2>On phone (playback)</h2>
            <div class="lan-playback-section">
            <div id="lan-playback-media" class="lan-playback-media">
            <ul id="lan-playback-files">
            \(mediaList)
            </ul>
            </div>
            <div id="lan-playback-logs" class="lan-playback-logs-block">
            <h3 class="lan-playback-subhead">Export logs (newest first)</h3>
            <div class="lan-playback-logs-scroll" aria-label="Export log files">
            <ul id="lan-export-logs">
            \(logList)
            </ul>
            </div>
            </div>
            </div>
            \(htmlLANSpeedTestScript())
            \(htmlExportControlPanel())
            \(htmlURLDownloadPanel())
            \(htmlLANCloudflareTunnelBlock())
            \(exportActive
                ? htmlMonitorManualRefreshScript()
                : htmlLANLiveRefreshScript(monitorOnly: false, deferAutoPoll: false))
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
        done: @escaping () -> Void,
        status: Int = 200
    ) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            sendResponse(connection: connection, status: 500, contentType: "text/plain", body: Data("JSON error".utf8), done: done)
            return
        }
        sendResponse(connection: connection, status: status, contentType: "application/json", body: data, done: done)
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

    private static var xrTunnelSidecarURL: URL {
        _ = ExportPaths.lanExportScriptsDirectory
        return ExportPaths.lanExportScriptsDirectory.appendingPathComponent("xr_tunnel.json")
    }

    // MARK: - XR debug ring (Quest /xr posts; PC pulls GET)

    private static let xrDebugLock = NSLock()
    private static var xrDebugLines: [String] = []
    private static var xrDebugSnapshot: [String: Any] = [:]
    private static let xrDebugCap = 500

    private static var xrDebugLogURL: URL {
        _ = ExportPaths.lanExportScriptsDirectory
        return ExportPaths.lanExportScriptsDirectory.appendingPathComponent("xr_debug.log")
    }

    private static func appendXRDebugLines(_ lines: [String], snapshot: [String: Any]?) {
        guard !lines.isEmpty || snapshot != nil else { return }
        xrDebugLock.lock()
        defer { xrDebugLock.unlock() }
        if let snapshot {
            xrDebugSnapshot = snapshot
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            xrDebugLines.append(line)
        }
        if xrDebugLines.count > xrDebugCap {
            xrDebugLines.removeFirst(xrDebugLines.count - xrDebugCap)
        }
        let joined = xrDebugLines.joined(separator: "\n") + (xrDebugLines.isEmpty ? "" : "\n")
        try? joined.data(using: .utf8)?.write(to: xrDebugLogURL, options: .atomic)
    }

    private static func xrDebugPayload() -> [String: Any] {
        xrDebugLock.lock()
        defer { xrDebugLock.unlock() }
        return [
            "schema": "loopsegments-xr-debug/v1",
            "count": xrDebugLines.count,
            "cap": xrDebugCap,
            "lines": xrDebugLines,
            "snapshot": xrDebugSnapshot,
            "file": "\(ExportPaths.mediaExportFolderName)/scripts/xr_debug.log",
        ]
    }

    private static func sendXRDebugGET(connection: NWConnection, done: @escaping () -> Void) {
        sendJSONPayload(xrDebugPayload(), connection: connection, done: done, status: 200)
    }

    private static func handleXRDebugWrite(
        requestHeaders: String,
        bodyPrefix: Data,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        receiveRequestBody(
            on: connection,
            requestHeaders: requestHeaders,
            bodyPrefix: bodyPrefix,
            maxBytes: 64_000
        ) { result in
            switch result {
            case .failure(.missingContentLength):
                sendResponse(connection: connection, status: 411, contentType: "text/plain", body: Data("Content-Length required".utf8), done: done)
            case .failure(.payloadTooLarge):
                sendResponse(connection: connection, status: 413, contentType: "text/plain", body: Data("Body too large".utf8), done: done)
            case .failure(.readFailed):
                connection.cancel()
                done()
            case .success(let body):
                guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    sendResponse(
                        connection: connection,
                        status: 400,
                        contentType: "text/plain",
                        body: Data("JSON object required — { \"lines\": [\"…\"], \"snapshot\": {…} }".utf8),
                        done: done
                    )
                    return
                }
                if object["action"] as? String == "clear" {
                    xrDebugLock.lock()
                    xrDebugLines.removeAll()
                    xrDebugSnapshot.removeAll()
                    xrDebugLock.unlock()
                    try? Data().write(to: xrDebugLogURL, options: .atomic)
                    sendJSONPayload(xrDebugPayload(), connection: connection, done: done, status: 200)
                    return
                }
                var lines: [String] = []
                if let arr = object["lines"] as? [String] {
                    lines = arr
                } else if let one = object["line"] as? String {
                    lines = [one]
                } else if let msg = object["message"] as? String {
                    lines = [msg]
                }
                let snap = object["snapshot"] as? [String: Any]
                appendXRDebugLines(lines, snapshot: snap)
                sendJSONPayload(["ok": true, "count": xrDebugPayload()["count"] as Any], connection: connection, done: done, status: 200)
            }
        }
    }

    private static func normalizeXRTunnelHost(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        s = s.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        if !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") {
            s = "https://\(s)"
        }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else { return nil }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }

    private static func xrTunnelPayload(host: String) -> [String: Any] {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload: [String: Any] = [
            "schema": "loopsegments-xr-tunnel/v1",
            "host": trimmed,
            "updatedAtUtc": ISO8601DateFormatter().string(from: Date()),
            "file": "\(ExportPaths.mediaExportFolderName)/scripts/xr_tunnel.json",
        ]
        if trimmed.isEmpty {
            payload["httpsBase"] = NSNull()
            payload["xrUrl"] = NSNull()
        } else {
            payload["httpsBase"] = "https://\(trimmed)"
            payload["xrUrl"] = "https://\(trimmed)/xr"
        }
        return payload
    }

    private static func readXRTunnelHostFromDisk() -> String {
        let url = xrTunnelSidecarURL
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        if let host = obj["host"] as? String {
            return normalizeXRTunnelHost(host) ?? ""
        }
        return ""
    }

    private static func writeXRTunnelHostToDisk(_ host: String) throws -> [String: Any] {
        let payload = xrTunnelPayload(host: host)
        _ = ExportPaths.lanExportScriptsDirectory
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: xrTunnelSidecarURL, options: .atomic)
        return payload
    }

    private static func sendXRTunnelGET(connection: NWConnection, done: @escaping () -> Void) {
        let host = readXRTunnelHostFromDisk()
        sendJSONPayload(xrTunnelPayload(host: host), connection: connection, done: done, status: 200)
    }

    private static func handleXRTunnelWrite(
        requestHeaders: String,
        bodyPrefix: Data,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        receiveRequestBody(
            on: connection,
            requestHeaders: requestHeaders,
            bodyPrefix: bodyPrefix,
            maxBytes: 4_096
        ) { result in
            switch result {
            case .failure(.missingContentLength):
                sendResponse(connection: connection, status: 411, contentType: "text/plain", body: Data("Content-Length required".utf8), done: done)
            case .failure(.payloadTooLarge):
                sendResponse(connection: connection, status: 413, contentType: "text/plain", body: Data("Body too large".utf8), done: done)
            case .failure(.readFailed):
                connection.cancel()
                done()
            case .success(let body):
                guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    sendResponse(
                        connection: connection,
                        status: 400,
                        contentType: "text/plain",
                        body: Data("JSON object required — { \"host\": \"xxxx.trycloudflare.com\" }".utf8),
                        done: done
                    )
                    return
                }
                let rawHost: String
                if let s = object["host"] as? String {
                    rawHost = s
                } else if object["host"] is NSNull || object["host"] == nil {
                    rawHost = ""
                } else {
                    sendResponse(
                        connection: connection,
                        status: 400,
                        contentType: "text/plain",
                        body: Data("host must be a string".utf8),
                        done: done
                    )
                    return
                }
                guard let host = normalizeXRTunnelHost(rawHost) else {
                    sendResponse(
                        connection: connection,
                        status: 400,
                        contentType: "text/plain; charset=utf-8",
                        body: Data("Could not parse host — use xxxx.trycloudflare.com or https://…".utf8),
                        done: done
                    )
                    return
                }
                do {
                    let payload = try writeXRTunnelHostToDisk(host)
                    sendJSONPayload(payload, connection: connection, done: done, status: 200)
                } catch {
                    sendResponse(
                        connection: connection,
                        status: 500,
                        contentType: "text/plain; charset=utf-8",
                        body: Data("Could not write xr_tunnel.json: \(error.localizedDescription)".utf8),
                        done: done
                    )
                }
            }
        }
    }

    private static func sendLANThroughputGET(connection: NWConnection, done: @escaping () -> Void) {
        if let payload = LANThroughputSidecar.readPrimary() {
            sendJSONPayload(payload, connection: connection, done: done, status: 200)
            return
        }
        sendJSONPayload(
            [
                "endpoint": "/lan_throughput.json",
                "methods": ["GET", "POST"],
                "auth": "Basic \(lanWebDAVUsername):\(lanWebDAVPassword) (POST)",
                "schema": LANThroughputSidecar.schema,
                "notes": [
                    "GET returns last recommendation sidecar (same JSON as Measure-LoopSegmentsLanThroughput.ps1).",
                    "POST body: measuredMbps (or transferredBytes + elapsedSeconds), optional sourceUrl/sourcePath.",
                    "Writes pcld_ios_media/scripts/lan_throughput.json and lan_recommended_segment_bitrate.json (+ archive/).",
                    "HTTP-only (browser Range download). No rclone mount leg / no other-router reboot.",
                ],
                "sidecarPresent": false,
            ] as [String: Any],
            connection: connection,
            done: done,
            status: 404
        )
    }

    private static func handleLANThroughputPOST(
        requestHeaders: String,
        bodyPrefix: Data,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        receiveRequestBody(
            on: connection,
            requestHeaders: requestHeaders,
            bodyPrefix: bodyPrefix,
            maxBytes: 32_000
        ) { result in
            switch result {
            case .failure(.missingContentLength):
                sendResponse(connection: connection, status: 411, contentType: "text/plain", body: Data("Content-Length required".utf8), done: done)
            case .failure(.payloadTooLarge):
                sendResponse(connection: connection, status: 413, contentType: "text/plain", body: Data("Body too large".utf8), done: done)
            case .failure(.readFailed):
                connection.cancel()
                done()
            case .success(let body):
                guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    sendResponse(
                        connection: connection,
                        status: 400,
                        contentType: "text/plain",
                        body: Data("JSON object required".utf8),
                        done: done
                    )
                    return
                }
                let parsed = parseLANThroughputPOSTBody(object)
                switch parsed {
                case .failure(let err):
                    sendResponse(
                        connection: connection,
                        status: 400,
                        contentType: "text/plain; charset=utf-8",
                        body: Data(err.message.utf8),
                        done: done
                    )
                case .success(let measurement):
                    do {
                        let payload = try LANThroughputSidecar.write(measurement)
                        sendJSONPayload(payload, connection: connection, done: done, status: 200)
                    } catch {
                        sendResponse(
                            connection: connection,
                            status: 500,
                            contentType: "text/plain; charset=utf-8",
                            body: Data("Could not write sidecars: \(error.localizedDescription)".utf8),
                            done: done
                        )
                    }
                }
            }
        }
    }

    private struct LANThroughputPOSTParseError: Error {
        let message: String
    }

    private static func parseLANThroughputPOSTBody(
        _ object: [String: Any]
    ) -> Result<LANThroughputSidecar.Measurement, LANThroughputPOSTParseError> {
        let transferred = int64Value(object["transferredBytes"]) ?? int64Value(object["bytes"])
        let elapsed = doubleValue(object["elapsedSeconds"]) ?? doubleValue(object["elapsedSec"])
        var measured = doubleValue(object["measuredMbps"]) ?? doubleValue(object["mbps"])
        if measured == nil, let transferred, let elapsed, elapsed > 0, transferred > 0 {
            measured = (Double(transferred) * 8.0) / (elapsed * 1_000_000.0)
        }
        guard let measuredMbps = measured, measuredMbps > 0, measuredMbps.isFinite else {
            return .failure(LANThroughputPOSTParseError(
                message: "measuredMbps (or transferredBytes + elapsedSeconds) required"
            ))
        }
        let host = primaryLANIPv4Address()
        let baseURL: String? = {
            guard let host else { return nil }
            return "http://\(host):\(Int(defaultPort))/"
        }()
        let sourceUrl = stringValue(object["sourceUrl"])
        let sourcePath = stringValue(object["sourcePath"])
            ?? stringValue(object["sourceRelativePath"])
        let minLan = doubleValue(object["minLanThroughputMbps"])
            ?? LANThroughputSidecar.defaultMinLanThroughputMbps
        let note = stringValue(object["note"])
            ?? "LAN page HTTP Range download (browser). Same sidecars as Measure-LoopSegmentsLanThroughput.ps1 HTTP leg; no mount copy / no other-router reboot."
        return .success(
            LANThroughputSidecar.Measurement(
                measuredMbps: measuredMbps,
                transferredBytes: transferred ?? 0,
                elapsedSeconds: elapsed ?? 0,
                sourceUrl: sourceUrl,
                sourcePath: sourcePath,
                phoneLanHost: host,
                phoneLanBaseUrl: baseURL,
                minLanThroughputMbps: minLan,
                note: note
            )
        )
    }

    private static func stringValue(_ any: Any?) -> String? {
        guard let any else { return nil }
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        guard let any else { return nil }
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String, let d = Double(s) { return d }
        return nil
    }

    private static func int64Value(_ any: Any?) -> Int64? {
        guard let any else { return nil }
        if let i = any as? Int64 { return i }
        if let i = any as? Int { return Int64(i) }
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String, let i = Int64(s) { return i }
        if let d = any as? Double { return Int64(d) }
        return nil
    }

    private static func sendExportFromURLUsageJSON(connection: NWConnection, done: @escaping () -> Void) {
        sendJSONPayload(
            [
                "endpoint": "/export_from_url.json",
                "methods": ["PUT", "POST"],
                "auth": "Basic admin:iosadmin",
                "body": [
                    "url": "https://example.com/video.mp4",
                    "saveName": "video.mp4",
                    "id": "<optional uuid>",
                ],
                "notes": [
                    "Same pipeline as browse Export from URL (vanilla → segments → archive).",
                    "Returns 202 queued; phone polls export_trigger.json ~2s while app is foreground/exporting/Keep Alive.",
                    "Poll GET /\(LANExportTriggerControl.ackRelativePath) for accepted/rejected.",
                    "Prefer /export_from_folder.json for pCloud files (avoids CDN IP binding).",
                ],
            ] as [String: Any],
            connection: connection,
            done: done
        )
    }

    private static func sendExportFromFolderUsageJSON(connection: NWConnection, done: @escaping () -> Void) {
        sendJSONPayload(
            [
                "endpoint": "/export_from_folder.json",
                "methods": ["PUT", "POST"],
                "auth": "Basic admin:iosadmin",
                "body": [
                    "folderPath": "/Videos/MyFolder/",
                    "displayName": "clip.mp4",
                    "seekMs": 0,
                    "id": "<optional uuid>",
                ],
                "notes": [
                    "Queues start_export with displayName/saveName; folderPath optional.",
                    "With folderPath: one-level PROPFIND, then WebDAV walk on failure.",
                    "Without folderPath: WebDAV filename walk only (bookmarks + recent folders) — use when PC cannot resolve path.",
                    "Builds on-phone WebDAV href (avoids PC/CDN IP-bound URLs).",
                    "Returns 202 queued; poll GET /\(LANExportTriggerControl.ackRelativePath) for accepted/rejected.",
                ],
            ] as [String: Any],
            connection: connection,
            done: done
        )
    }

    private static func handleExportFromURLWrite(
        requestHeaders: String,
        bodyPrefix: Data,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        receiveRequestBody(
            on: connection,
            requestHeaders: requestHeaders,
            bodyPrefix: bodyPrefix,
            maxBytes: 64_000
        ) { result in
            switch result {
            case .failure(.missingContentLength):
                sendResponse(connection: connection, status: 411, contentType: "text/plain", body: Data("Content-Length required".utf8), done: done)
            case .failure(.payloadTooLarge):
                sendResponse(connection: connection, status: 413, contentType: "text/plain", body: Data("Body too large".utf8), done: done)
            case .failure(.readFailed):
                connection.cancel()
                done()
            case .success(let body):
                guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    sendResponse(
                        connection: connection,
                        status: 400,
                        contentType: "text/plain; charset=utf-8",
                        body: Data("Expected JSON { \"url\", \"saveName\"? , \"id\"? }".utf8),
                        done: done
                    )
                    return
                }
                let urlString = (object["url"] as? String)
                    ?? (object["downloadURL"] as? String)
                    ?? (object["href"] as? String)
                    ?? ""
                let saveName = (object["saveName"] as? String)
                    ?? (object["name"] as? String)
                    ?? (object["displayName"] as? String)
                let triggerId = object["id"] as? String
                let queued = LANExportTriggerControl.queueDownloadURLExport(
                    urlString: urlString,
                    saveName: saveName,
                    triggerId: triggerId
                )
                sendJSONPayload(
                    queued.payload,
                    connection: connection,
                    done: done,
                    status: queued.httpStatus
                )
            }
        }
    }

    private static func handleExportFromFolderWrite(
        requestHeaders: String,
        bodyPrefix: Data,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        receiveRequestBody(
            on: connection,
            requestHeaders: requestHeaders,
            bodyPrefix: bodyPrefix,
            maxBytes: 64_000
        ) { result in
            switch result {
            case .failure(.missingContentLength):
                sendResponse(connection: connection, status: 411, contentType: "text/plain", body: Data("Content-Length required".utf8), done: done)
            case .failure(.payloadTooLarge):
                sendResponse(connection: connection, status: 413, contentType: "text/plain", body: Data("Body too large".utf8), done: done)
            case .failure(.readFailed):
                connection.cancel()
                done()
            case .success(let body):
                guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    sendResponse(
                        connection: connection,
                        status: 400,
                        contentType: "text/plain; charset=utf-8",
                        body: Data("Expected JSON { \"displayName\"|\"saveName\", \"folderPath\"?, \"seekMs\"?, \"id\"? }".utf8),
                        done: done
                    )
                    return
                }
                let folderPath = (object["folderPath"] as? String)
                    ?? (object["path"] as? String)
                    ?? (object["listingPath"] as? String)
                    ?? ""
                let displayName = (object["displayName"] as? String)
                    ?? (object["saveName"] as? String)
                    ?? (object["name"] as? String)
                    ?? ""
                let seekMs: Int64? = {
                    if let n = object["seekMs"] as? Int64 { return n }
                    if let n = object["seekMs"] as? Int { return Int64(n) }
                    if let n = object["seekMs"] as? Double { return Int64(n) }
                    return nil
                }()
                let triggerId = object["id"] as? String
                let queued = LANExportTriggerControl.queueStartExportFromFolder(
                    folderPath: folderPath,
                    displayName: displayName,
                    seekMs: seekMs,
                    triggerId: triggerId
                )
                sendJSONPayload(
                    queued.payload,
                    connection: connection,
                    done: done,
                    status: queued.httpStatus
                )
            }
        }
    }

    /// Disk snapshot for `status.json` / LAN UI (LAN callbacks are not on the main actor).
    private static func pendingExportQueueStatusPayload() -> [String: Any] {
        guard let url = ExportPaths.urlForLANWritableMedia(relativePath: PendingExportQueue.relativePath),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([PendingExportItem].self, from: data) else {
            return ["count": 0, "items": []]
        }
        return [
            "count": items.count,
            "items": items.prefix(50).map { item -> [String: Any] in
                var row: [String: Any] = [
                    "id": item.id,
                    "displayName": item.displayName,
                ]
                if let folder = item.folderPath { row["folderPath"] = folder }
                if let seek = item.seekMs { row["seekMs"] = seek }
                return row
            },
        ]
    }

    private static func sendExportQueueUsageJSON(connection: NWConnection, done: @escaping () -> Void) {
        let queue = pendingExportQueueStatusPayload()
        let payload: [String: Any] = [
            "endpoint": "/export_queue.json",
            "methods": ["GET", "PUT", "POST"],
            "queue": queue,
            "body": [
                "mode": "append|prepend|replace (default prepend)",
                "startFirst": "bool (default true) — pop first item into export_trigger (soft-pauses if busy)",
                "action": "remove|clear — manage queue without enqueuing (remove needs id)",
                "id": "uuid — required with action=remove",
                "items": [
                    [
                        "folderPath": "optional pCloud folder listing path",
                        "displayName": "required filename",
                        "seekMs": 0,
                        "id": "optional uuid",
                    ],
                ],
            ],
            "notes": [
                "Pending FIFO on phone (not Paused). Survives companion close.",
                "On finish/stop, next pending item auto-starts. User Pause holds the queue.",
                "Companion multi-select archive → cancel zip → POST items with mode=prepend.",
                "LAN page lists queue with Remove / Clear (POST action).",
            ],
        ]
        sendJSONPayload(payload, connection: connection, done: done, status: 200)
    }

    private static func sendPausedExportsUsageJSON(connection: NWConnection, done: @escaping () -> Void) {
        let paused = pausedExportsStatusPayload()
        let payload: [String: Any] = [
            "endpoint": "/paused_exports.json",
            "methods": ["GET", "POST"],
            "pausedExports": paused,
            "body": [
                "action": "clear | queue_all — clear removes checkpoints + parked media; queue_all moves all paused → Queued as fresh jobs (drops checkpoints / parked; live export kept)",
            ],
            "notes": [
                "Same paused list as phone Paused tab (excluding the live export).",
                "Clear also removes parked/ media for those checkpoints.",
                "queue_all appends onto pending FIFO (no seekMs); drops parks/checkpoints; releases Pause hold so drain can start when idle.",
            ],
        ]
        sendJSONPayload(payload, connection: connection, done: done, status: 200)
    }

    private static func handlePausedExportsWrite(
        requestHeaders: String,
        bodyPrefix: Data,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        receiveRequestBody(
            on: connection,
            requestHeaders: requestHeaders,
            bodyPrefix: bodyPrefix,
            maxBytes: 4_096
        ) { result in
            switch result {
            case .failure(.missingContentLength):
                sendResponse(connection: connection, status: 411, contentType: "text/plain", body: Data("Content-Length required".utf8), done: done)
            case .failure(.payloadTooLarge):
                sendResponse(connection: connection, status: 413, contentType: "text/plain", body: Data("Body too large".utf8), done: done)
            case .failure(.readFailed):
                connection.cancel()
                done()
            case .success(let body):
                guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let action = (object["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      action == "clear" || action == "queue_all" else {
                    sendResponse(
                        connection: connection,
                        status: 400,
                        contentType: "text/plain; charset=utf-8",
                        body: Data("Expected JSON { \"action\": \"clear\" | \"queue_all\" }".utf8),
                        done: done
                    )
                    return
                }
                Task { @MainActor in
                    let exceptKey = ExportPlaybackState.shared.isLANExportActive
                        ? ExportRetentionSourceCatalog.read()?.fileKey
                        : nil
                    if action == "queue_all" {
                        let moved = ResumeStore.shared.moveAllPausedExportsToPendingQueue(exceptFileKey: exceptKey)
                        let payload: [String: Any] = [
                            "status": "ok",
                            "action": "queue_all",
                            "moved": moved,
                            "message": moved == 0
                                ? "No paused exports to move"
                                : "Moved \(moved) paused export(s) to Queued",
                            "pausedExports": pausedExportsStatusPayload(),
                            "pendingExportQueue": pendingExportQueueStatusPayload(),
                        ]
                        sendJSONPayload(payload, connection: connection, done: done, status: 200)
                    } else {
                        ResumeStore.shared.clearPausedExports(exceptFileKey: exceptKey)
                        let payload: [String: Any] = [
                            "status": "ok",
                            "action": "clear",
                            "pausedExports": pausedExportsStatusPayload(),
                        ]
                        sendJSONPayload(payload, connection: connection, done: done, status: 200)
                    }
                }
            }
        }
    }

    private static func handleExportQueueWrite(
        requestHeaders: String,
        bodyPrefix: Data,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        receiveRequestBody(
            on: connection,
            requestHeaders: requestHeaders,
            bodyPrefix: bodyPrefix,
            maxBytes: 256_000
        ) { result in
            switch result {
            case .failure(.missingContentLength):
                sendResponse(connection: connection, status: 411, contentType: "text/plain", body: Data("Content-Length required".utf8), done: done)
            case .failure(.payloadTooLarge):
                sendResponse(connection: connection, status: 413, contentType: "text/plain", body: Data("Body too large".utf8), done: done)
            case .failure(.readFailed):
                connection.cancel()
                done()
            case .success(let body):
                guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    sendResponse(
                        connection: connection,
                        status: 400,
                        contentType: "text/plain; charset=utf-8",
                        body: Data("Expected JSON { \"mode\"?, \"startFirst\"?, \"items\":[{displayName, folderPath?, …}] } or { \"action\": \"remove|clear\", \"id\"? }".utf8),
                        done: done
                    )
                    return
                }
                if let action = (object["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !action.isEmpty {
                    let id = (object["id"] as? String)
                        ?? (object["itemId"] as? String)
                    Task { @MainActor in
                        let managed = PendingExportQueue.manageFromREST(action: action, id: id)
                        var payload = managed.payload
                        payload["pendingExportQueue"] = pendingExportQueueStatusPayload()
                        sendJSONPayload(
                            payload,
                            connection: connection,
                            done: done,
                            status: managed.httpStatus
                        )
                    }
                    return
                }
                let modeRaw = (object["mode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "prepend"
                let mode = PendingExportEnqueueMode(rawValue: modeRaw) ?? .prepend
                let startFirst: Bool = {
                    if let b = object["startFirst"] as? Bool { return b }
                    if let n = object["startFirst"] as? Int { return n != 0 }
                    return true
                }()
                var parsed: [PendingExportItem] = []
                if let arr = object["items"] as? [[String: Any]] {
                    for row in arr {
                        let name = (row["displayName"] as? String)
                            ?? (row["saveName"] as? String)
                            ?? (row["name"] as? String)
                            ?? ""
                        let folder = (row["folderPath"] as? String)
                            ?? (row["path"] as? String)
                            ?? (row["listingPath"] as? String)
                        let seek: Int64? = {
                            if let n = row["seekMs"] as? Int64 { return n }
                            if let n = row["seekMs"] as? Int { return Int64(n) }
                            if let n = row["seekMs"] as? Double { return Int64(n) }
                            return nil
                        }()
                        let id = (row["id"] as? String) ?? UUID().uuidString
                        parsed.append(
                            PendingExportItem(
                                id: id,
                                folderPath: folder,
                                displayName: name,
                                seekMs: seek
                            )
                        )
                    }
                }
                let busy = ExportPlaybackState.shared.isLANExportActive
                Task { @MainActor in
                    let queued = PendingExportQueue.queueFromREST(
                        items: parsed,
                        mode: mode,
                        startFirst: startFirst,
                        sessionIsBusy: busy
                    )
                    sendJSONPayload(
                        queued.payload,
                        connection: connection,
                        done: done,
                        status: queued.httpStatus
                    )
                }
            }
        }
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

    private static func htmlURLDownloadPanel() -> String {
        let user = htmlEscape(lanWebDAVUsername)
        let pass = htmlEscape(lanWebDAVPassword)
        return """
        <div class="panel">
        <h2>Export from URL</h2>
        <p class="muted">Same pipeline as browse <strong>Export</strong>: phone downloads the link (vanilla → 60s segments → archive). Prefer <strong>https://</strong>. Keep Loop Segments open on Wi‑Fi. Save name becomes the export display name / file extension. REST: <code>POST /export_from_url.json</code> (Basic auth).</p>
        <div class="row">
          <label style="flex:1 1 auto;min-width:0;display:flex;flex-direction:column;gap:0.25rem;width:100%">URL
            <input type="url" id="url-download-link" placeholder="https://…" style="width:100%;box-sizing:border-box;padding:0.4rem" autocomplete="off" />
          </label>
        </div>
        <div class="row" style="align-items:flex-end;flex-wrap:nowrap;gap:0.65rem">
          <label style="flex:1 1 auto;min-width:0;display:flex;flex-direction:column;gap:0.25rem">Save as (file name)
            <input type="text" id="url-download-name" placeholder="MyClip.mp4" style="width:100%;box-sizing:border-box;padding:0.4rem" autocomplete="off" />
          </label>
          <button type="button" id="url-download-start" style="flex:0 0 auto;white-space:nowrap;align-self:flex-end">Start export</button>
        </div>
        <p id="url-download-status" class="muted"></p>
        </div>
        <script>
        (function () {
          var AUTH = "Basic " + btoa("\(user):\(pass)");
          var exportUrlApi = "/export_from_url.json";
          var ackUrl = "/\(LANExportTriggerControl.ackRelativePath)";
          function uuid() {
            return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function (c) {
              var r = Math.random() * 16 | 0, v = c === "x" ? r : (r & 0x3 | 0x8);
              return v.toString(16);
            });
          }
          function setStatus(msg, isErr) {
            var el = document.getElementById("url-download-status");
            el.textContent = msg || "";
            el.style.color = (typeof __lanStatusColor === "function") ? __lanStatusColor(isErr) : (isErr ? "#b00020" : "#333");
          }
          function guessNameFromUrl(urlText) {
            try {
              var u = new URL(urlText);
              var base = (u.pathname || "").split("/").filter(Boolean).pop() || "";
              try { base = decodeURIComponent(base); } catch (e) {}
              return base;
            } catch (e) {
              return "";
            }
          }
          document.getElementById("url-download-link").addEventListener("change", function () {
            var nameEl = document.getElementById("url-download-name");
            if (nameEl.value.trim()) return;
            var guess = guessNameFromUrl(this.value.trim());
            if (guess) nameEl.value = guess;
          });
          document.getElementById("url-download-start").onclick = async function () {
            var url = document.getElementById("url-download-link").value.trim();
            var saveName = document.getElementById("url-download-name").value.trim();
            if (!url) { setStatus("Enter a download URL", true); return; }
            if (!saveName) {
              saveName = guessNameFromUrl(url) || "download";
              document.getElementById("url-download-name").value = saveName;
            }
            var btn = document.getElementById("url-download-start");
            btn.disabled = true;
            setStatus("Starting export… Keep the phone app open.");
            if (window.setExportPending) {
              window.setExportPending(
                true,
                "Starting URL export",
                "Please wait while the phone starts the same export pipeline as browse Export (vanilla → segments). Keep Loop Segments open in the foreground."
              );
            }
            if (window.updateExportSourceLine) {
              window.updateExportSourceLine("running", saveName);
            }
            try {
              var body = {
                url: url,
                saveName: saveName,
                id: uuid()
              };
              var r = await fetch(exportUrlApi, {
                method: "POST",
                headers: { "Authorization": AUTH, "Content-Type": "application/json" },
                body: JSON.stringify(body)
              });
              var j = null;
              try { j = await r.json(); } catch (e) {}
              if (!r.ok && r.status !== 202) {
                var errText = (j && j.message) ? j.message : "";
                if (!errText) {
                  try { errText = await r.text(); } catch (e2) {}
                }
                throw new Error("POST " + r.status + (errText ? ": " + errText.trim() : ""));
              }
              var finalMsg = (j && (j.status || j.message))
                ? ((j.status || "ok") + ": " + (j.message || ""))
                : ("queued: export " + saveName);
              if (j && (j.status === "rejected" || j.status === "error")) {
                setStatus(finalMsg, true);
                return;
              }
              for (var i = 0; i < 8; i++) {
                await new Promise(function (res) { setTimeout(res, 500); });
                try {
                  var ack = await fetch(ackUrl, { headers: { "Authorization": AUTH } });
                  if (ack.ok) {
                    var a = await ack.json();
                    if (j && j.triggerId && a.triggerId && a.triggerId !== j.triggerId) continue;
                    finalMsg = (a.status || "ok") + ": " + (a.message || "");
                    if (a.status === "rejected" || a.status === "ignored") {
                      setStatus(finalMsg, true);
                      return;
                    }
                    break;
                  }
                } catch (e) {}
              }
              setStatus(finalMsg + " Export runs on the phone — watch the top bar / export_latest.txt.");
              if (window.refreshLANPlayback) {
                for (var p = 0; p < 6; p++) {
                  await new Promise(function (res) { setTimeout(res, 500); });
                  try { await window.refreshLANPlayback(); } catch (e) {}
                }
              }
            } catch (e) {
              setStatus(e.message || String(e), true);
            } finally {
              if (window.setExportPending) window.setExportPending(false);
              btn.disabled = false;
            }
          };
        })();
        </script>
        """
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
          <button type="button" id="export-random">Export random in folder</button>
        </div>
        <div class="row">
          <button type="button" id="export-trim-media">Trim media (keep last 2)</button>
          <button type="button" id="export-clear-media">Clear media</button>
          <button type="button" id="export-lan-speed-test">LAN speed test</button>
        </div>
        <p class="muted" style="margin:0.25rem 0 0;font-size:0.85em">LAN speed test: <strong>10×</strong> browser Range downloads (up to 64&nbsp;MB each ≈ <strong>640&nbsp;MB</strong> total, same file) → <strong>median</strong> Mbps → <code>lan_throughput.json</code> sidecars. Available during export. No other-router reboot — use companion Measure for that.</p>
        <p id="trigger-status" class="muted"></p>
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
            el.style.color = (typeof __lanStatusColor === "function") ? __lanStatusColor(isErr) : (isErr ? "#b00020" : "#333");
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
              case "resume_export":
                return {
                  title: "Starting export",
                  detail: "Please wait while the phone resumes the paused export." + foreground
                };
              case "clear_media":
                return {
                  title: "Clearing media",
                  detail: "Please wait while the phone permanently deletes active export media, archive/, and downloads/ files." + foreground
                };
              case "download_url":
                return {
                  title: "Starting URL export",
                  detail: "Please wait while the phone starts the same export pipeline as browse Export (vanilla → segments)." + foreground
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
            ["export-resume", "export-random", "export-trim-media", "export-clear-media"].forEach(function (id) {
              var btn = document.getElementById(id);
              if (btn) btn.disabled = !!active;
            });
            document.querySelectorAll(".export-file").forEach(function (btn) {
              btn.disabled = !!active;
            });
            document.querySelectorAll(".export-parked").forEach(function (btn) {
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
            } else if (body.command === "resume_export" && window.updateExportSourceLine) {
              var curName = document.getElementById("lan-export-source-name");
              if (curName && curName.textContent) window.updateExportSourceLine("running", curName.textContent);
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
          document.getElementById("export-trim-media").onclick = function () {
            putTrigger({ version: 1, command: "trim_media", id: uuid() })
              .catch(function (e) { setStatus(e.message || e, true); });
          };
          document.getElementById("export-clear-media").onclick = function () {
            if (!confirm("Permanently delete active export media, archive/, and downloads/ files on the phone?")) return;
            putTrigger({ version: 1, command: "clear_media", id: uuid() })
              .catch(function (e) { setStatus(e.message || e, true); });
          };
          if (window.bindLANSpeedTestButton) {
            window.bindLANSpeedTestButton({
              buttonId: "export-lan-speed-test",
              setStatus: setStatus,
              authHeader: AUTH
            });
          }
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
                folderPath: pcloudPath,
                seekMs: 0,
                id: uuid()
              }).catch(function (e) { setStatus(e.message || e, true); });
            }
          };
          function queueParkedResume(btn) {
            if (!btn) return;
            var href = (btn.getAttribute("data-href") || "").trim();
            var name = (btn.getAttribute("data-name") || "").trim();
            var folder = (btn.getAttribute("data-folder-path") || "").trim();
            var seekMs = parseInt(btn.getAttribute("data-seek-ms") || "0", 10) || 0;
            var body = { version: 1, command: "start_export", displayName: name, seekMs: seekMs, id: uuid() };
            if (href) body.href = href;
            if (folder) body.folderPath = folder;
            if (!href && !folder && !name) {
              setStatus("Parked resume missing href/folder/name", true);
              return;
            }
            putTrigger(body).catch(function (e) { setStatus(e.message || e, true); });
          }
          var playbackFiles = document.getElementById("lan-playback-files");
          if (playbackFiles) {
            playbackFiles.onclick = function (ev) {
              var parkedBtn = ev.target.closest ? ev.target.closest(".export-parked") : null;
              if (!parkedBtn && ev.target.classList && ev.target.classList.contains("export-parked")) {
                parkedBtn = ev.target;
              }
              if (parkedBtn) queueParkedResume(parkedBtn);
            };
          }
          var pausedList = document.getElementById("lan-paused-list");
          if (pausedList) {
            pausedList.onclick = function (ev) {
              var parkedBtn = ev.target.closest ? ev.target.closest(".export-parked") : null;
              if (!parkedBtn && ev.target.classList && ev.target.classList.contains("export-parked")) {
                parkedBtn = ev.target;
              }
              if (parkedBtn) queueParkedResume(parkedBtn);
            };
          }
          loadPins().then(function () { loadPCloud(); }).catch(function () { loadPCloud(); });
          window.refreshLANBookmarks = loadPins;
        })();
        </script>
        """
    }

    /// Playback/log link HTML + file index — polled less often than `status.json` (or manual refresh on `/`).
    private static func sendStatusListsJSON(_ connection: NWConnection, done: @escaping () -> Void) {
        var payload: [String: Any] = [:]
        autoreleasepool {
            let index = currentLANIndexSnapshot()
            payload["playbackListHTML"] = playbackMediaFileListHTML()
            payload["exportLogsListHTML"] = exportLogsFileListHTML()
            payload["files"] = statusFilesJSONArray(from: index)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            sendResponse(connection: connection, status: 500, contentType: "text/plain", body: Data("JSON error".utf8), done: done)
            return
        }
        sendResponse(connection: connection, status: 200, contentType: "application/json", body: data, done: done)
    }

    private static func sendStatusJSON(_ connection: NWConnection, done: @escaping () -> Void) {
        let exportActive = ExportPlaybackState.shared.isLANExportActive
        if !exportActive {
            refreshLANMetricsBeforeStatusResponse()
        }
        var payload: [String: Any] = [
            "exportsDirectory": "Exports",
            "port": Int(defaultPort),
            "listsDeferred": true,
        ]
        if exportActive {
            payload["manualRefresh"] = true
        }
        if !exportActive {
            let index = currentLANIndexSnapshot()
            payload["files"] = statusFilesJSONArray(from: index)
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
        } else if FileManager.default.fileExists(atPath: ExportPaths.workingSourceURL.path) {
            var playback = ExportPlaybackState.shared.frozenStatusPayload
            let startSec = (playback["playbackStartSeconds"] as? Double) ?? 0
            playback["resumeTimelineReadable"] = ExportPlaybackState.shared.timelineSecondsIsReadable(startSec)
            payload["workingSourcePlayback"] = playback
        }
            payload["playbackStatusHTML"] = playbackStatusHTMLBlock()
        } else {
            payload["lanLive"] = ExportPlaybackState.shared.lanLiveStatusPayloadSlim()
        }
        if let exportSource = LANExportSourceDisplay.statusPayload() {
            payload["exportSource"] = exportSource
        }
        payload["pendingExportQueue"] = pendingExportQueueStatusPayload()
        payload["pausedExports"] = pausedExportsStatusPayload()
        payload["wifiWwwProbe"] = WifiWwwProbe.currentSnapshot().statusJSON()
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
              let sizeNum = attrs[.size] as? NSNumber else {
            sendResponse(connection: connection, status: 404, contentType: "text/plain", body: Data("Not found".utf8), done: done)
            return
        }
        let fileSize = sizeNum.int64Value
        if fileSize == 0 {
            let rel = ExportPaths.pathRelativeToExports(fileURL)
            let isAuxLog = ExportPaths.isLANExportLogRelativePath(rel)
                || ExportPaths.canonicalLANLogRelativePath(rel) != nil
            guard isAuxLog else {
                sendResponse(connection: connection, status: 404, contentType: "text/plain", body: Data("Empty or missing".utf8), done: done)
                return
            }
            let contentType = mimeType(for: fileURL)
            sendResponse(
                connection: connection,
                status: 200,
                contentType: contentType,
                body: Data(),
                done: done
            )
            return
        }
        if ExportPlaybackState.shared.isLANExportActive,
           ExportPaths.isLANBrowsableMediaFile(fileName: fileURL.lastPathComponent),
           shouldRejectBrowserMediaGETDuringExport(
               requestHeaders: requestHeaders,
               method: method,
               fileURL: fileURL,
               fileSize: fileSize
           ) {
            sendResponse(
                connection: connection,
                status: 503,
                contentType: "text/plain",
                body: Data(
                    "Export active — browser prefetch blocked. Click the media link on the LAN page, use WebDAV (PotPlayer), or open export_latest.txt."
                        .utf8
                ),
                done: done
            )
            return
        }
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
