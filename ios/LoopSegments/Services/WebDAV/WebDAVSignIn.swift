import Foundation

/// Verifies pCloud WebDAV login; tries the other datacenter if the chosen region returns 401/404.
enum WebDAVSignIn {
    private static let probePaths = ["/", "/remote.php/dav/"]

    static func verify(credentials: WebDAVCredentials) async throws -> WebDAVCredentials {
        var lastError: Error?
        for region in [credentials.region, credentials.region.alternate] {
            var attempt = credentials
            attempt.region = region
            do {
                try await verifyWebDAVAccess(credentials: attempt)
                if attempt.region != credentials.region {
                    SearchDebugLog.log(
                        "sign-in: WebDAV OK on \(attempt.region.rawValue) datacenter (picker was \(credentials.region.rawValue))"
                    )
                }
                return attempt
            } catch let error as WebDAVError {
                lastError = error
                if case .httpStatus(let code, _) = error, code == 401 || code == 404 { continue }
                throw error
            } catch let error as URLError {
                SearchDebugLog.log(
                    "sign-in: network \(error.code.rawValue) on \(attempt.region.rawValue) — \(error.localizedDescription)"
                )
                lastError = error
                continue
            } catch {
                throw error
            }
        }
        if let lastError { throw lastError }
        throw WebDAVError.httpStatus(401, context: .signIn)
    }

    /// Depth-0 PROPFIND on `/` can 404 even when a root list works; fall back before failing sign-in.
    private static func verifyWebDAVAccess(credentials: WebDAVCredentials) async throws {
        let client = WebDAVClient(credentials: credentials)
        var lastPathError: Error?
        for path in probePaths {
            do {
                try await client.verifyAccess(path: path, context: .signIn)
                return
            } catch let error as WebDAVError {
                lastPathError = error
                if case .httpStatus(let code, _) = error, code == 404 { continue }
                throw error
            }
        }
        do {
            _ = try await client.list(path: "/", context: .signIn)
            SearchDebugLog.log("sign-in: WebDAV root list OK after PROPFIND 404 on \(probePaths.joined(separator: ", "))")
            return
        } catch {
            if let lastPathError { throw lastPathError }
            throw error
        }
    }
}
