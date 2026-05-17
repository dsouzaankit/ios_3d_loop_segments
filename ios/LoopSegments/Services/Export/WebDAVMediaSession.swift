import Foundation

/// URLSession tuned for large pCloud WebDAV reads over cellular (export).
enum WebDAVMediaSession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 60 * 60
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: config)
    }()

    static func isRetriable(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorSecureConnectionFailed:
            return true
        default:
            return false
        }
    }

    static func friendlyMessage(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorTimedOut {
            return """
            Timed out loading from pCloud (often at 10+ min seek on cellular). Try seek **0 min**, \
            stronger signal, or Wi‑Fi for export. Keep the app open; see log for pCloud retry lines.
            """
        }
        if ns.localizedDescription.contains("timed out") {
            return """
            Timed out opening video from pCloud. Try **Wi‑Fi** for export, wait for stronger cellular, \
            or use PC Run-SegmentCopy.ps1 (see FEASIBILITY.md). Check log for Prefetch / retry lines.
            """
        }
        return error.localizedDescription
    }
}
