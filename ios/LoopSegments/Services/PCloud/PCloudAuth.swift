import CryptoKit
import Foundation

enum PCloudAuth {
    private static let authExpireSeconds = "31536000"
    private static let authInactiveExpireSeconds = "2592000"
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
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !trimmedPassword.isEmpty else {
            throw PCloudAPIError.authenticationFailed("Email and password are required.")
        }

        let usernames = uniqueUsernames(trimmedEmail)
        var lastError: Error?
        for region in [preferredRegion, preferredRegion.alternate] {
            let hosts = await PCloudAPIHostResolver.hostsToTry(for: region, session: session)
            for host in hosts {
                for username in usernames {
                    do {
                        let token = try await requestAuthTokenPlain(
                            username: username,
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
                            username: username.lowercased(),
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
        }

        if let lastError {
            throw lastError
        }
        throw PCloudAPIError.authenticationFailed(nil)
    }

    private static func uniqueUsernames(_ email: String) -> [String] {
        let lower = email.lowercased()
        if lower == email {
            return [email]
        }
        return [email, lower]
    }

    private static func requestAuthTokenPlain(
        username: String,
        password: String,
        apiHost: String,
        session: URLSession
    ) async throws -> String {
        var lastError: Error?
        for parameters in plainAuthParameterSets(username: username, password: password) {
            let style = parameters["logout"] == nil ? "plain" : "plain-logout"
            do {
                let json = try await PCloudAPIRequest.get(
                    host: apiHost,
                    method: "userinfo",
                    parameters: parameters,
                    session: session
                )
                return try parseAuthToken(from: json, apiHost: apiHost, style: style)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? PCloudAPIError.authenticationFailed(nil)
    }

    private static func requestAuthTokenDigest(
        username: String,
        password: String,
        apiHost: String,
        session: URLSession
    ) async throws -> String {
        let digestJSON = try await PCloudAPIRequest.get(host: apiHost, method: "getdigest", session: session)
        try PCloudAPIRequest.throwIfAPIError(digestJSON)
        guard let digest = digestJSON["digest"] as? String, !digest.isEmpty else {
            throw PCloudAPIError.unexpectedResponse
        }

        let passwordDigest = makePasswordDigest(email: username, password: password, digest: digest)
        var lastError: Error?
        for parameters in digestAuthParameterSets(
            username: username,
            digest: digest,
            passwordDigest: passwordDigest
        ) {
            let style = parameters["logout"] == nil ? "digest" : "digest-logout"
            do {
                let json = try await PCloudAPIRequest.get(
                    host: apiHost,
                    method: "userinfo",
                    parameters: parameters,
                    session: session
                )
                return try parseAuthToken(from: json, apiHost: apiHost, style: style)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? PCloudAPIError.authenticationFailed(nil)
    }

    private static func plainAuthParameterSets(username: String, password: String) -> [[String: String]] {
        [
            baseAuthParameters(username: username, password: password, includeLogout: false),
            baseAuthParameters(username: username, password: password, includeLogout: true),
        ]
    }

    private static func digestAuthParameterSets(
        username: String,
        digest: String,
        passwordDigest: String
    ) -> [[String: String]] {
        [
            baseAuthParameters(
                username: username,
                digest: digest,
                passwordDigest: passwordDigest,
                includeLogout: false
            ),
            baseAuthParameters(
                username: username,
                digest: digest,
                passwordDigest: passwordDigest,
                includeLogout: true
            ),
        ]
    }

    private static func baseAuthParameters(
        username: String,
        password: String? = nil,
        digest: String? = nil,
        passwordDigest: String? = nil,
        includeLogout: Bool
    ) -> [String: String] {
        var parameters: [String: String] = [
            "getauth": "1",
            "username": username,
            "authexpire": authExpireSeconds,
            "authinactiveexpire": authInactiveExpireSeconds,
            "device": deviceName,
        ]
        if includeLogout {
            parameters["logout"] = "1"
        }
        if let password {
            parameters["password"] = password
        }
        if let digest, let passwordDigest {
            parameters["digest"] = digest
            parameters["passworddigest"] = passwordDigest
        }
        return parameters
    }

    private static func parseAuthToken(from json: [String: Any], apiHost: String, style: String) throws -> String {
        let code = PCloudAPIRequest.resultCode(json)
        if code == 0, let auth = extractAuthToken(json) {
            SearchDebugLog.log("auth ok host=\(apiHost) style=\(style) tokenLen=\(auth.count)")
            return auth
        }
        if code == 0 {
            let keys = Array(json.keys).sorted().joined(separator: ",")
            let userid = json["userid"].map { "\($0)" } ?? "-"
            SearchDebugLog.log(
                "auth host=\(apiHost) style=\(style) result=0 but no auth — keys=[\(keys)] userid=\(userid)"
            )
            throw PCloudAPIError.authenticationFailed(missingTokenMessage(json))
        }
        throw PCloudAPIError.api(code: code, message: PCloudAPIRequest.errorMessage(json))
    }

    private static func extractAuthToken(_ json: [String: Any]) -> String? {
        for key in ["auth", "authtoken", "token"] {
            if let value = json[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func missingTokenMessage(_ json: [String: Any]) -> String {
        if let apiMessage = PCloudAPIRequest.errorMessage(json), !apiMessage.isEmpty {
            return apiMessage
        }
        return """
        pCloud accepted login but returned no API token. Sign out, pick the correct US/Europe region, and sign in again. \
        If you use two-factor authentication, create an app password in pCloud settings and use that here instead of your main password.
        """
    }

    private static func makePasswordDigest(email: String, password: String, digest: String) -> String {
        let usernameHashHex = sha1Hex(Data(email.lowercased().utf8))
        var combined = Data(password.utf8)
        combined.append(Data(usernameHashHex.utf8))
        combined.append(Data(digest.utf8))
        return sha1Hex(combined)
    }

    private static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
