import Foundation

/// Search order matches pCloud web: REST `search` first (~seconds), then catalog, then WebDAV walk (last, capped).
enum PCloudSearchService {
    struct Result {
        let items: [WebDAVItem]
        let statusNote: String
    }

    private static let webSearchTimeoutSeconds: Double = 20
    private static let catalogTimeoutSeconds: Double = 15
    private static let webDAVTimeoutSeconds: Double = 10
    private static let webDAVMaxFolders = 80

    /// Browse stack plus saved folder bookmarks — used for WebDAV folder walk (`extraRoots`).
    static func mergedBrowsePathsForSearch(pathStack: [String]) -> [String] {
        var paths = pathStack
        for bookmark in FolderBookmarkStore.lanBookmarkEntries() {
            paths.append(bookmark.listingPath)
        }
        return dedupeListingPaths(paths)
    }

    private static func dedupeListingPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in paths {
            let normalized = WebDAVURLBuilder.directoryListingPath(path)
            guard seen.insert(normalized).inserted else { continue }
            out.append(normalized)
        }
        return out
    }

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

        let webDAVRoots = mergedBrowsePathsForSearch(pathStack: browsePaths)
        SearchDebugLog.beginSearch(query: trimmed, credentials: credentials, browsePaths: webDAVRoots)

        guard !Task.isCancelled else {
            SearchDebugLog.log("search: cancelled before start")
            throw CancellationError()
        }

        let bookmarkCount = FolderBookmarkStore.lanBookmarkEntries().count
        let hasToken = credentials.apiAuthToken?.isEmpty == false
        if !hasToken {
            SearchDebugLog.log(
                "search: tokenSaved=false — API skipped; WebDAV walk on browse + \(bookmarkCount) bookmark folder(s)"
            )
            status?("WebDAV folder walk (bookmarks + browse, \(Int(webDAVTimeoutSeconds))s max)…")
            let webDAV = try await runWebDAVSearch(
                query: trimmed,
                credentials: credentials,
                browsePaths: webDAVRoots
            )
            if !webDAV.items.isEmpty {
                let note = "Found \(webDAV.items.count) match(es) via folder search (WebDAV, bookmarks + browse)."
                SearchDebugLog.log("done: \(note)")
                return Result(items: webDAV.items, statusNote: note)
            }
            let note = """
            pCloud search login missing. Sign out, sign in again (correct US/Europe), then search. \
            Browse still works; use 2FA app password if enabled. \
            Also tried WebDAV on \(bookmarkCount) bookmark folder(s) and current browse path — no matches.
            """
            SearchDebugLog.log("done: \(note)")
            return Result(items: [], statusNote: note)
        }

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
        } catch is CancellationError {
            SearchDebugLog.log("web search: cancelled")
            throw CancellationError()
        } catch is ExportAsyncTimeout.TimedOut {
            SearchDebugLog.log("web search: timed out after \(Int(webSearchTimeoutSeconds))s")
        } catch {
            SearchDebugLog.log("web search failed: \(error.localizedDescription)")
        }

        guard !Task.isCancelled else {
            SearchDebugLog.log("search: cancelled after web search")
            throw CancellationError()
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
        } catch is CancellationError {
            SearchDebugLog.log("folder index: cancelled")
            throw CancellationError()
        } catch is ExportAsyncTimeout.TimedOut {
            catalogTimedOut = true
            SearchDebugLog.log("folder index: timed out after \(Int(catalogTimeoutSeconds))s")
        } catch {
            SearchDebugLog.log("folder index failed: \(error.localizedDescription)")
        }

        guard !Task.isCancelled else {
            SearchDebugLog.log("search: cancelled after folder index")
            throw CancellationError()
        }

        tried.append("folders (WebDAV)")
        status?("WebDAV folder walk (bookmarks + browse, \(Int(webDAVTimeoutSeconds))s max)…")
        let webDAVPass = try await runWebDAVSearch(
            query: trimmed,
            credentials: credentials,
            browsePaths: webDAVRoots
        )
        webDAVTimedOut = webDAVPass.timedOut
        let webDAV = webDAVPass.items

        SearchDebugLog.log("WebDAV walk matches=\(webDAV.count)")

        if !webDAV.isEmpty {
            let note = "Found \(webDAV.count) match(es) via folder search (WebDAV, bookmarks + browse)."
            SearchDebugLog.log("done: \(note)")
            return Result(items: webDAV, statusNote: note)
        }

        let empty = emptyMessage(
            query: trimmed,
            tried: tried,
            apiRawCount: apiRawCount,
            browsePaths: webDAVRoots,
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

    private struct WebDAVSearchPass {
        var items: [WebDAVItem]
        var timedOut: Bool
    }

    private static func runWebDAVSearch(
        query: String,
        credentials: WebDAVCredentials,
        browsePaths: [String]
    ) async throws -> WebDAVSearchPass {
        do {
            let items = try await timed("WebDAV search", seconds: webDAVTimeoutSeconds) {
                try await WebDAVSearchClient.search(
                    query: query,
                    credentials: credentials,
                    extraRoots: browsePaths,
                    maxFoldersToVisit: webDAVMaxFolders,
                    quickRootDiscovery: true
                )
            }
            return WebDAVSearchPass(items: items, timedOut: false)
        } catch is CancellationError {
            SearchDebugLog.log("WebDAV walk: cancelled")
            throw CancellationError()
        } catch is ExportAsyncTimeout.TimedOut {
            SearchDebugLog.log("WebDAV walk: timed out after \(Int(webDAVTimeoutSeconds))s")
            return WebDAVSearchPass(items: [], timedOut: true)
        } catch {
            SearchDebugLog.log("WebDAV walk failed: \(error.localizedDescription)")
            return WebDAVSearchPass(items: [], timedOut: false)
        }
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
