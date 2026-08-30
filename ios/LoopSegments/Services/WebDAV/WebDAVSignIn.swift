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

    /// pCloud often 404s Depth-0 on `/` even when `/remote.php/dav/` works (build 296 probes).
    private static func verifyWebDAVAccess(credentials: WebDAVCredentials) async throws {
        let client = WebDAVClient(credentials: credentials)
        let email = credentials.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = email.lowercased()
        var paths = [
            "/",
            "/remote.php/dav/",
            "/remote.php/dav/files/\(lower)/",
        ]
        if lower != email {
            paths.append("/remote.php/dav/files/\(email)/")
        }
        // Yesterday’s session listed /p_cld_media/… — pCloud often 404s on `/` even when those folders work.
        paths.append(contentsOf: await extraListingPaths())

        var lastError: Error?
        for path in paths {
            do {
                try await client.verifyAccess(path: path, context: .signIn)
                if path != "/" {
                    SearchDebugLog.log("sign-in: WebDAV OK on \(credentials.region.rawValue) path=\(path)")
                }
                return
            } catch let error as WebDAVError {
                lastError = error
                if case .httpStatus(let code, _) = error, code == 404 {
                    SearchDebugLog.log("sign-in: HTTP 404 on \(credentials.region.rawValue) path=\(path)")
                    continue
                }
                throw error
            }
        }
        do {
            _ = try await client.list(path: "/", context: .signIn)
            SearchDebugLog.log("sign-in: WebDAV root list OK on \(credentials.region.rawValue) after PROPFIND 404")
            return
        } catch {
            if let lastError { throw lastError }
            throw error
        }
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
