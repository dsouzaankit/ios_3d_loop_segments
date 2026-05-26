import Foundation

/// Search: optional REST `search` + folder index (Browse toggle, off by default), then WebDAV walk (bookmarks + browse).
enum PCloudSearchService {
    struct Result {
        let items: [WebDAVItem]
        let statusNote: String
    }

    private static let webSearchTimeoutSeconds: Double = 20
    private static let catalogTimeoutSeconds: Double = 15
    private static let webDAVTimeoutBaseSeconds: Double = 10
    private static let webDAVTimeoutMaxSeconds: Double = 45
    private static let webDAVMaxFolders = 80

    /// More bookmark/browse roots need more time; cap avoids multi-minute LAN stalls.
    private static func webDAVTimeoutSeconds(rootCount: Int) -> Double {
        let extra = max(0, rootCount - 1)
        return min(webDAVTimeoutBaseSeconds + Double(extra) * 2.5, webDAVTimeoutMaxSeconds)
    }

    /// WebDAV walk roots for search.
    ///
    /// Restrict scope to **bookmarks + current folder only** (not the whole browse stack),
    /// and always exclude `/` (root).
    static func mergedBrowsePathsForSearch(pathStack: [String]) -> [String] {
        var paths: [String] = []
        if let current = pathStack.last {
            let normalized = WebDAVURLBuilder.directoryListingPath(current)
            if normalized != "/" {
                paths.append(normalized)
            }
        }
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

        let rawCurrentPath = browsePaths.last ?? "/"
        let normalizedCurrentPath = WebDAVURLBuilder.directoryListingPath(rawCurrentPath)
        let initiatedFromRoot = normalizedCurrentPath == "/"

        let scopedStatus: (@Sendable (String) -> Void)? = initiatedFromRoot
            ? status.map { upstream in
                { note in upstream("Root excluded (bookmarks-only): \(note)") }
            }
            : status

        let webDAVRoots = mergedBrowsePathsForSearch(pathStack: browsePaths)
        SearchDebugLog.beginSearch(query: trimmed, credentials: credentials, browsePaths: webDAVRoots)

        guard !Task.isCancelled else {
            SearchDebugLog.log("search: cancelled before start")
            throw CancellationError()
        }

        let hasToken = credentials.apiAuthToken?.isEmpty == false
        SearchDebugLog.log(
            "restAPISearchEnabled=\(PCloudSearchSettings.restAPISearchEnabled) tokenSaved=\(hasToken)"
        )
        if initiatedFromRoot {
            let note = "Search started at / — root excluded; WebDAV scope = bookmarks only."
            SearchDebugLog.log(note)
            status?(note)
        }

        if !hasToken {
            SearchDebugLog.log("search: tokenSaved=false — API skipped; WebDAV only")
            return try await webDAVOnlyResult(
                query: trimmed,
                credentials: credentials,
                browsePaths: webDAVRoots,
                status: scopedStatus,
                reason: .missingToken
            )
        }

        if !PCloudSearchSettings.restAPISearchEnabled {
            SearchDebugLog.log("search: REST API disabled in Browse — WebDAV only")
            return try await webDAVOnlyResult(
                query: trimmed,
                credentials: credentials,
                browsePaths: webDAVRoots,
                status: scopedStatus,
                reason: .restDisabled
            )
        }

        var tried: [String] = []
        var apiRawCount = 0
        var webDAVTimedOut = false
        var catalogTimedOut = false

        let api = PCloudAPIClient(credentials: credentials)

        tried.append("pCloud web search")
        scopedStatus?("pCloud web search…")
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
        scopedStatus?("pCloud folder index (shallow)…")
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
        let webDAVSeconds = webDAVTimeoutSeconds(rootCount: webDAVRoots.count)
        scopedStatus?("WebDAV folder walk (\(Int(webDAVSeconds))s max)…")
        let webDAVPass = try await runWebDAVSearch(
            query: trimmed,
            credentials: credentials,
            browsePaths: webDAVRoots,
            timeoutSeconds: webDAVSeconds,
            status: scopedStatus
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

    private enum WebDAVOnlyReason {
        case missingToken
        case restDisabled
    }

    private static func webDAVOnlyResult(
        query: String,
        credentials: WebDAVCredentials,
        browsePaths: [String],
        status: (@Sendable (String) -> Void)?,
        reason: WebDAVOnlyReason
    ) async throws -> Result {
        let bookmarkCount = FolderBookmarkStore.lanBookmarkEntries().count
        let webDAVSeconds = webDAVTimeoutSeconds(rootCount: browsePaths.count)
        status?("WebDAV folder walk (\(browsePaths.count) roots, \(Int(webDAVSeconds))s max)…")
        let webDAV = try await runWebDAVSearch(
            query: query,
            credentials: credentials,
            browsePaths: browsePaths,
            timeoutSeconds: webDAVSeconds,
            status: status
        )
        if !webDAV.items.isEmpty {
            let note = "Found \(webDAV.items.count) match(es) via folder search (WebDAV, bookmarks + browse)."
            SearchDebugLog.log("done: \(note)")
            return Result(items: webDAV.items, statusNote: note)
        }
        let note = webDAVOnlyEmptyNote(
            query: query,
            reason: reason,
            bookmarkCount: bookmarkCount,
            rootCount: browsePaths.count,
            timedOut: webDAV.timedOut,
            timeoutSeconds: webDAVSeconds
        )
        SearchDebugLog.log("done: \(note)")
        return Result(items: [], statusNote: note)
    }

    private static func webDAVOnlyEmptyNote(
        query: String,
        reason: WebDAVOnlyReason,
        bookmarkCount: Int,
        rootCount: Int,
        timedOut: Bool,
        timeoutSeconds: Double
    ) -> String {
        let limit = Int(timeoutSeconds)
        if timedOut {
            switch reason {
            case .missingToken:
                return """
                Folder search timed out (\(limit)s) across \(rootCount) folder root(s) (\(bookmarkCount) bookmark(s)) — \
                not every folder was scanned for “\(query)”. Try opening the folder in Browse first, fewer bookmarks, \
                or sign in and turn on **pCloud REST search** for account-wide hits (see search_debug: tokenSaved). \
                Browse and export still work without the API token.
                """
            case .restDisabled:
                return """
                Folder search timed out (\(limit)s) across \(rootCount) folder root(s) for “\(query)”. \
                Turn on **pCloud REST search** in Browse for faster account-wide search, or open the target folder and search again.
                """
            }
        }
        switch reason {
        case .missingToken:
            return """
            No matches for “\(query)” in \(bookmarkCount) bookmark folder(s) + current browse path. \
            For account-wide search, sign in until search_debug shows tokenSaved=true, then enable **pCloud REST search**. \
            Browse and export work without the API token.
            """
        case .restDisabled:
            return """
            No matches for “\(query)” (WebDAV on bookmarks + browse). Turn on **pCloud REST search** in Browse \
            for account-wide web search and folder index.
            """
        }
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
        browsePaths: [String],
        timeoutSeconds: Double? = nil,
        status: (@Sendable (String) -> Void)? = nil
    ) async throws -> WebDAVSearchPass {
        let seconds = timeoutSeconds ?? webDAVTimeoutSeconds(rootCount: browsePaths.count)
        let progressHandler: (@Sendable (WebDAVSearchProgress) -> Void)? = status.map { report in
            { progress in
                let line = progress.uiStatusLine()
                report(line)
                if progress.phase == .discoveringRoots
                    || (progress.foldersVisited > 0 && progress.foldersVisited % 15 == 0) {
                    SearchDebugLog.log(line)
                }
            }
        }
        do {
            let items = try await timed("WebDAV search", seconds: seconds) {
                try await WebDAVSearchClient.search(
                    query: query,
                    credentials: credentials,
                    extraRoots: browsePaths,
                    maxFoldersToVisit: webDAVMaxFolders,
                    quickRootDiscovery: true,
                    timeoutSeconds: seconds,
                    progress: progressHandler
                )
            }
            return WebDAVSearchPass(items: items, timedOut: false)
        } catch is CancellationError {
            SearchDebugLog.log("WebDAV walk: cancelled")
            throw CancellationError()
        } catch is ExportAsyncTimeout.TimedOut {
            SearchDebugLog.log("WebDAV walk: timed out after \(Int(seconds))s (\(browsePaths.count) roots)")
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

    /// Same pipeline as Browse search (bookmarks + path stack, REST toggle, WebDAV progress) — for paused / pinned resume rows.
    static func searchMatchingResumeEntry(
        entry: ResumeEntry,
        credentials: WebDAVCredentials,
        browsePaths: [String],
        status: (@Sendable (String) -> Void)? = nil
    ) async throws -> WebDAVItem? {
        SearchDebugLog.log(
            "resume resolve start: \"\(entry.displayName)\" pinned=\(entry.pinnedCompleted) browseDepth=\(browsePaths.count)"
        )
        for query in resumeSearchQueries(for: entry) {
            guard !Task.isCancelled else {
                SearchDebugLog.log("resume resolve: cancelled")
                throw CancellationError()
            }
            SearchDebugLog.log("resume resolve: query=\"\(query)\"")
            let result = try await search(
                query: query,
                credentials: credentials,
                browsePaths: browsePaths,
                status: status
            )
            let videos = result.items.filter(\.isVideo)
            if let item = WebDAVRenameReconcile.matchResumeEntry(entry, in: videos) {
                SearchDebugLog.log("resume resolve: matched \"\(item.name)\" href=\(item.href)")
                return item
            }
            SearchDebugLog.log(
                "resume resolve: no reconcile match for query=\"\(query)\" (\(videos.count) video hit(s))"
            )
        }
        SearchDebugLog.log("resume resolve: gave up — no match")
        return nil
    }

    private static func resumeSearchQueries(for entry: ResumeEntry) -> [String] {
        var queries: [String] = []
        let name = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            queries.append(name)
            let base = (name as NSString).deletingPathExtension
            if base != name, !base.isEmpty {
                queries.append(base)
            }
        }
        return queries
    }
}
