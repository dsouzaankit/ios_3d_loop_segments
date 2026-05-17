import Foundation

/// Search order matches pCloud web: REST `search` first (~seconds), then catalog, then WebDAV walk (last, capped).
enum PCloudSearchService {
    struct Result {
        let items: [WebDAVItem]
        let statusNote: String
    }

    private static let webSearchTimeoutSeconds: Double = 12
    private static let catalogTimeoutSeconds: Double = 15
    private static let webDAVTimeoutSeconds: Double = 10
    private static let webDAVMaxFolders = 80

    static func search(
        query: String,
        credentials: WebDAVCredentials,
        browsePaths: [String] = [],
        status: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Result(items: [], statusNote: "Enter a file or folder name to search.")
        }

        var tried: [String] = []
        var apiRawCount = 0
        var webDAVTimedOut = false
        var catalogTimedOut = false

        let api = PCloudAPIClient(credentials: credentials)

        tried.append("pCloud web search")
        status?("pCloud web search…")
        if let apiResult = try? await timed("pCloud web search", seconds: webSearchTimeoutSeconds, {
            try await api.search(query: trimmed)
        }) {
            apiRawCount = apiResult.1.rawEntryCount
            if !apiResult.0.isEmpty {
                return Result(
                    items: apiResult.0,
                    statusNote: "Found \(apiResult.0.count) match(es) via pCloud web search."
                )
            }
            if apiRawCount > 0 {
                return Result(
                    items: [],
                    statusNote: """
                    pCloud returned \(apiRawCount) hit(s) but none mapped to videos/folders — sign out/in, open the folder in Browse, then search again.
                    """
                )
            }
        }

        tried.append("pCloud folder index")
        status?("pCloud folder index (shallow)…")
        if let catalog = try? await timed("pCloud folder index", seconds: catalogTimeoutSeconds, {
            try await PCloudAPIFolderSearch.search(
                query: trimmed,
                credentials: credentials,
                apiClient: api
            )
        }) {
            if !catalog.isEmpty {
                return Result(
                    items: catalog,
                    statusNote: "Found \(catalog.count) match(es) via pCloud folder index."
                )
            }
        } else {
            catalogTimedOut = true
        }

        tried.append("folders (WebDAV)")
        status?("WebDAV folder walk (last resort, \(Int(webDAVTimeoutSeconds))s max)…")
        let webDAV: [WebDAVItem]
        do {
            webDAV = try await timed("WebDAV search", seconds: webDAVTimeoutSeconds) {
                try await WebDAVSearchClient.search(
                    query: trimmed,
                    credentials: credentials,
                    extraRoots: browsePaths,
                    maxFoldersToVisit: webDAVMaxFolders,
                    quickRootDiscovery: true
                )
            }
        } catch is ExportAsyncTimeout.TimedOut {
            webDAVTimedOut = true
            webDAV = []
        }

        if !webDAV.isEmpty {
            return Result(
                items: webDAV,
                statusNote: "Found \(webDAV.count) match(es) via folder search (WebDAV)."
            )
        }

        return Result(
            items: [],
            statusNote: emptyMessage(
                query: trimmed,
                tried: tried,
                apiRawCount: apiRawCount,
                browsePaths: browsePaths,
                webDAVTimedOut: webDAVTimedOut,
                catalogTimedOut: catalogTimedOut
            )
        )
    }

    private static func timed<T>(
        _ operation: String,
        seconds: Double,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await ExportAsyncTimeout.run(seconds: seconds, operation: operation, body: body)
    }

    private static func emptyMessage(
        query: String,
        tried: [String],
        apiRawCount: Int,
        browsePaths: [String],
        webDAVTimedOut: Bool,
        catalogTimedOut: Bool
    ) -> String {
        if apiRawCount > 0 {
            return """
            pCloud web search returned \(apiRawCount) hit(s) but paths could not be mapped to WebDAV. \
            Open the folder in Browse first, then search again — or sign out and sign in to refresh search login.
            """
        }
        var suffix = ""
        if webDAVTimedOut || catalogTimedOut {
            let parts = [
                webDAVTimedOut ? "WebDAV timed out" : nil,
                catalogTimedOut ? "folder index timed out" : nil,
            ].compactMap { $0 }
            suffix = " (\(parts.joined(separator: "; ")))"
        }
        let methods = tried.joined(separator: " → ")
        if let path = browsePaths.last, path != "/" {
            let folder = (path as NSString).lastPathComponent
            return "No matches for “\(query)” (\(methods))\(suffix). Try a shorter name or browse “\(folder)”."
        }
        return "No matches for “\(query)” (\(methods))\(suffix). Try a shorter fragment or sign out/in to refresh API login."
    }
}
