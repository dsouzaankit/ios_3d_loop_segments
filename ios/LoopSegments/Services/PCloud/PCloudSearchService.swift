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

        SearchDebugLog.beginSearch(query: trimmed, credentials: credentials, browsePaths: browsePaths)

        var tried: [String] = []
        var apiRawCount = 0
        var webDAVTimedOut = false
        var catalogTimedOut = false

        let api = PCloudAPIClient(credentials: credentials)

        tried.append("pCloud web search")
        status?("pCloud web search…")
        do {
            let apiResult = try await timed("pCloud web search", seconds: webSearchTimeoutSeconds) {
                try await api.search(query: trimmed)
            }
            apiRawCount = apiResult.1.rawEntryCount
            SearchDebugLog.log(
                "web search raw=\(apiResult.1.rawEntryCount) resolved=\(apiResult.1.resolvedCount) shown=\(apiResult.0.count)"
            )
            if !apiResult.0.isEmpty {
                let note = "Found \(apiResult.0.count) match(es) via pCloud web search."
                SearchDebugLog.log("done: \(note)")
                return Result(items: apiResult.0, statusNote: note)
            }
            if apiRawCount > 0 {
                let note = """
                pCloud returned \(apiRawCount) hit(s) but none mapped to videos/folders — sign out/in, open the folder in Browse, then search again.
                """
                SearchDebugLog.log("done: raw hits but 0 mapped (see resolve drops above)")
                return Result(items: [], statusNote: note)
            }
            SearchDebugLog.log("web search: 0 raw hits")
        } catch is ExportAsyncTimeout.TimedOut {
            SearchDebugLog.log("web search: timed out after \(Int(webSearchTimeoutSeconds))s")
        } catch {
            SearchDebugLog.log("web search failed: \(error.localizedDescription)")
        }

        tried.append("pCloud folder index")
        status?("pCloud folder index (shallow)…")
        do {
            let catalog = try await timed("pCloud folder index", seconds: catalogTimeoutSeconds) {
                try await PCloudAPIFolderSearch.search(
                    query: trimmed,
                    credentials: credentials,
                    apiClient: api
                )
            }
            SearchDebugLog.log("folder index matches=\(catalog.count)")
            if !catalog.isEmpty {
                let note = "Found \(catalog.count) match(es) via pCloud folder index."
                SearchDebugLog.log("done: \(note)")
                return Result(items: catalog, statusNote: note)
            }
        } catch is ExportAsyncTimeout.TimedOut {
            catalogTimedOut = true
            SearchDebugLog.log("folder index: timed out after \(Int(catalogTimeoutSeconds))s")
        } catch {
            SearchDebugLog.log("folder index failed: \(error.localizedDescription)")
        }

        tried.append("folders (WebDAV)")
        status?("WebDAV folder walk (last resort, \(Int(webDAVTimeoutSeconds))s max)…")
        var webDAV: [WebDAVItem] = []
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
            SearchDebugLog.log("WebDAV walk: timed out after \(Int(webDAVTimeoutSeconds))s")
        } catch {
            webDAV = []
            SearchDebugLog.log("WebDAV walk failed: \(error.localizedDescription)")
        }

        SearchDebugLog.log("WebDAV walk matches=\(webDAV.count)")

        if !webDAV.isEmpty {
            let note = "Found \(webDAV.count) match(es) via folder search (WebDAV)."
            SearchDebugLog.log("done: \(note)")
            return Result(items: webDAV, statusNote: note)
        }

        let empty = emptyMessage(
                query: trimmed,
                tried: tried,
                apiRawCount: apiRawCount,
                browsePaths: browsePaths,
                webDAVTimedOut: webDAVTimedOut,
                catalogTimedOut: catalogTimedOut
            )
        SearchDebugLog.log("done: no matches — \(empty)")
        return Result(items: [], statusNote: empty)
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
