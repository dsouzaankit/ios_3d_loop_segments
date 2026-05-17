import Foundation

/// Filename search by walking WebDAV folders (slower than REST search).
enum WebDAVSearchClient {
    private static let maxFoldersToVisitDefault = 1200
    private static let maxResults = 80

    static func search(
        query: String,
        credentials: WebDAVCredentials,
        extraRoots: [String] = [],
        maxFoldersToVisit: Int = maxFoldersToVisitDefault,
        quickRootDiscovery: Bool = false
    ) async throws -> [WebDAVItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }

        let client = WebDAVClient(credentials: credentials)
        let roots = try await discoverSearchRoots(
            client: client,
            credentials: credentials,
            extraRoots: extraRoots,
            quick: quickRootDiscovery
        )
        let folderLimit = max(1, maxFoldersToVisit)
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
                let nameMatch = item.name.lowercased().contains(needle)
                if haystack.contains(needle) || nameMatch {
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
    private static func discoverSearchRoots(
        client: WebDAVClient,
        credentials: WebDAVCredentials,
        extraRoots: [String],
        quick: Bool
    ) async throws -> [String] {
        var roots: [String] = extraRoots.map { WebDAVURLBuilder.directoryListingPath($0) }
        if let stored = credentials.webDAVFilesRoot, !stored.isEmpty {
            roots.append(WebDAVURLBuilder.directoryListingPath(stored))
        }
        if let userRoot = try? await PCloudWebDAVRootResolver.filesRoot(credentials: credentials) {
            roots.append(userRoot)
        }
        guard !quick else {
            return prioritizeUserRoot(roots)
        }
        roots.append("/")
        let top = try await client.list(path: "/")
        for dir in top where dir.isDirectory {
            let path = WebDAVURLBuilder.directoryListingPath(dir.href)
            roots.append(path)
            let lower = path.lowercased()
            if lower.contains("remote.php") || lower.hasSuffix("/dav/") {
                if let children = try? await client.list(path: path) {
                    for child in children where child.isDirectory {
                        roots.append(WebDAVURLBuilder.directoryListingPath(child.href))
                    }
                }
            }
        }
        return prioritizeUserRoot(roots)
    }

    private static func prioritizeUserRoot(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var userFiles: [String] = []
        var other: [String] = []
        for path in paths {
            let normalized = WebDAVURLBuilder.directoryListingPath(path)
            guard seen.insert(normalized).inserted else { continue }
            let lower = normalized.lowercased()
            if lower.contains("remote.php") && lower.contains("/dav/files/") {
                userFiles.append(normalized)
            } else {
                other.append(normalized)
            }
        }
        return userFiles + other
    }
}
