import Darwin
import Foundation
import Network
import UIKit

/// JSON endpoints: status, queue, paused exports, pCloud proxy, throughput, XR debug and tunnel.
extension ExportLANServer {
    static func splitPathAndQuery(_ normalized: String) -> (path: String, query: [String: String]) {
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

    static func sendJSONPayload(
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

    static func sendPCloudListJSON(
        folderPath: String,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        Task { @MainActor in
            let payload = await LANHTTPExportAPI.pcloudListPayload(folderPath: folderPath)
            sendJSONPayload(payload, connection: connection, done: done)
        }
    }

    static func sendPCloudBookmarksJSON(
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        sendJSONPayload(FolderBookmarkStore.lanBookmarksPayload(), connection: connection, done: done)
    }

    static var xrTunnelSidecarURL: URL {
        _ = ExportPaths.lanExportScriptsDirectory
        return ExportPaths.lanExportScriptsDirectory.appendingPathComponent("xr_tunnel.json")
    }

    // MARK: - XR debug ring (Quest /xr posts; PC pulls GET)

    static let xrDebugLock = NSLock()
    static var xrDebugLines: [String] = []
    static var xrDebugSnapshot: [String: Any] = [:]
    static let xrDebugCap = 500

    static var xrDebugLogURL: URL {
        _ = ExportPaths.lanExportScriptsDirectory
        return ExportPaths.lanExportScriptsDirectory.appendingPathComponent("xr_debug.log")
    }

    static func appendXRDebugLines(_ lines: [String], snapshot: [String: Any]?) {
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

    static func xrDebugPayload() -> [String: Any] {
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

    static func sendXRDebugGET(connection: NWConnection, done: @escaping () -> Void) {
        sendJSONPayload(xrDebugPayload(), connection: connection, done: done, status: 200)
    }

    static func handleXRDebugWrite(
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

    static func normalizeXRTunnelHost(_ raw: String) -> String? {
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

    static func xrTunnelPayload(host: String) -> [String: Any] {
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

    static func readXRTunnelHostFromDisk() -> String {
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

    static func writeXRTunnelHostToDisk(_ host: String) throws -> [String: Any] {
        let payload = xrTunnelPayload(host: host)
        _ = ExportPaths.lanExportScriptsDirectory
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: xrTunnelSidecarURL, options: .atomic)
        return payload
    }

    static func sendXRTunnelGET(connection: NWConnection, done: @escaping () -> Void) {
        let host = readXRTunnelHostFromDisk()
        sendJSONPayload(xrTunnelPayload(host: host), connection: connection, done: done, status: 200)
    }

    static func handleXRTunnelWrite(
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

    static func sendLANThroughputGET(connection: NWConnection, done: @escaping () -> Void) {
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

    static func handleLANThroughputPOST(
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

    struct LANThroughputPOSTParseError: Error {
        let message: String
    }

    static func parseLANThroughputPOSTBody(
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

    static func stringValue(_ any: Any?) -> String? {
        guard let any else { return nil }
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    static func doubleValue(_ any: Any?) -> Double? {
        guard let any else { return nil }
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String, let d = Double(s) { return d }
        return nil
    }

    static func int64Value(_ any: Any?) -> Int64? {
        guard let any else { return nil }
        if let i = any as? Int64 { return i }
        if let i = any as? Int { return Int64(i) }
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String, let i = Int64(s) { return i }
        if let d = any as? Double { return Int64(d) }
        return nil
    }

    static func sendExportFromURLUsageJSON(connection: NWConnection, done: @escaping () -> Void) {
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

    static func sendExportFromFolderUsageJSON(connection: NWConnection, done: @escaping () -> Void) {
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

    static func handleExportFromURLWrite(
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

    static func handleExportFromFolderWrite(
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
    static func pendingExportQueueStatusPayload() -> [String: Any] {
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

    static func sendExportQueueUsageJSON(connection: NWConnection, done: @escaping () -> Void) {
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

    static func sendPausedExportsUsageJSON(connection: NWConnection, done: @escaping () -> Void) {
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

    static func handlePausedExportsWrite(
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

    static func handleExportQueueWrite(
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

    static func handlePCloudBookmarksPUT(
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

    /// Playback/log link HTML + file index — polled less often than `status.json` (or manual refresh on `/`).
    static func sendStatusListsJSON(_ connection: NWConnection, done: @escaping () -> Void) {
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

    static func sendStatusJSON(_ connection: NWConnection, done: @escaping () -> Void) {
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
}
