import Foundation

/// Last search-hit folder roots (WebDAV listing paths), preferred before bookmarks + current Browse folder.
enum SearchLocationCache {
    static let maxEntries = 100
    private static let storageKey = "search_location_cache_v1"

    private struct Entry: Codable {
        var listingPath: String
        var recordedAt: Date
    }

    static func listingPaths() -> [String] {
        load()
            .map(\.listingPath)
            .filter { WebDAVURLBuilder.directoryListingPath($0) != "/" }
    }

    static func recordHits(from items: [WebDAVItem]) {
        guard !items.isEmpty else { return }
        var entries = load()
        for item in items {
            guard let path = listingPath(for: item), path != "/" else { continue }
            let normalized = WebDAVURLBuilder.directoryListingPath(path)
            entries.removeAll { WebDAVURLBuilder.pathsEqual($0.listingPath, normalized) }
            entries.insert(Entry(listingPath: normalized, recordedAt: Date()), at: 0)
        }
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save(entries)
        SearchDebugLog.log(
            "search location cache: \(entries.count) folder root(s) — newest \(entries.first?.listingPath ?? "?")"
        )
    }

    private static func listingPath(for item: WebDAVItem) -> String? {
        if item.isDirectory {
            return WebDAVURLBuilder.directoryListingPath(item.href)
        }
        return WebDAVRenameReconcile.parentBrowsePath(forFileHref: item.href)
    }

    private static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return decoded
    }

    private static func save(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
