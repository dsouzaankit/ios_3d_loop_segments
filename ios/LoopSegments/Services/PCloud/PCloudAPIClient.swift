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
        if let saved = credentials.apiAuthToken, !saved.isEmpty {
            authToken = saved
            authAPIHost = credentials.apiAuthHost
            authRegion = credentials.region
        }
    }

    struct SearchDiagnostics {
        let rawEntryCount: Int
        let resolvedCount: Int
    }

    func search(query: String) async throws -> ([WebDAVItem], SearchDiagnostics) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ([], SearchDiagnostics(rawEntryCount: 0, resolvedCount: 0))
        }

        let creds = resolvedCredentials()
        let json = try await performSearch(query: trimmed, credentials: creds)
        try PCloudAPIRequest.throwIfAPIError(json)
        let raw = PCloudMetadataParsing.extractEntries(from: json)
        let items = try await PCloudPathResolver.resolveSearchItems(
            entries: raw,
            credentials: creds,
            apiClient: self
        )
        return (items, SearchDiagnostics(rawEntryCount: raw.count, resolvedCount: items.count))
    }

    func listFolderContents(folderId: Int64) async throws -> [[String: Any]] {
        let creds = resolvedCredentials()
        let token = try await ensureAuthToken(credentials: creds)
        let host = authAPIHost ?? authRegion?.apiHost ?? creds.region.apiHost
        let json = try await PCloudAPIRequest.get(
            host: host,
            method: "listfolder",
            parameters: [
                "auth": token,
                "folderid": "\(folderId)",
            ],
            session: session
        )
        try PCloudAPIRequest.throwIfAPIError(json)
        guard let metadata = json["metadata"] as? [String: Any],
              let contents = metadata["contents"] as? [[String: Any]] else {
            return []
        }
        return PCloudMetadataParsing.flattenFolderContents(contents)
    }

    func apiPath(fileId: Int64) async throws -> String? {
        let creds = resolvedCredentials()
        let token = try await ensureAuthToken(credentials: creds)
        let host = authAPIHost ?? authRegion?.apiHost ?? creds.region.apiHost
        let json = try await PCloudAPIRequest.get(
            host: host,
            method: "getpath",
            parameters: ["auth": token, "fileid": "\(fileId)"],
            session: session
        )
        guard PCloudAPIRequest.resultCode(json) == 0 else { return nil }
        return normalizedAPIPath(json["path"])
    }

    func apiPath(folderId: Int64) async throws -> String? {
        let creds = resolvedCredentials()
        let token = try await ensureAuthToken(credentials: creds)
        let host = authAPIHost ?? authRegion?.apiHost ?? creds.region.apiHost
        let json = try await PCloudAPIRequest.get(
            host: host,
            method: "getpath",
            parameters: ["auth": token, "folderid": "\(folderId)"],
            session: session
        )
        guard PCloudAPIRequest.resultCode(json) == 0 else { return nil }
        return normalizedAPIPath(json["path"])
    }

    private func performSearch(query: String, credentials: WebDAVCredentials) async throws -> [String: Any] {
        let token = try await ensureAuthToken(credentials: credentials)
        let hosts = await searchHostsToTry(credentials: credentials)
        var lastJSON: [String: Any]?
        var lastCode = -1

        for host in hosts {
            for includeSearchAll in [true, false] {
                var parameters: [String: String] = [
                    "auth": token,
                    "query": query,
                ]
                if includeSearchAll {
                    parameters["searchall"] = "1"
                }
                let json = try await PCloudAPIRequest.get(
                    host: host,
                    method: "search",
                    parameters: parameters,
                    session: session
                )
                let code = PCloudAPIRequest.resultCode(json)
                if code == 1000 || code == 2000 {
                    authToken = nil
                    authAPIHost = nil
                    let retryToken = try await ensureAuthToken(credentials: credentials)
                    parameters["auth"] = retryToken
                    let retryJSON = try await PCloudAPIRequest.get(
                        host: host,
                        method: "search",
                        parameters: parameters,
                        session: session
                    )
                    let retryCode = PCloudAPIRequest.resultCode(retryJSON)
                    if retryCode == 0 {
                        authAPIHost = host
                        return retryJSON
                    }
                    lastJSON = retryJSON
                    lastCode = retryCode
                    break
                }
                if code == 0 {
                    authAPIHost = host
                    return json
                }
                lastJSON = json
                lastCode = code
            }
        }

        if let lastJSON {
            return lastJSON
        }
        throw PCloudAPIError.api(code: lastCode, message: nil)
    }

    private func searchHostsToTry(credentials: WebDAVCredentials) async -> [String] {
        var hosts: [String] = []
        if let saved = credentials.apiAuthHost, !saved.isEmpty {
            hosts.append(saved)
        }
        if let authAPIHost, !authAPIHost.isEmpty {
            hosts.append(authAPIHost)
        }
        let resolved = await PCloudAPIHostResolver.hostsToTry(for: credentials.region, session: session)
        hosts.append(contentsOf: resolved)
        var seen = Set<String>()
        return hosts.filter { seen.insert($0).inserted }
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
        persistAuthSession(token: token, region: region, apiHost: apiHost, credentials: credentials)
        return token
    }

    private func persistAuthSession(
        token: String,
        region: PCloudRegion,
        apiHost: String,
        credentials: WebDAVCredentials
    ) {
        var updated = credentials
        updated.region = region
        updated.apiAuthToken = token
        updated.apiAuthHost = apiHost
        CredentialStore().save(updated)
    }

    private func normalizedAPIPath(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty else { return nil }
        return WebDAVURLBuilder.canonicalBrowsePath(normalized)
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
        case 0:
            return "pCloud API returned an unexpected success response without data. Sign out and sign in again."
        default:
            if !detail.isEmpty {
                return "pCloud error \(code): \(detail)"
            }
            if code < 0 {
                return "Unexpected pCloud API response — folder browse may still work."
            }
            return "pCloud error \(code)."
        }
    }
}
