import Foundation

/// Verifies pCloud WebDAV login; tries US and EU in parallel when the picker region fails.
enum WebDAVSignIn {
    static func verify(credentials: WebDAVCredentials) async throws -> WebDAVCredentials {
        let regions = [credentials.region, credentials.region.alternate]
        SearchDebugLog.log(
            "sign-in: WebDAV probe start — picker=\(credentials.region.rawValue), parallel=\(regions.map(\.rawValue).joined(separator: "+"))"
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
                    return verified
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
