import Foundation

/// Verifies pCloud WebDAV login; tries the other datacenter if the chosen region returns 401.
enum WebDAVSignIn {
    static func verify(credentials: WebDAVCredentials) async throws -> WebDAVCredentials {
        var lastError: Error?
        for region in [credentials.region, credentials.region.alternate] {
            var attempt = credentials
            attempt.region = region
            do {
                let client = WebDAVClient(credentials: attempt)
                _ = try await client.list(path: "/")
                return attempt
            } catch let error as WebDAVError {
                lastError = error
                if case .httpStatus(401) = error { continue }
                throw error
            } catch {
                throw error
            }
        }
        if let lastError { throw lastError }
        throw WebDAVError.httpStatus(401)
    }
}
