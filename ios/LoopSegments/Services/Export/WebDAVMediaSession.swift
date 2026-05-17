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
            Network timed out loading from pCloud. Stay on cellular with a strong signal, \
            keep the app open, and try again. Large files use many range requests — Wi‑Fi may help.
            """
        }
        return error.localizedDescription
    }
}
