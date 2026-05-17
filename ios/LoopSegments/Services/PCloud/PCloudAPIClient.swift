import Foundation

/// pCloud REST API (search, etc.) using the same credentials as WebDAV.
final class PCloudAPIClient {
    private let credentials: WebDAVCredentials
    private let session: URLSession
    private var authToken: String?

    init(credentials: WebDAVCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    func search(query: String) async throws -> [WebDAVItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let token = try await ensureAuthToken()
        var components = URLComponents(url: credentials.region.apiBaseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "auth", value: token),
            URLQueryItem(name: "query", value: trimmed),
        ]
        guard let url = components.url else { throw PCloudAPIError.unexpectedResponse }

        let (data, response) = try await session.data(from: url)
        try Self.validateHTTP(response)
        let json = try Self.decodeJSONObject(data)
        let code = Self.apiResultCode(json)
        if code == 1000 || code == 2000 {
            authToken = nil
            let retryToken = try await ensureAuthToken()
            var retry = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            retry.queryItems = [
                URLQueryItem(name: "auth", value: retryToken),
                URLQueryItem(name: "query", value: trimmed),
            ]
            guard let retryURL = retry.url else { throw PCloudAPIError.unexpectedResponse }
            let (retryData, retryResponse) = try await session.data(from: retryURL)
            try Self.validateHTTP(retryResponse)
            return try parseSearchItems(Self.decodeJSONObject(retryData))
        }
        try Self.throwIfAPIError(json)
        return try parseSearchItems(json)
    }

    private func ensureAuthToken() async throws -> String {
        if let authToken, !authToken.isEmpty { return authToken }
        let token = try await PCloudAuth.fetchAuthToken(
            email: credentials.email,
            password: credentials.password,
            region: credentials.region,
            session: session
        )
        authToken = token
        return token
    }

    private func parseSearchItems(_ json: [String: Any]) throws -> [WebDAVItem] {
        let rawItems: [[String: Any]]
        if let items = json["items"] as? [[String: Any]] {
            rawItems = items
        } else if let metadata = json["metadata"] as? [[String: Any]] {
            rawItems = metadata
        } else {
            rawItems = []
        }

        var results: [WebDAVItem] = []
        results.reserveCapacity(rawItems.count)
        for entry in rawItems {
            guard let item = Self.webDAVItem(from: entry) else { continue }
            if item.isDirectory || item.isVideo {
                results.append(item)
            }
        }
        return results.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func webDAVItem(from metadata: [String: Any]) -> WebDAVItem? {
        guard let name = metadata["name"] as? String, !name.isEmpty else { return nil }
        let isFolder = metadata["isfolder"] as? Bool ?? false
        guard let path = metadata["path"] as? String, !path.isEmpty else { return nil }

        let href = isFolder
            ? WebDAVURLBuilder.directoryListingPath(path)
            : WebDAVURLBuilder.canonicalBrowsePath(path)
        let size = int64Field(metadata["size"])
        return WebDAVItem(href: href, name: name, isDirectory: isFolder, contentLength: size)
    }

    private static func int64Field(_ value: Any?) -> Int64? {
        switch value {
        case let n as Int64: return n
        case let n as Int: return Int64(n)
        case let n as NSNumber: return n.int64Value
        default: return nil
        }
    }

    private static func apiResultCode(_ json: [String: Any]) -> Int {
        if let code = json["result"] as? Int { return code }
        if let code = json["result"] as? NSNumber { return code.intValue }
        return -1
    }

    private static func throwIfAPIError(_ json: [String: Any]) throws {
        let code = apiResultCode(json)
        guard code == 0 else {
            throw PCloudAPIError.api(code: code, message: json["error"] as? String)
        }
    }

    private static func decodeJSONObject(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw PCloudAPIError.unexpectedResponse
        }
        return dict
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

enum PCloudAPIError: LocalizedError {
    case unexpectedResponse
    case httpStatus(Int)
    case api(code: Int, message: String?)
    case authenticationFailed(String?)

    var errorDescription: String? {
        switch self {
        case .unexpectedResponse:
            return "Unexpected pCloud API response."
        case .httpStatus(let code):
            return "pCloud API HTTP \(code)."
        case .api(let code, let message):
            if let message, !message.isEmpty {
                return "pCloud error \(code): \(message)"
            }
            return "pCloud error \(code)."
        case .authenticationFailed(let message):
            if let message, !message.isEmpty {
                return "pCloud sign-in failed: \(message)"
            }
            return "pCloud sign-in failed. Use the same app password as WebDAV."
        }
    }
}
