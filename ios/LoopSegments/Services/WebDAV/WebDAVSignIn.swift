import Foundation

/// Verifies pCloud WebDAV. Picker region only — EU timeout must not block Sign in after a US HTTP 404.
enum WebDAVSignIn {
    static func verify(credentials: WebDAVCredentials) async throws -> WebDAVCredentials {
        SearchDebugLog.log("sign-in: WebDAV picker=\(credentials.region.rawValue) (no EU wait)")
        var attempt = credentials
        try await verifyWebDAVAccess(credentials: attempt)
        return attempt
    }

    private static func verifyWebDAVAccess(credentials: WebDAVCredentials) async throws {
        let client = WebDAVClient(credentials: credentials)
        var paths = await extraListingPaths()
        if paths.isEmpty { paths = ["/"] }

        var lastError: Error?
        for path in paths {
            do {
                let items = try await client.list(path: path, context: .signIn)
                SearchDebugLog.log(
                    "sign-in: WebDAV OK on \(credentials.region.rawValue) list \(path) (\(items.count) item(s))"
                )
                return
            } catch let error as WebDAVError {
                lastError = error
                if case .httpStatus(let code, _) = error {
                    SearchDebugLog.log(
                        "sign-in: HTTP \(code) on \(credentials.region.rawValue) list \(path)"
                    )
                    if code == 404 { continue }
                }
                throw error
            }
        }
        if let lastError { throw lastError }
        throw WebDAVError.httpStatus(404, context: .signIn)
    }

    private static func extraListingPaths() async -> [String] {
        let bookmarks = await MainActor.run {
            FolderBookmarkStore.shared.bookmarks().map(\.listingPath)
        }
        var seen = Set<String>()
        var out: [String] = []
        for path in bookmarks + SearchLocationCache.listingPaths() {
            let normalized = WebDAVURLBuilder.directoryListingPath(path)
            if normalized == "/" || seen.contains(normalized) { continue }
            seen.insert(normalized)
            out.append(normalized)
            if out.count >= 6 { break }
        }
        if !out.isEmpty {
            SearchDebugLog.log("sign-in: extra WebDAV paths \(out.joined(separator: ", "))")
        }
        return out
    }
}
