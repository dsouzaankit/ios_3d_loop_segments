import Foundation

/// Verifies pCloud login: fast REST probe (US+EU parallel), then WebDAV on the winning region.
enum WebDAVSignIn {
    static func verify(credentials: WebDAVCredentials) async throws -> WebDAVCredentials {
        SearchDebugLog.log("sign-in: start — picker=\(credentials.region.rawValue)")

        var enriched = credentials
        if let apiHit = try? await apiQuickProbe(credentials) {
            enriched.region = apiHit.region
            enriched.apiAuthToken = apiHit.token
            enriched.apiAuthHost = apiHit.apiHost
            SearchDebugLog.log(
                "sign-in: API OK region=\(apiHit.region.rawValue) host=\(apiHit.apiHost) — verifying WebDAV"
            )
            do {
                try await verifyWebDAVAccess(credentials: enriched)
                return enriched
            } catch {
                SearchDebugLog.log(
                    "sign-in: WebDAV failed on API region \(apiHit.region.rawValue) — \(error.localizedDescription)"
                )
            }
        } else {
            SearchDebugLog.log("sign-in: API probe failed or skipped — WebDAV-only (2FA / no API token is OK)")
        }

        return try await verifyWebDAVParallel(credentials: enriched)
    }

    private static func apiQuickProbe(
        _ credentials: WebDAVCredentials
    ) async throws -> (token: String, region: PCloudRegion, apiHost: String) {
        try await PCloudAuth.quickSignInSession(
            email: credentials.email,
            password: credentials.password,
            preferredRegion: credentials.region
        )
    }

    private static func verifyWebDAVParallel(credentials: WebDAVCredentials) async throws -> WebDAVCredentials {
        let regions = [credentials.region, credentials.region.alternate]
        SearchDebugLog.log(
            "sign-in: WebDAV parallel — \(regions.map(\.rawValue).joined(separator: "+"))"
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

            var lastError: Error?
            for try await result in group {
                switch result {
                case .success(let verified):
                    group.cancelAll()
                    if verified.region != credentials.region {
                        SearchDebugLog.log(
                            "sign-in: WebDAV OK on \(verified.region.rawValue) datacenter (picker was \(credentials.region.rawValue))"
                        )
                    }
                    var merged = verified
                    if let token = credentials.apiAuthToken, !token.isEmpty {
                        merged.apiAuthToken = token
                        merged.apiAuthHost = credentials.apiAuthHost
                    }
                    return merged
                case .failure(let error):
                    lastError = error
                }
            }
            if let lastError { throw lastError }
            throw WebDAVError.httpStatus(401, context: .signIn)
        }
    }

    /// Depth-0 PROPFIND on `/` can 404 even when a root list works; fall back before failing sign-in.
    private static func verifyWebDAVAccess(credentials: WebDAVCredentials) async throws {
        let client = WebDAVClient(credentials: credentials)
        do {
            try await client.verifyAccess(path: "/", context: .signIn)
            return
        } catch let error as WebDAVError {
            if case .httpStatus(let code, _) = error, code == 404 {
                _ = try await client.list(path: "/", context: .signIn)
                SearchDebugLog.log(
                    "sign-in: WebDAV root list OK on \(credentials.region.rawValue) after PROPFIND 404 on /"
                )
                return
            }
            throw error
        }
    }

    private static func logRegionFailure(_ error: Error, region: PCloudRegion) {
        if let error = error as? URLError {
            SearchDebugLog.log(
                "sign-in: network \(error.code.rawValue) on \(region.rawValue) — \(error.localizedDescription)"
            )
        } else if let error = error as? WebDAVError, case .httpStatus(let code, _) = error {
            SearchDebugLog.log("sign-in: HTTP \(code) on \(region.rawValue)")
        }
    }
}
