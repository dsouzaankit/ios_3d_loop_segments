import Foundation

/// Verifies pCloud WebDAV login. US and EU run in parallel; REST API token loads after success.
enum WebDAVSignIn {
    static func verify(credentials: WebDAVCredentials) async throws -> WebDAVCredentials {
        let regions = [credentials.region, credentials.region.alternate]
        SearchDebugLog.log(
            "sign-in: WebDAV parallel — picker=\(credentials.region.rawValue) \(regions.map(\.rawValue).joined(separator: "+"))"
        )

        return try await withThrowingTaskGroup(of: Result<WebDAVCredentials, Error>.self) { group in
            for region in regions {
                group.addTask {
                    var attempt = credentials
                    attempt.region = region
                    do {
                        try await verifyWebDAVAccess(credentials: attempt)
                        return .success(attempt)
                    } catch {
                        logRegionFailure(error, region: region)
                        return .failure(error)
                    }
                }
            }

            var errors: [Error] = []
            for try await result in group {
                switch result {
                case .success(let verified):
                    group.cancelAll()
                    if verified.region != credentials.region {
                        SearchDebugLog.log(
                            "sign-in: WebDAV OK on \(verified.region.rawValue) datacenter (picker was \(credentials.region.rawValue))"
                        )
                    }
                    return verified
                case .failure(let error):
                    errors.append(error)
                }
            }
            throw preferredSignInError(errors)
        }
    }

    /// Browse/export use Depth 1. Depth 0 on this account 404s even for `/p_cld_media/` (build 303 logs).
    private static func verifyWebDAVAccess(credentials: WebDAVCredentials) async throws {
        let client = WebDAVClient(credentials: credentials)
        var paths = await extraListingPaths()
        if !paths.contains("/") {
            paths.append("/")
        }

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

    /// Bookmarks + recent search folders (survives Sign out). Skip `/`.
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

    /// A hung EU probe must not hide a fast US HTTP 404/401.
    private static func preferredSignInError(_ errors: [Error]) -> Error {
        if errors.isEmpty {
            return WebDAVError.httpStatus(401, context: .signIn)
        }
        let http = errors.first { isHTTPStatus($0) }
        if let http { return http }
        return errors[0]
    }

    private static func isHTTPStatus(_ error: Error) -> Bool {
        if case .httpStatus = error as? WebDAVError { return true }
        return false
    }

    private static func logRegionFailure(_ error: Error, region: PCloudRegion) {
        if let error = error as? URLError {
            SearchDebugLog.log(
                "sign-in: network \(error.code.rawValue) on \(region.rawValue) — \(error.localizedDescription)"
            )
        } else if let error = error as? WebDAVError, case .httpStatus(let code, _) = error {
            SearchDebugLog.log("sign-in: HTTP \(code) on \(region.rawValue) (all probe paths)")
        } else {
            SearchDebugLog.log("sign-in: \(error.localizedDescription) on \(region.rawValue)")
        }
    }
}
