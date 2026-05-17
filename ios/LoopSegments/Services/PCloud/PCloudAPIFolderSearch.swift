import Foundation

/// Filename search via shallow pCloud `listfolder` BFS (no full-tree recursive — that can hang).
enum PCloudAPIFolderSearch {
    private static let maxFoldersToVisit = 120
    private static let maxResults = 80
    static let maxRecursiveEntriesForAPI = 25_000

    static func search(
        query: String,
        credentials: WebDAVCredentials,
        apiClient: PCloudAPIClient
    ) async throws -> [WebDAVItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }

        let matches = try await walkFolders(needle: needle, apiClient: apiClient)
        guard !matches.isEmpty else { return [] }

        return try await PCloudPathResolver.resolveSearchItems(
            entries: matches,
            credentials: credentials,
            apiClient: apiClient
        )
    }

    private static func filterMatches(needle: String, entries: [[String: Any]]) -> [[String: Any]] {
        var matches: [[String: Any]] = []
        matches.reserveCapacity(min(maxResults, entries.count))
        for entry in entries {
            guard let name = entry["name"] as? String, !name.isEmpty else { continue }
            if PCloudMetadataParsing.matchesSearchNeedle(needle, metadata: entry, name: name) {
                let isFolder = PCloudMetadataParsing.boolField(entry["isfolder"])
                if PCloudMetadataParsing.isBrowsableVideo(name: name, metadata: entry, isFolder: isFolder) {
                    matches.append(entry)
                    if matches.count >= maxResults { break }
                }
            }
        }
        return matches
    }

    private static func walkFolders(needle: String, apiClient: PCloudAPIClient) async throws -> [[String: Any]] {
        var matches: [[String: Any]] = []
        var queue: [Int64] = [0]
        var visited = Set<Int64>()
        var foldersVisited = 0

        while !queue.isEmpty, matches.count < maxResults, foldersVisited < maxFoldersToVisit {
            if Task.isCancelled { throw CancellationError() }

            let folderId = queue.removeFirst()
            guard visited.insert(folderId).inserted else { continue }
            foldersVisited += 1

            let contents: [[String: Any]]
            do {
                contents = try await apiClient.listFolderContents(folderId: folderId)
            } catch {
                continue
            }

            for entry in contents {
                guard let name = entry["name"] as? String, !name.isEmpty else { continue }
                if PCloudMetadataParsing.matchesSearchNeedle(needle, metadata: entry, name: name) {
                    let isFolder = PCloudMetadataParsing.boolField(entry["isfolder"])
                    if PCloudMetadataParsing.isBrowsableVideo(name: name, metadata: entry, isFolder: isFolder) {
                        matches.append(entry)
                        if matches.count >= maxResults { break }
                    }
                }
                if PCloudMetadataParsing.boolField(entry["isfolder"]),
                   let childId = PCloudMetadataParsing.int64Field(entry["folderid"]) {
                    queue.append(childId)
                }
            }
        }
        return matches
    }
}
