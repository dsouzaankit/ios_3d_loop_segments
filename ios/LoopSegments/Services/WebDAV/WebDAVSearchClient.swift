import Foundation

/// Filename search by walking WebDAV folders (slower than REST search).
enum WebDAVSearchClient {
    private static let maxFoldersToVisit = 250
    private static let maxResults = 80

    static func search(query: String, credentials: WebDAVCredentials) async throws -> [WebDAVItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }

        let client = WebDAVClient(credentials: credentials)
        var results: [WebDAVItem] = []
        var queue: [String] = ["/"]
        var visited = Set<String>()
        var foldersVisited = 0

        while !queue.isEmpty, results.count < maxResults, foldersVisited < maxFoldersToVisit {
            if Task.isCancelled { throw CancellationError() }

            let folderPath = queue.removeFirst()
            let listingPath = WebDAVURLBuilder.directoryListingPath(folderPath)
            if visited.contains(listingPath) { continue }
            visited.insert(listingPath)
            foldersVisited += 1

            let items: [WebDAVItem]
            do {
                items = try await client.list(path: listingPath)
            } catch {
                continue
            }

            for item in items {
                if item.name.lowercased().contains(needle) {
                    if item.isDirectory || item.isVideo {
                        results.append(item)
                        if results.count >= maxResults { break }
                    }
                }
                if item.isDirectory {
                    queue.append(item.href)
                }
            }
        }

        return results.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
