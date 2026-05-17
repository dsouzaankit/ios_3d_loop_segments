import Foundation

/// pCloud REST API (search, etc.) using the same credentials as WebDAV.
final class PCloudAPIClient {
    private let credentials: WebDAVCredentials
    private let session: URLSession
    private var authToken: String?
    private var authRegion: PCloudRegion?
    private var authAPIHost: String?

    init(credentials: WebDAVCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    func search(query: String) async throws -> [WebDAVItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let creds = resolvedCredentials()
        let token = try await ensureAuthToken(credentials: creds)
        let apiHost = authAPIHost ?? authRegion?.apiHost ?? creds.region.apiHost
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
            authAPIHost = nil
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
        let (token, region, apiHost) = try await PCloudAuth.fetchAuthSession(
            email: credentials.email,
            password: credentials.password,
            preferredRegion: credentials.region,
            session: session
        )
        authToken = token
        authRegion = region
        authAPIHost = apiHost
        return token
    }

    private func parseSearchItems(_ json: [String: Any]) throws -> [WebDAVItem] {
        let rawItems = PCloudMetadataParsing.extractEntries(from: json)
        var results: [WebDAVItem] = []
        results.reserveCapacity(rawItems.count)
        for entry in rawItems {
            guard let item = PCloudMetadataParsing.webDAVItem(from: entry) else { continue }
            let isFolder = item.isDirectory
            if PCloudMetadataParsing.isBrowsableVideo(name: item.name, metadata: entry, isFolder: isFolder) {
                results.append(item)
            }
        }
        return results.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
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
            pCloud search could not log in with your saved password. \
            Sign out, confirm US/Europe matches my.pcloud.com, and sign in again with the same password you use in the pCloud app. \
            If you use two-factor authentication, pCloud may require a separate security password for API access.
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
