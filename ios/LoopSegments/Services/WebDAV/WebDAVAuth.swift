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

    /// Basic auth from `user:pass` embedded in the URL, otherwise empty (omit Authorization header).
    static func providerForExternalURL(_ url: URL) -> WebDAVAuthorizationProvider {
        {
            guard let user = url.user, let password = url.password else { return "" }
            let token = Data("\(user):\(password)".utf8).base64EncodedString()
            return "Basic \(token)"
        }
    }

    static func applyAuthorization(_ authorization: String, to request: inout URLRequest) {
        let trimmed = authorization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        request.setValue(trimmed, forHTTPHeaderField: "Authorization")
    }
}

enum WebDAVAccessProbe {
    /// HEAD probe; on 404 re-lists the parent folder and reconciles rename so export can use the new `href`.
    static func resolveMediaURL(
        for item: WebDAVItem,
        credentials: WebDAVCredentials,
        authorization: WebDAVAuthorizationProvider,
        log: ((String) -> Void)? = nil
    ) async throws -> (URL, WebDAVItem) {
        let url = item.mediaURL(credentials: credentials)
        if item.isExternalHTTPMedia(credentials: credentials) {
            let externalAuth = WebDAVAuth.providerForExternalURL(url)
            log?("External HTTP(S) media — skipping pCloud PROPFIND rename probe")
            try await verifyMediaURL(url, authorization: externalAuth, log: log)
            return (url, item)
        }
        do {
            try await verifyMediaURL(url, authorization: authorization, log: log)
            return (url, item)
        } catch let error as WebDAVResourceLoaderError {
            guard case .httpStatus(404) = error,
                  let parentPath = WebDAVRenameReconcile.parentBrowsePath(forFileHref: item.href) else {
                throw error
            }
            log?("File not found at stored path — re-listing \(parentPath) after pCloud rename…")
            let client = WebDAVClient(credentials: credentials)
            let listing = try await client.list(path: parentPath)
            await MainActor.run {
                ResumeStore.shared.reconcileWithBrowseListing(listing)
            }
            let entry = ResumeEntry(
                fileKey: item.fileKey,
                displayName: item.name,
                href: item.href,
                lastSeekMs: 0,
                updatedAt: Date()
            )
            let videos = listing.filter(\.isVideo)
            guard let match = WebDAVRenameReconcile.matchResumeEntry(entry, in: videos) else {
                throw error
            }
            let repairedURL = match.mediaURL(credentials: credentials)
            try await verifyMediaURL(repairedURL, authorization: authorization, log: log)
            log?("Using renamed file on pCloud — \(match.name)")
            return (repairedURL, match)
        }
    }

    static func verifyMediaURL(
        _ url: URL,
        authorization: WebDAVAuthorizationProvider,
        log: ((String) -> Void)? = nil
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        WebDAVAuth.applyAuthorization(authorization(), to: &request)

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
