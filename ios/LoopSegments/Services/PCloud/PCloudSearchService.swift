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
    /// Order: **recent search-hit folders** (last 100), then **current Browse folder**, then **bookmarks**.
    /// Excludes `/` (root). Not the whole browse stack — only `pathStack.last` for current folder.
    static func mergedBrowsePathsForSearch(pathStack: [String]) -> [String] {
        var paths: [String] = SearchLocationCache.listingPaths()
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

    private static func finishResult(items: [WebDAVItem], statusNote: String) -> Result {
        SearchLocationCache.recordHits(from: items)
        return Result(items: items, statusNote: statusNote)
    }

    private static func webDAVSuccessNote(count: Int, recentRootCount: Int) -> String {
        if recentRootCount > 0 {
            return "Found \(count) match(es) via folder search (WebDAV, recent folders + bookmarks + browse)."
        }
        return "Found \(count) match(es) via folder search (WebDAV, bookmarks + browse)."
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
        status: (@Sendable (String) -> Void)? = nil,
        onPartialResults: (@Sendable (_ items: [WebDAVItem], _ statusNote: String) -> Void)? = nil
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
        let recentRootCount = SearchLocationCache.listingPaths().count
        if recentRootCount > 0 {
            SearchDebugLog.log(
                "search: \(recentRootCount) recent hit folder(s) preferred before bookmarks + browse"
            )
        }
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
                reason: .missingToken,
                bookmarksOnly: initiatedFromRoot,
                onPartialResults: onPartialResults
            )
        }

        if !PCloudSearchSettings.restAPISearchEnabled {
            SearchDebugLog.log("search: REST API disabled in Browse — WebDAV only")
            return try await webDAVOnlyResult(
                query: trimmed,
                credentials: credentials,
                browsePaths: webDAVRoots,
                status: scopedStatus,
                reason: .restDisabled,
                bookmarksOnly: initiatedFromRoot,
                onPartialResults: onPartialResults
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
                return finishResult(items: catalog, statusNote: note)
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
        let webDAVPass = try await runWebDAVSearchWithCacheFirst(
            query: trimmed,
            credentials: credentials,
            browsePaths: webDAVRoots,
            timeoutSeconds: webDAVSeconds,
            status: scopedStatus,
            bookmarksOnly: initiatedFromRoot,
            onPartialResults: onPartialResults
        )
        webDAVTimedOut = webDAVPass.timedOut
        let webDAV = webDAVPass.items

        SearchDebugLog.log("WebDAV walk matches=\(webDAV.count)")

        if !webDAV.isEmpty {
            let note = webDAVSuccessNote(count: webDAV.count, recentRootCount: recentRootCount)
            SearchDebugLog.log("done: \(note)")
            return finishResult(items: webDAV, statusNote: note)
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
        reason: WebDAVOnlyReason,
        bookmarksOnly: Bool = false,
        onPartialResults: (@Sendable (_ items: [WebDAVItem], _ statusNote: String) -> Void)?
    ) async throws -> Result {
        let bookmarkCount = FolderBookmarkStore.lanBookmarkEntries().count
        let webDAVSeconds = webDAVTimeoutSeconds(rootCount: browsePaths.count)
        status?("WebDAV folder walk (\(browsePaths.count) roots, \(Int(webDAVSeconds))s max)…")
        let webDAV = try await runWebDAVSearchWithCacheFirst(
            query: query,
            credentials: credentials,
            browsePaths: browsePaths,
            timeoutSeconds: webDAVSeconds,
            status: status,
            bookmarksOnly: bookmarksOnly,
            onPartialResults: onPartialResults
        )
        if !webDAV.items.isEmpty {
            let recent = SearchLocationCache.listingPaths().count
            let note = webDAVSuccessNote(count: webDAV.items.count, recentRootCount: recent)
            SearchDebugLog.log("done: \(note)")
            return finishResult(items: webDAV.items, statusNote: note)
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

    /// Lists each recent search-hit folder first (like paused-export resolve), publishes hits early, then walks bookmarks + browse.
    private static func runWebDAVSearchWithCacheFirst(
        query: String,
        credentials: WebDAVCredentials,
        browsePaths: [String],
        timeoutSeconds: Double? = nil,
        status: (@Sendable (String) -> Void)? = nil,
        bookmarksOnly: Bool = false,
        onPartialResults: (@Sendable (_ items: [WebDAVItem], _ statusNote: String) -> Void)? = nil
    ) async throws -> WebDAVSearchPass {
        let fileHits = SearchLocationCache.matchSearchQuery(query)
        if !fileHits.isEmpty {
            let note = fileCacheEarlyResultsNote(count: fileHits.count, strong: SearchLocationCache.hasStrongFileMatch(for: query))
            SearchDebugLog.log("search: \(fileHits.count) file cache hit(s) (path/name) — continuing bookmark + browse walk")
            onPartialResults?(fileHits, note)
        } else {
            SearchDebugLog.log(
                "search: 0 file cache match(es) for \"\(query)\" (\(SearchLocationCache.savedFileCount()) saved files)"
            )
        }

        let folderHits: [WebDAVItem]
        if !fileHits.isEmpty {
            SearchDebugLog.log("search: file cache satisfied — skipping cached-folder PROPFIND")
            folderHits = []
        } else {
            folderHits = try await searchQueryInCachedFolders(
                query: query,
                credentials: credentials,
                status: status,
                onFirstHits: { hits in
                    guard fileHits.isEmpty else { return }
                    let note = cacheEarlyResultsNote(count: hits.count)
                    SearchDebugLog.log(
                        "search: \(hits.count) hit(s) in recent folder — continuing bookmark + browse walk"
                    )
                    onPartialResults?(hits, note)
                }
            )
        }
        let pass = try await runWebDAVSearch(
            query: query,
            credentials: credentials,
            browsePaths: browsePaths,
            timeoutSeconds: timeoutSeconds,
            status: status,
            bookmarksOnly: bookmarksOnly
        )
        let merged = mergeSearchItems([fileHits, folderHits, pass.items])
        return WebDAVSearchPass(items: merged, timedOut: pass.timedOut)
    }

    private static func fileCacheEarlyResultsNote(count: Int, strong: Bool) -> String {
        let n = count == 1 ? "1 match" : "\(count) matches"
        if strong {
            return "Found \(n) from saved file path (still searching bookmarks + browse)…"
        }
        return "Found \(n) in saved file names (still searching bookmarks + browse)…"
    }

    private static func cacheEarlyResultsNote(count: Int) -> String {
        let n = count == 1 ? "1 match" : "\(count) matches"
        return "Found \(n) in recent folders (still searching bookmarks + browse)…"
    }

    private static func searchQueryInCachedFolders(
        query: String,
        credentials: WebDAVCredentials,
        status: (@Sendable (String) -> Void)?,
        onFirstHits: (@Sendable ([WebDAVItem]) -> Void)? = nil
    ) async throws -> [WebDAVItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let folders = SearchLocationCache.listingPaths()
        guard !folders.isEmpty else { return [] }

        let client = WebDAVClient(credentials: credentials)
        var results: [WebDAVItem] = []
        for path in folders {
            guard !Task.isCancelled else { throw CancellationError() }
            let short = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let label = short.isEmpty ? path : short
            status?("Recent folder: \(label)…")
            SearchDebugLog.log("search: list cached folder \(path)")
            let items: [WebDAVItem]
            do {
                items = try await client.list(path: path)
            } catch {
                SearchDebugLog.log("search: list failed \(path) — \(error.localizedDescription)")
                continue
            }
            SearchLocationCache.recordListingWarmup(from: items)
            let warmed = SearchLocationCache.matchSearchQuery(query)
            if !warmed.isEmpty {
                SearchLocationCache.recordHits(from: warmed)
                SearchDebugLog.log(
                    "search: \(warmed.count) file cache hit(s) after listing \(path) — continuing bookmark + browse walk"
                )
                onFirstHits?(warmed)
                return warmed
            }
            var folderHits: [WebDAVItem] = []
            for item in items {
                let haystack = "\(item.href)/\(item.name)".lowercased()
                let nameMatch = item.name.lowercased().contains(needle)
                guard haystack.contains(needle) || nameMatch else { continue }
                guard item.isDirectory || item.isVideo else { continue }
                folderHits.append(item)
            }
            guard folderHits.isEmpty else {
                SearchLocationCache.recordHits(from: folderHits)
                results.append(contentsOf: folderHits)
                let merged = mergeSearchItems([results])
                onFirstHits?(merged)
                return merged
            }
        }
        return mergeSearchItems([results])
    }

    private static func mergeSearchItems(_ groups: [[WebDAVItem]]) -> [WebDAVItem] {
        var seen = Set<String>()
        var out: [WebDAVItem] = []
        for item in groups.flatMap({ $0 }) {
            guard seen.insert(item.fileKey).inserted else { continue }
            out.append(item)
        }
        return out.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func runWebDAVSearch(
        query: String,
        credentials: WebDAVCredentials,
        browsePaths: [String],
        timeoutSeconds: Double? = nil,
        status: (@Sendable (String) -> Void)? = nil,
        bookmarksOnly: Bool = false
    ) async throws -> WebDAVSearchPass {
        let seconds = timeoutSeconds ?? webDAVTimeoutSeconds(rootCount: browsePaths.count)
        if bookmarksOnly {
            SearchDebugLog.log("search: bookmarks-only walk (no user-files tree)")
        }
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
                    pinnedRootsOnly: bookmarksOnly,
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
        if let fileCached = SearchLocationCache.matchResumeEntry(entry) {
            SearchDebugLog.log("resume resolve: file cache match \"\(fileCached.name)\" href=\(fileCached.href)")
            SearchLocationCache.recordHits(from: [fileCached])
            return fileCached
        }
        if let cached = try await matchResumeEntryInCachedFolders(
            entry: entry,
            credentials: credentials,
            status: status
        ) {
            SearchDebugLog.log("resume resolve: matched in cached folder \"\(cached.name)\"")
            return cached
        }
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

    /// LAN / REST: find a video by filename via cache + Browse search (WebDAV walk on bookmarks + recent folders).
    static func findVideoByDisplayName(
        displayName: String,
        credentials: WebDAVCredentials,
        browsePaths: [String] = ["/"],
        status: (@Sendable (String) -> Void)? = nil
    ) async throws -> WebDAVItem? {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let entry = ResumeEntry(
            fileKey: "lan-resolve:\(name.lowercased())",
            displayName: name,
            href: nil,
            lastSeekMs: 0,
            sourceDurationMs: nil,
            updatedAt: Date(),
            exportInProgress: false,
            checkpointMediaMs: nil,
            pinnedCompleted: false
        )
        SearchDebugLog.log("LAN filename resolve start: \"\(name)\" browseDepth=\(browsePaths.count)")
        return try await searchMatchingResumeEntry(
            entry: entry,
            credentials: credentials,
            browsePaths: browsePaths,
            status: status
        )
    }

    /// One PROPFIND per recent search-hit folder — avoids walking 80 bookmark trees first.
    private static func matchResumeEntryInCachedFolders(
        entry: ResumeEntry,
        credentials: WebDAVCredentials,
        status: (@Sendable (String) -> Void)?
    ) async throws -> WebDAVItem? {
        let folders = SearchLocationCache.listingPaths()
        guard !folders.isEmpty else { return nil }
        let client = WebDAVClient(credentials: credentials)
        for path in folders {
            guard !Task.isCancelled else { throw CancellationError() }
            let short = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let label = short.isEmpty ? path : short
            status?("Recent folder: \(label)…")
            SearchDebugLog.log("resume resolve: list cached folder \(path)")
            let items: [WebDAVItem]
            do {
                items = try await client.list(path: path)
            } catch {
                SearchDebugLog.log("resume resolve: list failed \(path) — \(error.localizedDescription)")
                continue
            }
            let videos = items.filter(\.isVideo)
            if let match = WebDAVRenameReconcile.matchResumeEntry(entry, in: videos) {
                SearchLocationCache.recordHits(from: [match])
                return match
            }
        }
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
