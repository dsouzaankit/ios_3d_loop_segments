import CryptoKit
import Foundation

enum PCloudAuth {
    /// pCloud password login: `getdigest` → `userinfo` → auth token (same app password as WebDAV).
    static func fetchAuthToken(
        email: String,
        password: String,
        region: PCloudRegion,
        session: URLSession = .shared
    ) async throws -> String {
        let digest = try await requestDigest(region: region, session: session)
        let passwordDigest = makePasswordDigest(email: email, password: password, digest: digest)
        return try await requestAuthToken(
            email: email,
            passwordDigest: passwordDigest,
            digest: digest,
            region: region,
            session: session
        )
    }

    private static func requestDigest(region: PCloudRegion, session: URLSession) async throws -> String {
        let url = region.apiBaseURL.appendingPathComponent("getdigest")
        let (data, response) = try await session.data(from: url)
        try validateHTTP(response)
        let json = try decodeJSONObject(data)
        try throwIfAPIError(json)
        guard let digest = json["digest"] as? String, !digest.isEmpty else {
            throw PCloudAPIError.unexpectedResponse
        }
        return digest
    }

    private static func requestAuthToken(
        email: String,
        passwordDigest: String,
        digest: String,
        region: PCloudRegion,
        session: URLSession
    ) async throws -> String {
        var components = URLComponents(url: region.apiBaseURL.appendingPathComponent("userinfo"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "getauth", value: "1"),
            URLQueryItem(name: "logout", value: "1"),
            URLQueryItem(name: "username", value: email.lowercased()),
            URLQueryItem(name: "digest", value: digest),
            URLQueryItem(name: "passworddigest", value: passwordDigest),
            URLQueryItem(name: "authexpire", value: "31536000"),
        ]
        guard let url = components.url else { throw PCloudAPIError.unexpectedResponse }
        let (data, response) = try await session.data(from: url)
        try validateHTTP(response)
        let json = try decodeJSONObject(data)
        try throwIfAPIError(json)
        guard let auth = json["auth"] as? String, !auth.isEmpty else {
            throw PCloudAPIError.authenticationFailed(json["error"] as? String)
        }
        return auth
    }

    private static func makePasswordDigest(email: String, password: String, digest: String) -> String {
        let emailLower = email.lowercased()
        let usernameHashHex = sha1Hex(Data(emailLower.utf8))
        var combined = Data(password.utf8)
        combined.append(Data(usernameHashHex.utf8))
        combined.append(Data(digest.utf8))
        return sha1Hex(combined)
    }

    private static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeJSONObject(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw PCloudAPIError.unexpectedResponse
        }
        return dict
    }

    private static func throwIfAPIError(_ json: [String: Any]) throws {
        let code = json["result"] as? Int ?? (json["result"] as? NSNumber)?.intValue ?? -1
        guard code == 0 else {
            throw PCloudAPIError.api(code: code, message: json["error"] as? String)
        }
    }

    private static func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PCloudAPIError.unexpectedResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw PCloudAPIError.httpStatus(http.statusCode)
        }
    }
}
