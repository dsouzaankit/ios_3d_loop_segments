import Foundation

/// pCloud REST API (search, etc.) using the same credentials as WebDAV.
final class PCloudAPIClient {
    private static let searchResultLimit = 80
    private static let searchPageLimit = 600

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
        let apiCode = PCloudAPIRequest.resultCode(json)
        if apiCode != 0 {
            SearchDebugLog.log(
                "api search final result=\(apiCode) msg=\(PCloudAPIRequest.errorMessage(json) ?? "-")"
            )
        }
        try PCloudAPIRequest.throwIfAPIError(json)
        let raw = PCloudMetadataParsing.extractEntries(from: json)
        SearchDebugLog.log("api extractEntries count=\(raw.count)")
        if raw.isEmpty, apiCode == 0 {
            SearchDebugLog.log("api empty items — sample keys: \(Array(json.keys).sorted().prefix(12).joined(separator: ","))")
        } else if let first = raw.first {
            let name = first["name"] as? String ?? "?"
            let ids = PCloudMetadataParsing.resolvedIds(from: first)
            SearchDebugLog.log(
                "api first hit name=\(name) fileId=\(ids.fileId.map(String.init) ?? "-") folderId=\(ids.folderId.map(String.init) ?? "-") path=\(first["path"] as? String ?? "-")"
            )
        }
        let capped = Array(raw.prefix(Self.searchResultLimit))
        let items = try await PCloudPathResolver.resolveSearchItems(
            entries: capped,
            credentials: creds,
            apiClient: self
        )
        return (items, SearchDiagnostics(rawEntryCount: raw.count, resolvedCount: items.count))
    }

    func listFolderContents(folderId: Int64) async throws -> [[String: Any]] {
        let json = try await listFolderJSON(folderId: folderId, recursive: false)
        guard let metadata = json["metadata"] as? [String: Any],
              let contents = metadata["contents"] as? [[String: Any]] else {
            return []
        }
        return PCloudMetadataParsing.flattenFolderContents(contents)
    }

    /// One-shot recursive listing (pCloud `listfolder` + `recursive=1`).
    func listFolderRecursiveFlat(folderId: Int64 = 0) async throws -> [[String: Any]] {
        let json = try await listFolderJSON(folderId: folderId, recursive: true)
        guard let metadata = json["metadata"] as? [String: Any] else { return [] }
        var rows = PCloudMetadataParsing.flattenFolderContents([metadata])
        if rows.count > PCloudAPIFolderSearch.maxRecursiveEntriesForAPI {
            rows = Array(rows.prefix(PCloudAPIFolderSearch.maxRecursiveEntriesForAPI))
        }
        return rows
    }

    private func listFolderJSON(folderId: Int64, recursive: Bool) async throws -> [String: Any] {
        let creds = resolvedCredentials()
        let token = try await ensureAuthToken(credentials: creds)
        let host = authAPIHost ?? authRegion?.apiHost ?? creds.region.apiHost
        var parameters: [String: String] = [
            "auth": token,
            "folderid": "\(folderId)",
        ]
        if recursive {
            parameters["recursive"] = "1"
        }
        let json = try await PCloudAPIRequest.get(
            host: host,
            method: "listfolder",
            parameters: parameters,
            session: session
        )
        try PCloudAPIRequest.throwIfAPIError(json)
        return json
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

        let parameterSets: [[String: String]] = [
            Self.browserSearchParameters(query: query, token: token),
            Self.legacySearchParameters(query: query, token: token),
        ]

        SearchDebugLog.log("api search hosts=\(hosts.joined(separator: ",")) tokenLen=\(token.count)")

        for host in hosts {
            for (styleIndex, parameters) in parameterSets.enumerated() {
                let style = styleIndex == 0 ? "browser" : "legacy"
                let json = try await PCloudAPIRequest.get(
                    host: host,
                    method: "search",
                    parameters: parameters,
                    session: session
                )
                let code = PCloudAPIRequest.resultCode(json)
                let entries = PCloudMetadataParsing.extractEntries(from: json)
                SearchDebugLog.logAPIAttempt(
                    host: host,
                    parameterStyle: style,
                    resultCode: code,
                    entryCount: entries.count,
                    topLevelKeys: Array(json.keys)
                )
                if code == 1000 || code == 2000 {
                    authToken = nil
                    authAPIHost = nil
                    var retryParams = parameters
                    retryParams["auth"] = try await ensureAuthToken(credentials: credentials)
                    let retryJSON = try await PCloudAPIRequest.get(
                        host: host,
                        method: "search",
                        parameters: retryParams,
                        session: session
                    )
                    let retryCode = PCloudAPIRequest.resultCode(retryJSON)
                    let retryEntries = PCloudMetadataParsing.extractEntries(from: retryJSON)
                    SearchDebugLog.logAPIAttempt(
                        host: host,
                        parameterStyle: "\(style)-retry",
                        resultCode: retryCode,
                        entryCount: retryEntries.count,
                        topLevelKeys: Array(retryJSON.keys)
                    )
                    if retryCode == 0, !retryEntries.isEmpty {
                        authAPIHost = host
                        return retryJSON
                    }
                    lastJSON = retryJSON
                    lastCode = retryCode
                    continue
                }
                if code == 0 {
                    if !entries.isEmpty {
                        authAPIHost = host
                        return json
                    }
                    lastJSON = json
                    lastCode = code
                    continue
                }
                lastJSON = json
                lastCode = code
            }
        }

        if let lastJSON, PCloudAPIRequest.resultCode(lastJSON) == 0 {
            return lastJSON
        }
        if let lastJSON {
            return lastJSON
        }
        throw PCloudAPIError.api(code: lastCode, message: nil)
    }

    /// Same query shape as my.pcloud.com (`/search?query=&offset=0&limit=600&iconformat=id&auth=`).
    private static func browserSearchParameters(query: String, token: String) -> [String: String] {
        [
            "auth": token,
            "query": query,
            "offset": "0",
            "limit": "\(searchPageLimit)",
            "iconformat": "id",
        ]
    }

    private static func legacySearchParameters(query: String, token: String) -> [String: String] {
        [
            "auth": token,
            "query": query,
            "searchall": "1",
        ]
    }

    private func searchHostsToTry(credentials: WebDAVCredentials) async -> [String] {
        var hosts: [String] = []
        if let saved = credentials.apiAuthHost, !saved.isEmpty {
            hosts.append(saved)
        }
        if let authAPIHost, !authAPIHost.isEmpty {
            hosts.append(authAPIHost)
        }
        hosts.append(credentials.region.apiHost)
        hosts.append(credentials.region.alternate.apiHost)
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
