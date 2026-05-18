import Foundation

/// URLSession tuned for large pCloud WebDAV reads over cellular (export).
enum WebDAVMediaSession {
    private final class SessionDelegate: NSObject, URLSessionTaskDelegate {
        var credentials: WebDAVCredentials?

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic,
                  let credentials else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let credential = URLCredential(
                user: credentials.email,
                password: credentials.password,
                persistence: .forSession
            )
            completionHandler(.useCredential, credential)
        }
    }

    private static let sessionDelegate = SessionDelegate()

    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 60 * 60
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
    }()

    static func setActiveCredentials(_ credentials: WebDAVCredentials?) {
        sessionDelegate.credentials = credentials
    }

    /// Retries transient cellular drops (connection lost, timeout, etc.).
    static func data(
        for request: URLRequest,
        log: ((String) -> Void)? = nil,
        maxAttempts: Int = 8
    ) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 1 ... maxAttempts {
            do {
                return try await shared.data(for: request)
            } catch {
                lastError = error
                guard isRetriable(error), attempt < maxAttempts else { throw error }
                let delaySec = min(30, attempt * 3)
                log?("pCloud retry \(attempt + 1)/\(maxAttempts) in \(delaySec)s: \(error.localizedDescription)")
                try await Task.sleep(nanoseconds: UInt64(delaySec) * 1_000_000_000)
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    static func isRetriable(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorSecureConnectionFailed,
                 NSURLErrorDataNotAllowed:
                return true
            default:
                break
            }
        }
        let text = error.localizedDescription.lowercased()
        return text.contains("interrupted")
            || text.contains("connection was lost")
            || text.contains("network connection lost")
    }

    static func friendlyMessage(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNetworkConnectionLost:
                return """
                Network connection lost while reading pCloud (common on cellular). Keep the app open — \
                retries run automatically. Try seek 0 min, stronger signal, or Wi‑Fi for export.
                """
            case NSURLErrorTimedOut:
                return """
                Timed out loading from pCloud (often at 10+ min seek on cellular). Try seek 0 min, \
                stronger signal, or Wi‑Fi. See export log for retry lines.
                """
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed:
                return "No internet for pCloud. Check cellular/Wi‑Fi and Settings → Cellular → Loop Segments."
            default:
                break
            }
        }
        if ns.localizedDescription.localizedCaseInsensitiveContains("connection was lost")
            || ns.localizedDescription.localizedCaseInsensitiveContains("network connection lost") {
            return friendlyMessage(for: URLError(.networkConnectionLost))
        }
        if ns.localizedDescription.contains("timed out") {
            return friendlyMessage(for: URLError(.timedOut))
        }
        return error.localizedDescription
    }
}
