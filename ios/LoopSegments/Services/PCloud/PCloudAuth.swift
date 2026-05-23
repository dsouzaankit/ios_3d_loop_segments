import CryptoKit
import Foundation

enum PCloudAuth {
    private static let authExpireSeconds = "31536000"
    private static let authInactiveExpireSeconds = "2592000"
    private static let deviceName = "LoopSegments-iOS"

    /// No cookie jar — avoids `userinfo` returning a profile without a new `auth` token from a stale session.
    private static let authSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Verifies REST API login (search). Returns the datacenter that accepted the password.
    static func verifyAPIAccess(
        credentials: WebDAVCredentials,
        session: URLSession = authSession
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
        session: URLSession = authSession
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
        session: URLSession = authSession
    ) async throws -> (token: String, region: PCloudRegion, apiHost: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !trimmedPassword.isEmpty else {
            throw PCloudAPIError.authenticationFailed("Email and password are required.")
        }

        let usernames = uniqueUsernames(trimmedEmail)
        var lastError: Error?

        // Fast path: regional API host only (skips getapiserver discovery round-trips).
        for username in usernames {
            if let hit = try? await tryAuthOnHost(
                username: username,
                password: trimmedPassword,
                region: preferredRegion,
                apiHost: preferredRegion.apiHost,
                session: session
            ) {
                return hit
            }
        }

        for region in [preferredRegion, preferredRegion.alternate] {
            let hosts = await PCloudAPIHostResolver.hostsToTry(for: region, session: session)
            for host in hosts {
                if region == preferredRegion, host == preferredRegion.apiHost {
                    continue
                }
                for username in usernames {
                    do {
                        return try await tryAuthOnHost(
                            username: username,
                            password: trimmedPassword,
                            region: region,
                            apiHost: host,
                            session: session
                        )
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

    private static func tryAuthOnHost(
        username: String,
        password: String,
        region: PCloudRegion,
        apiHost: String,
        session: URLSession
    ) async throws -> (token: String, region: PCloudRegion, apiHost: String) {
        do {
            let token = try await requestAuthTokenPlain(
                username: username,
                password: password,
                apiHost: apiHost,
                session: session
            )
            return (token, region, apiHost)
        } catch {
            let token = try await requestAuthTokenDigest(
                username: username.lowercased(),
                password: password,
                apiHost: apiHost,
                session: session
            )
            return (token, region, apiHost)
        }
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
            baseAuthParameters(username: username, password: password, includeLogout: true),
            baseAuthParameters(username: username, password: password, includeLogout: false),
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
                includeLogout: true
            ),
            baseAuthParameters(
                username: username,
                digest: digest,
                passwordDigest: passwordDigest,
                includeLogout: false
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
        for key in ["auth", "authtoken", "token", "access_token"] {
            if let value = json[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let value = json[key] as? NSNumber {
                let text = value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    /// `result=0` with `userid` but no `auth` — password often works for WebDAV but API search token is blocked.
    private static func isProfileWithoutAuthToken(_ json: [String: Any]) -> Bool {
        PCloudAPIRequest.resultCode(json) == 0
            && extractAuthToken(json) == nil
            && json["userid"] != nil
    }

    private static func missingTokenMessage(_ json: [String: Any]) -> String {
        if let apiMessage = PCloudAPIRequest.errorMessage(json), !apiMessage.isEmpty {
            return apiMessage
        }
        if isProfileWithoutAuthToken(json) {
            return """
            pCloud returned your account profile but no API search token (WebDAV can still work). \
            Sign out, confirm US vs Europe matches my.pCloud, then sign in again. \
            If two-factor authentication (2FA) is on, pCloud often blocks third-party API tokens — try disabling 2FA temporarily, \
            or use an app-specific password from pCloud Security settings if your account offers one.
            """
        }
        return """
        pCloud login did not return an API token. Sign out, pick the correct US/Europe region, and sign in again.
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
