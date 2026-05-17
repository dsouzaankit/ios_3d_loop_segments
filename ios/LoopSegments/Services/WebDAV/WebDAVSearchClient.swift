import Foundation

/// Filename search by walking WebDAV folders (slower than REST search).
enum WebDAVSearchClient {
    private static let maxFoldersToVisit = 400
    private static let maxResults = 80

    static func search(query: String, credentials: WebDAVCredentials) async throws -> [WebDAVItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }

        let client = WebDAVClient(credentials: credentials)
        let roots = try await discoverSearchRoots(client: client)
        var results: [WebDAVItem] = []
        var queue = roots
        var visited = Set<String>()
        var foldersVisited = 0
        var listFailures = 0

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
                listFailures += 1
                continue
            }

            for item in items {
                let haystack = "\(item.href)/\(item.name)".lowercased()
                if haystack.contains(needle) {
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

        if results.isEmpty, foldersVisited > 0, listFailures == foldersVisited {
            throw WebDAVError.httpStatus(401)
        }
        return results.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// pCloud WebDAV root is often `/remote.php/dav/files/<user>/`, not flat children of `/`.
    private static func discoverSearchRoots(client: WebDAVClient) async throws -> [String] {
        let rootItems = try await client.list(path: "/")
        let directories = rootItems.filter(\.isDirectory)
        if directories.isEmpty {
            return ["/"]
        }
        if directories.count == 1 {
            return [WebDAVURLBuilder.directoryListingPath(directories[0].href)]
        }
        var roots = ["/"]
        for dir in directories {
            roots.append(WebDAVURLBuilder.directoryListingPath(dir.href))
        }
        return uniquePaths(roots)
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for path in paths {
            let normalized = WebDAVURLBuilder.directoryListingPath(path)
            if seen.insert(normalized).inserted {
                ordered.append(normalized)
            }
        }
        return ordered
    }
}
