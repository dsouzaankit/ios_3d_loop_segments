import CryptoKit
import Foundation

enum PCloudAuth {
    private static let authExpireSeconds = "31536000"
    private static let deviceName = "LoopSegments-iOS"

    /// Verifies REST API login (search). Returns the datacenter that accepted the password.
    static func verifyAPIAccess(
        credentials: WebDAVCredentials,
        session: URLSession = .shared
    ) async throws -> PCloudRegion {
        let (_, region, _) = try await fetchAuthSession(
            email: credentials.email,
            password: credentials.password,
            preferredRegion: credentials.region,
            session: session
        )
        return region
    }

    /// pCloud REST token — plain password over HTTPS first, then digest; tries regional + nearest API hosts.
    static func fetchAuthToken(
        email: String,
        password: String,
        region: PCloudRegion,
        session: URLSession = .shared
    ) async throws -> String {
        let (token, _, _) = try await fetchAuthSession(
            email: email,
            password: password,
            preferredRegion: region,
            session: session
        )
        return token
    }

    static func fetchAuthSession(
        email: String,
        password: String,
        preferredRegion: PCloudRegion,
        session: URLSession
    ) async throws -> (token: String, region: PCloudRegion, apiHost: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !trimmedPassword.isEmpty else {
            throw PCloudAPIError.authenticationFailed("Email and password are required.")
        }

        var lastError: Error?
        for region in [preferredRegion, preferredRegion.alternate] {
            let hosts = await PCloudAPIHostResolver.hostsToTry(for: region, session: session)
            for host in hosts {
                do {
                    let token = try await requestAuthTokenPlain(
                        email: trimmedEmail,
                        password: trimmedPassword,
                        apiHost: host,
                        session: session
                    )
                    return (token, region, host)
                } catch {
                    lastError = error
                }
                do {
                    let token = try await requestAuthTokenDigest(
                        email: trimmedEmail,
                        password: trimmedPassword,
                        apiHost: host,
                        session: session
                    )
                    return (token, region, host)
                } catch {
                    lastError = error
                }
            }
        }

        if let lastError {
            throw lastError
        }
        throw PCloudAPIError.authenticationFailed(nil)
    }

    private static func requestAuthTokenPlain(
        email: String,
        password: String,
        apiHost: String,
        session: URLSession
    ) async throws -> String {
        let json = try await PCloudAPIRequest.get(
            host: apiHost,
            method: "userinfo",
            parameters: [
                "getauth": "1",
                "logout": "1",
                "username": email,
                "password": password,
                "authexpire": authExpireSeconds,
                "device": deviceName,
            ],
            session: session
        )
        return try parseAuthToken(from: json)
    }

    private static func requestAuthTokenDigest(
        email: String,
        password: String,
        apiHost: String,
        session: URLSession
    ) async throws -> String {
        let digestJSON = try await PCloudAPIRequest.get(host: apiHost, method: "getdigest", session: session)
        try PCloudAPIRequest.throwIfAPIError(digestJSON)
        guard let digest = digestJSON["digest"] as? String, !digest.isEmpty else {
            throw PCloudAPIError.unexpectedResponse
        }

        let passwordDigest = makePasswordDigest(email: email, password: password, digest: digest)
        let json = try await PCloudAPIRequest.get(
            host: apiHost,
            method: "userinfo",
            parameters: [
                "getauth": "1",
                "logout": "1",
                "username": email,
                "digest": digest,
                "passworddigest": passwordDigest,
                "authexpire": authExpireSeconds,
                "device": deviceName,
            ],
            session: session
        )
        return try parseAuthToken(from: json)
    }

    private static func parseAuthToken(from json: [String: Any]) throws -> String {
        let code = PCloudAPIRequest.resultCode(json)
        if code == 0, let auth = json["auth"] as? String, !auth.isEmpty {
            return auth
        }
        throw PCloudAPIError.api(code: code, message: PCloudAPIRequest.errorMessage(json))
    }

    private static func makePasswordDigest(email: String, password: String, digest: String) -> String {
        let usernameHashHex = sha1Hex(Data(email.utf8))
        var combined = Data(password.utf8)
        combined.append(Data(usernameHashHex.utf8))
        combined.append(Data(digest.utf8))
        return sha1Hex(combined)
    }

    private static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
