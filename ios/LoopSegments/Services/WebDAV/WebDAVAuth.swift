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
        log?("Auth probe OK for file (HTTP \(http.statusCode))")
    }
}
