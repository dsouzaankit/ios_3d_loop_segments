import Foundation

/// pCloud REST API (search, etc.) using the same credentials as WebDAV.
final class PCloudAPIClient {
    private let credentials: WebDAVCredentials
    private let session: URLSession
    private var authToken: String?
    private var authRegion: PCloudRegion?

    init(credentials: WebDAVCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    func search(query: String) async throws -> [WebDAVItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let creds = resolvedCredentials()
        let token = try await ensureAuthToken(credentials: creds)
        let apiHost = authRegion?.apiHost ?? creds.region.apiHost
        let json = try await PCloudAPIRequest.get(
            host: apiHost,
            method: "search",
            parameters: [
                "auth": token,
                "query": trimmed,
            ],
            session: session
        )

        let code = PCloudAPIRequest.resultCode(json)
        if code == 1000 || code == 2000 {
            authToken = nil
            let retryToken = try await ensureAuthToken(credentials: creds)
            let retryJSON = try await PCloudAPIRequest.get(
                host: apiHost,
                method: "search",
                parameters: [
                    "auth": retryToken,
                    "query": trimmed,
                ],
                session: session
            )
            try PCloudAPIRequest.throwIfAPIError(retryJSON)
            return try parseSearchItems(retryJSON)
        }

        try PCloudAPIRequest.throwIfAPIError(json)
        return try parseSearchItems(json)
    }

    private func resolvedCredentials() -> WebDAVCredentials {
        let store = CredentialStore()
        if let loaded = store.load(account: credentials.email),
           loaded.region == credentials.region,
           !loaded.password.isEmpty {
            return loaded
        }
        return credentials
    }

    private func ensureAuthToken(credentials: WebDAVCredentials) async throws -> String {
        if let authToken, !authToken.isEmpty { return authToken }
        let (token, region) = try await PCloudAuth.fetchAuthSession(
            email: credentials.email,
            password: credentials.password,
            preferredRegion: credentials.region,
            session: session
        )
        authToken = token
        authRegion = region
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
            return Self.describeAPI(code: code, message: message)
        case .authenticationFailed(let message):
            if let message, !message.isEmpty {
                return "pCloud sign-in failed: \(message)"
            }
            return Self.describeAPI(code: 2000, message: nil)
        }
    }

    private static func describeAPI(code: Int, message: String?) -> String {
        let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch code {
        case 2000:
            return """
            pCloud search login failed (use the same app password as WebDAV). \
            Check US/Europe region matches your account at my.pcloud.com. \
            If WebDAV works but search still fails, create a new app password (Settings → Security).
            \(detail.isEmpty ? "" : " (\(detail))")
            """
        case 1000:
            return "pCloud search requires login — sign out and sign in again."
        default:
            if !detail.isEmpty {
                return "pCloud error \(code): \(detail)"
            }
            return "pCloud error \(code)."
        }
    }
}
