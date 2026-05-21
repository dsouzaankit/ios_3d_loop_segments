import Combine
import Foundation

struct FolderBookmark: Codable, Identifiable, Hashable {
    /// Normalized WebDAV listing path (`/remote.php/dav/files/.../folder/`).
    var listingPath: String
    var displayName: String
    var updatedAt: Date

    var id: String { listingPath }
}

@MainActor
final class FolderBookmarkStore: ObservableObject {
    static let shared = FolderBookmarkStore()

    @Published private(set) var revision = 0

    private static let storageKey = "folder_bookmarks"
    private let defaults = UserDefaults.standard
    private var cache: [FolderBookmark]?

    func bookmarks() -> [FolderBookmark] {
        load().sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func isBookmarked(listingPath: String) -> Bool {
        let path = WebDAVURLBuilder.directoryListingPath(listingPath)
        return load().contains { WebDAVURLBuilder.pathsEqual($0.listingPath, path) }
    }

    func toggleBookmark(listingPath: String, displayName: String) {
        let path = WebDAVURLBuilder.directoryListingPath(listingPath)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path != "/", !name.isEmpty else { return }

        var list = load()
        if let index = list.firstIndex(where: { WebDAVURLBuilder.pathsEqual($0.listingPath, path) }) {
            list.remove(at: index)
        } else {
            list.append(
                FolderBookmark(
                    listingPath: path,
                    displayName: name,
                    updatedAt: Date()
                )
            )
        }
        save(list)
    }

    func remove(_ bookmark: FolderBookmark) {
        var list = load()
        list.removeAll { $0.listingPath == bookmark.listingPath }
        save(list)
    }

    private func load() -> [FolderBookmark] {
        if let cache { return cache }
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([FolderBookmark].self, from: data) else {
            cache = []
            return []
        }
        cache = decoded
        return decoded
    }

    private func save(_ list: [FolderBookmark]) {
        cache = list
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.storageKey)
        } else {
            defaults.removeObject(forKey: Self.storageKey)
        }
        revision += 1
    }
}
