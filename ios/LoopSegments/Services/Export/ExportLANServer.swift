import Darwin
import Foundation
import Network

/// Serves `Documents/Exports/` on the LAN when enabled (Path B — PC pull without USB/Photos).
enum ExportLANServer {
    static let defaultPort: UInt16 = 8765
    private static let enabledKey = "serveExportsOnLAN"

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
    private static var advertisedBaseURL: String?

    static var baseURLString: String? {
        lock.lock()
        defer { lock.unlock() }
        return advertisedBaseURL
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
                lock.lock()
                listener = nwListener
                lock.unlock()

                nwListener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let ip = Self.primaryLANIPv4Address() ?? "?"
                        let url = "http://\(ip):\(defaultPort)/"
                        lock.lock()
                        advertisedBaseURL = url
                        lock.unlock()
                        log("LAN export: \(url) — PC: Sync-FromPhoneLAN.ps1 -PhoneHost \(ip) -Watch")
                        let segmentName = ExportPaths.segmentURL(index: 0).lastPathComponent
                        log("LAN files: / status.json, /\(segmentName), /_export_source_working.mp4 (last export temp, if present)")
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
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                if let error {
                    connection.cancel()
                    _ = error
                    done()
                    return
                }
                guard let data, !data.isEmpty,
                      let text = String(data: data, encoding: .utf8) else {
                    sendResponse(connection: connection, status: 400, contentType: "text/plain", body: Data("Bad request".utf8), done: done)
                    return
                }
                guard let line = text.split(separator: "\r\n", maxSplits: 1).first,
                      let (method, path) = parseRequestLine(String(line)) else {
                    sendResponse(connection: connection, status: 400, contentType: "text/plain", body: Data("Bad request".utf8), done: done)
                    return
                }
                guard method == "GET" else {
                    sendResponse(connection: connection, status: 405, contentType: "text/plain", body: Data("GET only".utf8), done: done)
                    return
                }
                handleGET(path: path, connection: connection, done: done)
            }
        }
    }

    private static func parseRequestLine(_ line: String) -> (String, String)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        var path = String(parts[1])
        if let query = path.firstIndex(of: "?") {
            path = String(path[..<query])
        }
        if path.isEmpty { path = "/" }
        return (String(parts[0]).uppercased(), path)
    }

    private static func handleGET(path: String, connection: NWConnection, done: @escaping () -> Void) {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if normalized.isEmpty {
            sendIndexHTML(connection, done: done)
            return
        }
        if normalized == "status.json" {
            sendStatusJSON(connection, done: done)
            return
        }
        guard let fileURL = resolveExportFile(name: normalized) else {
            sendResponse(connection: connection, status: 404, contentType: "text/plain", body: Data("Not found".utf8), done: done)
            return
        }
        sendFile(connection: connection, fileURL: fileURL, done: done)
    }

    private static func httpResponseHeader(status: Int, phrase: String, contentType: String, contentLength: Int) -> String {
        "HTTP/1.1 \(status) \(phrase)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(contentLength)\r\n" +
            "Connection: close\r\n\r\n"
    }

    private static func resolveExportFile(name: String) -> URL? {
        guard !name.contains("/"), !name.contains("..") else { return nil }
        let allowedNames: Set<String> = {
            var names: Set<String> = [
                ExportPaths.latestLogTextURL.lastPathComponent,
                ExportPaths.latestLogURL.lastPathComponent,
                ExportPaths.exportProgressURL.lastPathComponent,
                "status.json",
            ]
            for slot in 0 ..< ExportPaths.segmentFileCount {
                names.insert(ExportPaths.segmentURL(index: slot).lastPathComponent)
            }
            names.insert(ExportPaths.workingSourceURL.lastPathComponent)
            return names
        }()
        guard allowedNames.contains(name) else { return nil }
        if name == "status.json" { return nil }
        let url = ExportPaths.exportsDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static func sendIndexHTML(_ connection: NWConnection, done: @escaping () -> Void) {
        let fm = FileManager.default
        let dir = ExportPaths.exportsDirectory
        var items: [String] = []
        if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
            for name in names.sorted() {
                guard resolveExportFile(name: name) != nil else { continue }
                let url = dir.appendingPathComponent(name)
                var sizeNote = ""
                if let attrs = try? fm.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? NSNumber, size.int64Value > 0 {
                    sizeNote = " (\(size.int64Value / 1024) KB)"
                }
                let escaped = name
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "\"", with: "&quot;")
                items.append("<li><a href=\"\(escaped)\">\(escaped)</a>\(sizeNote)</li>")
            }
        }
        let fileList = items.isEmpty
            ? "<li><em>No export files yet — start export on the phone.</em></li>"
            : items.joined()
        let html = """
            <!DOCTYPE html>
            <html lang="en"><head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Loop Segments — LAN export</title>
            <style>
            body { font: -apple-system-body; margin: 1.25rem; line-height: 1.4; }
            code { font-size: 0.9em; }
            ul { padding-left: 1.25rem; }
            </style>
            </head><body>
            <h1>Loop Segments — LAN export</h1>
            <p>Serving <code>Documents/Exports/</code> on port \(defaultPort).</p>
            <p>PC: <code>Sync-FromPhoneLAN.ps1 -Watch</code> (uses <a href="status.json">status.json</a>).</p>
            <ul>
            \(fileList)
            </ul>
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

    private static func sendStatusJSON(_ connection: NWConnection, done: @escaping () -> Void) {
        let fm = FileManager.default
        let dir = ExportPaths.exportsDirectory
        var entries: [[String: Any]] = []
        if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
            for name in names.sorted() {
                guard resolveExportFile(name: name) != nil || name.hasSuffix(".mp4") || name.hasSuffix(".txt") else {
                    continue
                }
                let url = dir.appendingPathComponent(name)
                var dict: [String: Any] = ["name": name]
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
        }
        let payload: [String: Any] = [
            "exportsDirectory": "Exports",
            "port": Int(defaultPort),
            "files": entries,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            sendResponse(connection: connection, status: 500, contentType: "text/plain", body: Data("JSON error".utf8), done: done)
            return
        }
        sendResponse(connection: connection, status: 200, contentType: "application/json", body: data, done: done)
    }

    private static func sendFile(connection: NWConnection, fileURL: URL, done: @escaping () -> Void) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let sizeNum = attrs[.size] as? NSNumber,
              sizeNum.int64Value > 0 else {
            sendResponse(connection: connection, status: 404, contentType: "text/plain", body: Data("Empty or missing".utf8), done: done)
            return
        }
        let size = sizeNum.int64Value
        let contentType = mimeType(for: fileURL)
        let header = httpResponseHeader(status: 200, phrase: "OK", contentType: contentType, contentLength: Int(size))
        guard let headerData = header.data(using: .utf8) else {
            done()
            return
        }
        connection.send(content: headerData, completion: .contentProcessed { error in
            if error != nil {
                connection.cancel()
                done()
                return
            }
            streamFile(connection: connection, fileURL: fileURL, offset: 0, remaining: size, done: done)
        })
    }

    private static func streamFile(
        connection: NWConnection,
        fileURL: URL,
        offset: Int64,
        remaining: Int64,
        done: @escaping () -> Void
    ) {
        if remaining <= 0 {
            connection.cancel()
            done()
            return
        }
        let chunkSize = min(remaining, 512 * 1024)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            connection.cancel()
            done()
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            let data = handle.readData(ofLength: Int(chunkSize))
            guard !data.isEmpty else {
                connection.cancel()
                done()
                return
            }
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    connection.cancel()
                    done()
                    return
                }
                let sent = Int64(data.count)
                streamFile(
                    connection: connection,
                    fileURL: fileURL,
                    offset: offset + sent,
                    remaining: remaining - sent,
                    done: done
                )
            })
        } catch {
            connection.cancel()
            done()
        }
    }

    private static func sendResponse(
        connection: NWConnection,
        status: Int,
        contentType: String,
        body: Data,
        done: @escaping () -> Void
    ) {
        let phrase = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Error")
        let header = httpResponseHeader(
            status: status,
            phrase: phrase,
            contentType: contentType,
            contentLength: body.count
        )
        var data = Data(header.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
            done()
        })
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "txt", "log": return "text/plain; charset=utf-8"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }

    // MARK: - IPv4

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
            if ip.hasPrefix("127.") || ip == "0.0.0.0" { continue }
            candidates.append((name, ip))
        }
        if let en0 = candidates.first(where: { $0.name == "en0" })?.address {
            return en0
        }
        return candidates.first?.address
    }
}
