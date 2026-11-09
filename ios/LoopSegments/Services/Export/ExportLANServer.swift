import Darwin
import Foundation
import Network
import UIKit

/// Serves export logs and media from private `Application Support/pcld_ios_media/` on the LAN (HTTP + WebDAV).
/// `pcld_ios_media/` accepts authenticated PUT/MKCOL/DELETE/MOVE for PC scripts and writable media; export pipeline paths stay read-only.
enum ExportLANServer {
    static let defaultPort: UInt16 = 8765
    /// Per-response cap — open-ended `Range: bytes=0-` must not ship multi-GB (Quest browser / Safari OOM).
    static let maxResponseBodyBytes: Int64 = 32 * 1024 * 1024
    /// PC script uploads via WebDAV PUT (Basic auth required).
    static let maxWebDAVPutBytes: Int = 2 * 1024 * 1024
    /// LAN WebDAV Basic auth (Skybox, mapped drives). GET without auth still works for PC sync.
    static let lanWebDAVUsername = "admin"
    /// Per-install, from the Keychain (`LANPasswordStore`); shown on the Export screen.
    static var lanWebDAVPassword: String { LANPasswordStore.current }
    static let lanWebDAVRealm = "Loop Segments LAN"
    static let enabledKey = "serveExportsOnLAN"
    static let backgroundCutoffKey = "lanBackgroundPrefetchCutoffMbps"

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

    static let lock = NSLock()
    static var listener: NWListener?
    static var listenerIsReady = false
    static var startInFlight = false
    static var addressInUseRetryCount = 0
    static let maxAddressInUseRetries = 8
    static var connections: [ObjectIdentifier: NWConnection] = [:]
    static let queue = DispatchQueue(label: "com.loopsegments.lan-server")
    /// Serializes cancel→rebind so a still-tearing-down NWListener cannot leave :8765 wedged (EADDRINUSE + nothing accepting).
    static var listenerCancelGeneration = 0
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
    static var advertisedBaseURL: String?
    static var advertisedIPAddressURL: String?

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

    static func beginListenAttempt(log: @escaping (String) -> Void, delaySeconds: TimeInterval = 0) {
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

    static func cancelListenerAndWait(_ stale: NWListener?, then work: @escaping () -> Void) {
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

    static func bindNewListener(log: @escaping (String) -> Void, includeBonjour: Bool = true) {
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

    static func scheduleListenRetryIfNeeded(
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

    static func isAddressAlreadyInUse(_ error: Error) -> Bool {
        if containsAddressInUseCode(error as NSError) { return true }
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, containsAddressInUseCode(underlying) {
            return true
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("already in use")
    }

    static func containsAddressInUseCode(_ ns: NSError) -> Bool {
        ns.code == 48
            || (ns.domain == NSPOSIXErrorDomain && ns.code == EADDRINUSE)
    }

    static func stop(log: ((String) -> Void)? = nil) {
        queue.async {
            stopOnQueue(log: log, resetAddressInUseRetries: true)
        }
    }

    static func stopOnQueue(log: ((String) -> Void)?, resetAddressInUseRetries: Bool = true) {
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

    static func performWhenReady(
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

    static func receiveRequest(on connection: NWConnection, done: @escaping () -> Void) {
        performWhenReady(connection: connection, onFailure: done) {
            receiveHTTPHeaders(on: connection, accumulated: Data(), done: done)
        }
    }

    static func receiveHTTPHeaders(
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

    static func handleRequest(
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

    static func requestBaseURL(from requestHeaders: String) -> String {
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
    static func davListingHref(path: String, isCollection: Bool) -> String {
        var p = normalizedDAVPath(path)
        if isCollection, p != "/", !p.hasSuffix("/") {
            p += "/"
        }
        return p
    }

    static func parseRequestLine(_ line: String) -> (String, String)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let path = httpRequestPath(from: String(parts[1]))
        return (String(parts[0]).uppercased(), path)
    }

    /// Request-target may be `/op_00.mp4` (browser) or `http://host:8765/op_00.mp4` (Skybox, some WebDAV clients).
    /// Preserves `?query=` for LAN JSON APIs (`pcloud_list.json?path=…`).
    static func httpRequestPath(from raw: String) -> String {
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

    static func isWebDAVClient(requestHeaders: String) -> Bool {
        let lower = requestHeaders.lowercased()
        if lower.contains("microsoft-webdav") { return true }
        if lower.contains("translate: f") { return true }
        // Check each header line. "\r\n" is one Character in Swift, so searching the text for
        // "\ndepth:" never matched after a CRLF line break.
        let lines = lower.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" })
        if lines.contains(where: { $0.hasPrefix("depth:") }) { return true }
        if lower.contains("user-agent:") {
            for token in ["skybox", "webdav", "okhttp", "dalvik", "unity"] {
                if lower.contains(token) { return true }
            }
        }
        return false
    }

    static func normalizedGETPath(_ path: String) -> String {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        // Strip ?query so `/xr?mode=working` matches the same route as `/xr`.
        return splitPathAndQuery(trimmed).path
    }

    /// Auth on OPTIONS/PROPFIND/LOCK, WebDAV writes, and WebDAV `GET /`. Media GET stays open (Skybox often omits Authorization on play).
    static func requiresLANWebDAVAuth(method: String, path: String, requestHeaders: String) -> Bool {
        switch method {
        case "OPTIONS", "PROPFIND", "LOCK", "PUT", "MKCOL", "DELETE", "MOVE":
            return true
        case "POST":
            // Quest /xr posts xr_debug.json with no Basic auth. A 401 here pops the browser
            // login sheet (seen on AR exit) and drops the debug ring.
            if normalizedGETPath(path) == "xr_debug.json" { return false }
            return true
        case "GET", "HEAD":
            // The LAN pages (/, /browse) need the login too. Their scripts rely on the browser
            // resending it, so the password is never written into a page. Media and JSON stay open.
            let route = normalizedGETPath(path)
            return route.isEmpty || route == "browse"
        default:
            return false
        }
    }

    @discardableResult
    static func enforceLANWebDAVAuth(
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
    static func enforceLANProxyAuth(
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
    static func isBrowserLikeRequest(requestHeaders: String) -> Bool {
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
    static func shouldServeMinimalMonitorHTML(requestHeaders: String) -> Bool {
        !isWebDAVClient(requestHeaders: requestHeaders)
    }

    /// Chrome desktop may speculative-prefetch same-origin links on the monitor page (PotPlayer WebDAV does not).
    static func isBrowserPrefetchRequest(requestHeaders: String) -> Bool {
        let lower = requestHeaders.lowercased()
        if lower.contains("sec-purpose: prefetch") { return true }
        if lower.contains("purpose: prefetch") { return true }
        if lower.contains("x-moz: prefetch") { return true }
        if lower.contains("sec-fetch-mode: prefetch") { return true }
        return false
    }

    /// Top-level navigation (address bar, `window.open`, `target=_blank` to media) — not speculative prefetch.
    /// Chrome sends `Sec-Fetch-Mode: navigate` on that first GET, which would otherwise hit the large file no-Range block and return 503.
    static func isBrowserUserNavigationMediaGET(requestHeaders: String) -> Bool {
        let lower = requestHeaders.lowercased()
        if lower.contains("sec-fetch-mode: navigate") { return true }
        // Chrome adds this for user-activated navigations; helps distinguish from speculative fetches.
        if lower.contains("sec-fetch-user: ?1") { return true }
        // Fallback when Sec-Fetch headers are missing (some Chrome setups/extensions): typical on top-level navigations.
        if lower.contains("upgrade-insecure-requests: 1") { return true }
        return false
    }

    /// Block browser full-file GET of large media during export (prefetch / accidental navigation). WebDAV and Range GET stay allowed.
    static func shouldRejectBrowserMediaGETDuringExport(
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

    static func lanWebDAVAuthHeaderLines() -> [String] {
        ["WWW-Authenticate: Basic realm=\"\(lanWebDAVRealm)\""]
    }

    /// When `Authorization` is sent it must match `lanWebDAVUsername` / `lanWebDAVPassword`.
    static func lanWebDAVAuthorizationOK(requestHeaders: String) -> Bool {
        guard let value = headerValue(named: "Authorization", in: requestHeaders) else {
            return true
        }
        guard let (user, password) = parseBasicAuthorization(value) else { return false }
        return user.caseInsensitiveCompare(lanWebDAVUsername) == .orderedSame
            && password == lanWebDAVPassword
    }

    static func parseBasicAuthorization(_ value: String) -> (user: String, password: String)? {
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

    static func headerValue(named name: String, in requestHeaders: String) -> String? {
        let prefix = "\(name.lowercased()):"
        for line in requestHeaders.split(separator: "\r\n", omittingEmptySubsequences: true) {
            let lower = line.lowercased()
            guard lower.hasPrefix(prefix) else { continue }
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func handleGET(
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
        if let script = xrPlayerScript(path: normalized) {
            sendResponse(connection: connection, status: 200, contentType: "text/javascript; charset=utf-8", body: Data(script.utf8), done: done)
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

    static func httpResponseHeader(
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

    static func clampResponseEnd(byteStart: Int64, byteEnd: Int64, fileSize: Int64) -> Int64 {
        let maxEnd = min(fileSize - 1, byteStart + maxResponseBodyBytes - 1)
        return min(byteEnd, maxEnd)
    }

    static func fileETag(size: Int64) -> String {
        String(format: "\"%016llx\"", size)
    }

    /// Parses `Range: bytes=…` for a file of `fileSize` bytes (single range only).
    static func parseByteRange(requestHeaders: String, fileSize: Int64) -> (start: Int64, end: Int64)? {
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

    static func sendFile(
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

    static func streamFile(
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

    static func respondWorkingSourceUnreadable(
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

    static func sendResponse(
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

    static func formatLANClock(_ totalSeconds: Double) -> String {
        formatLANClock(Int(totalSeconds.rounded(.down)))
    }

    static func formatLANClock(_ totalSeconds: Int) -> String {
        ExportTimelineLog.wallClock(seconds: Double(max(0, totalSeconds)))
    }

    static func mimeType(for url: URL) -> String {
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
    static func deviceMDNSHostLabel() -> String {
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

    static func sanitizeMDNSHostLabel(_ label: String) -> String {
        let folded = label.folding(options: .diacriticInsensitive, locale: .current)
        let safe = folded.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "'", with: "")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return safe.isEmpty ? "iphone" : safe
    }

    static func primaryLANIPv4Address() -> String? {
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
