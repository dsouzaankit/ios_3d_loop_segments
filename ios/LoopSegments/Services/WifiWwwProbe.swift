import Foundation

/// Wi‑Fi-only WAN reachability (www). Cellular is forbidden so success cannot be Wi‑Fi Assist.
enum WifiWwwProbe {
    /// Apple captive portal detect — lightweight, expected 200 with body `Success`.
    static let probeURL = URL(string: "https://captive.apple.com/hotspot-detect.html")!

    private static let lock = NSLock()
    private static var lastResult: ResultSnapshot = .idle

    struct ResultSnapshot: Sendable {
        var ok: Bool?
        var checkedAt: Date?
        var statusCode: Int?
        var error: String?
        var url: String
        var durationMs: Int?

        static let idle = ResultSnapshot(
            ok: nil,
            checkedAt: nil,
            statusCode: nil,
            error: nil,
            url: WifiWwwProbe.probeURL.absoluteString,
            durationMs: nil
        )

        func statusJSON() -> [String: Any] {
            var payload: [String: Any] = [
                "url": url,
                "allowsCellularAccess": false,
            ]
            if let ok {
                payload["ok"] = ok
            } else {
                payload["ok"] = NSNull()
            }
            if let checkedAt {
                payload["checkedAt"] = ISO8601DateFormatter().string(from: checkedAt)
            }
            if let statusCode {
                payload["statusCode"] = statusCode
            }
            if let error {
                payload["error"] = error
            }
            if let durationMs {
                payload["durationMs"] = durationMs
            }
            return payload
        }
    }

    static func currentSnapshot() -> ResultSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return lastResult
    }

    /// Runs a Wi‑Fi-only HEAD/GET. Blocks the calling thread up to `timeout` (use a background queue from LAN).
    @discardableResult
    static func runBlocking(timeout: TimeInterval = 8) -> ResultSnapshot {
        let started = Date()
        var request = URLRequest(url: probeURL, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("LoopSegments-WifiWwwProbe", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = false
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        let semaphore = DispatchSemaphore(value: 0)
        var statusCode: Int?
        var transportError: String?
        var bodyHint: String?

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                transportError = error.localizedDescription
                return
            }
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
            }
            if let data, let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                bodyHint = String(text.prefix(80))
            }
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        session.invalidateAndCancel()

        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        let code = statusCode ?? 0
        let ok = (200..<400).contains(code)
        let snapshot = ResultSnapshot(
            ok: ok,
            checkedAt: Date(),
            statusCode: statusCode,
            error: ok ? nil : (transportError ?? bodyHint ?? (code == 0 ? "no response (Wi‑Fi path failed or blocked)" : "HTTP \(code)")),
            url: probeURL.absoluteString,
            durationMs: durationMs
        )
        lock.lock()
        lastResult = snapshot
        lock.unlock()
        return snapshot
    }
}
