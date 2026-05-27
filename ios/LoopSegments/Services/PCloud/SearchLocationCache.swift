import Foundation

/// Recent search hits: **files** (full `href` + name, instant replay) and **folders** (PROPFIND roots for discovery).
enum SearchLocationCache {
    static let maxFolderEntries = 100
    static let maxFileEntries = 200
    private static let storageKeyV2 = "search_location_cache_v2"
    private static let storageKeyV1 = "search_location_cache_v1"

    private struct FolderEntry: Codable {
        var listingPath: String
        var recordedAt: Date
    }

    private struct FileEntry: Codable {
        var href: String
        var name: String
        var isDirectory: Bool
        var contentLength: Int64?
        var listingPath: String
        var recordedAt: Date

        func webDAVItem() -> WebDAVItem {
            WebDAVItem(
                href: href,
                name: name,
                isDirectory: isDirectory,
                contentLength: contentLength
            )
        }
    }

    private struct Store: Codable {
        var folders: [FolderEntry] = []
        var files: [FileEntry] = []
    }

    private enum FileMatchRank: Int {
        case fullHref = 0
        case exactName = 1
        case substring = 2
    }

    static func listingPaths() -> [String] {
        loadStore()
            .folders
            .map(\.listingPath)
            .filter { WebDAVURLBuilder.directoryListingPath($0) != "/" }
    }

    static func savedFileCount() -> Int {
        loadStore().files.count
    }

    /// Remember every video seen in a cached-folder PROPFIND (no log spam) so the next search can hit file cache.
    static func recordListingWarmup(from items: [WebDAVItem]) {
        guard !items.isEmpty else { return }
        var store = loadStore()
        for item in items where item.isVideo {
            recordFile(item, store: &store)
        }
        if store.files.count > maxFileEntries {
            store.files = Array(store.files.prefix(maxFileEntries))
        }
        saveStore(store)
    }

    /// Local match on cached file paths/names (no WebDAV). Strongest: full `href` path, then exact filename, then substring.
    static func matchSearchQuery(_ query: String) -> [WebDAVItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }

        var ranked: [(WebDAVItem, FileMatchRank)] = []
        for entry in loadStore().files {
            let item = entry.webDAVItem()
            guard item.isDirectory || item.isVideo else { continue }
            if let rank = fileMatchRank(needle: needle, item: item) {
                ranked.append((item, rank))
            }
        }
        ranked.sort { lhs, rhs in
            if lhs.1.rawValue != rhs.1.rawValue { return lhs.1.rawValue < rhs.1.rawValue }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }
        return dedupeItems(ranked.map(\.0))
    }

    /// True when the query matched a cached file by full path or exact filename (skip slow folder PROPFIND).
    static func hasStrongFileMatch(for query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        return loadStore().files.contains { entry in
            let item = entry.webDAVItem()
            guard item.isDirectory || item.isVideo else { return false }
            guard let rank = fileMatchRank(needle: needle, item: item) else { return false }
            return rank.rawValue <= FileMatchRank.exactName.rawValue
        }
    }

    /// Resume / pinned row — match cached file by `fileKey`, `href`, or name (no network).
    static func matchResumeEntry(_ entry: ResumeEntry) -> WebDAVItem? {
        let videos = loadStore().files.map { $0.webDAVItem() }.filter(\.isVideo)
        return WebDAVRenameReconcile.matchResumeEntry(entry, in: videos)
    }

    static func recordHits(from items: [WebDAVItem]) {
        guard !items.isEmpty else { return }
        var store = loadStore()
        for item in items {
            recordFile(item, store: &store)
            guard let path = listingPath(for: item), path != "/" else { continue }
            let normalized = WebDAVURLBuilder.directoryListingPath(path)
            store.folders.removeAll { WebDAVURLBuilder.pathsEqual($0.listingPath, normalized) }
            store.folders.insert(FolderEntry(listingPath: normalized, recordedAt: Date()), at: 0)
        }
        if store.folders.count > maxFolderEntries {
            store.folders = Array(store.folders.prefix(maxFolderEntries))
        }
        if store.files.count > maxFileEntries {
            store.files = Array(store.files.prefix(maxFileEntries))
        }
        saveStore(store)
        SearchDebugLog.log(
            "search location cache: \(store.files.count) file(s), \(store.folders.count) folder root(s) — newest \(store.files.first?.name ?? "?")"
        )
    }

    // MARK: - Private

    private static func fileMatchRank(needle: String, item: WebDAVItem) -> FileMatchRank? {
        let hrefL = item.href.lowercased()
        let nameL = item.name.lowercased()
        let normalizedPath = WebDAVURLBuilder.normalizedHrefPath(item.href).lowercased()
        if hrefL == needle || normalizedPath == needle || normalizedPath.hasSuffix("/\(needle)") {
            return .fullHref
        }
        if nameL == needle {
            return .exactName
        }
        if hrefL.contains(needle) || nameL.contains(needle) {
            return .substring
        }
        return nil
    }

    private static func recordFile(_ item: WebDAVItem, store: inout Store) {
        let parent =
            listingPath(for: item).map { WebDAVURLBuilder.directoryListingPath($0) }
            ?? WebDAVURLBuilder.directoryListingPath(item.href)
        store.files.removeAll { $0.href == item.href || $0.webDAVItem().fileKey == item.fileKey }
        store.files.insert(
            FileEntry(
                href: item.href,
                name: item.name,
                isDirectory: item.isDirectory,
                contentLength: item.contentLength,
                listingPath: parent,
                recordedAt: Date()
            ),
            at: 0
        )
    }

    private static func dedupeItems(_ items: [WebDAVItem]) -> [WebDAVItem] {
        var seen = Set<String>()
        var out: [WebDAVItem] = []
        for item in items {
            guard seen.insert(item.fileKey).inserted else { continue }
            out.append(item)
        }
        return out
    }

    private static func listingPath(for item: WebDAVItem) -> String? {
        if item.isDirectory {
            return WebDAVURLBuilder.directoryListingPath(item.href)
        }
        return WebDAVRenameReconcile.parentBrowsePath(forFileHref: item.href)
    }

    private static func loadStore() -> Store {
        if let data = UserDefaults.standard.data(forKey: storageKeyV2),
           let decoded = try? JSONDecoder().decode(Store.self, from: data) {
            return decoded
        }
        if let data = UserDefaults.standard.data(forKey: storageKeyV1),
           let folders = try? JSONDecoder().decode([FolderEntry].self, from: data) {
            let store = Store(folders: folders, files: [])
            saveStore(store)
            return store
        }
        return Store()
    }

    private static func saveStore(_ store: Store) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        UserDefaults.standard.set(data, forKey: storageKeyV2)
    }
}
