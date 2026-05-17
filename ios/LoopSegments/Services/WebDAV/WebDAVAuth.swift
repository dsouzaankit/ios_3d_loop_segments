import Foundation

typealias WebDAVAuthorizationProvider = () -> String

enum WebDAVAuth {
    /// Reads latest credentials from Keychain on each call (password updates, same session).
    static func provider(fallback: WebDAVCredentials) -> WebDAVAuthorizationProvider {
        let store = CredentialStore()
        return {
            if let loaded = store.load(account: fallback.email),
               loaded.region == fallback.region,
               !loaded.password.isEmpty {
                return loaded.authorizationHeaderValue
            }
            return fallback.authorizationHeaderValue
        }
    }
}

enum WebDAVAccessProbe {
    static func verifyMediaURL(
        _ url: URL,
        authorization: WebDAVAuthorizationProvider,
        log: ((String) -> Void)? = nil
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(authorization(), forHTTPHeaderField: "Authorization")

        let (_, response) = try await WebDAVMediaSession.data(for: request, log: log)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVResourceLoaderError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw WebDAVResourceLoaderError.httpStatus(http.statusCode)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw WebDAVResourceLoaderError.httpStatus(http.statusCode)
        }
        if let length = contentLength(from: http) {
            log?("Auth probe OK — HTTP \(http.statusCode), size \(formatBytes(length))")
        } else {
            log?("Auth probe OK for file (HTTP \(http.statusCode))")
        }
    }

    private static func contentLength(from response: HTTPURLResponse) -> Int64? {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let total = parseTotalLength(from: contentRange) {
            return total
        }
        return response.expectedContentLength >= 0 ? response.expectedContentLength : nil
    }

    private static func parseTotalLength(from contentRange: String) -> Int64? {
        guard let slash = contentRange.lastIndex(of: "/") else { return nil }
        return Int64(contentRange[contentRange.index(after: slash)...])
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", Double(bytes) / 1_073_741_824.0)
        }
        if bytes >= 1024 * 1024 {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
        }
        return "\(bytes) B"
    }
}
