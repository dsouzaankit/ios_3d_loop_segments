import Foundation

/// Filename search by walking the pCloud folder tree via `listfolder` (reliable when `search` returns nothing).
enum PCloudAPIFolderSearch {
    private static let maxFoldersToVisit = 800
    private static let maxResults = 80

    static func search(
        query: String,
        credentials: WebDAVCredentials,
        apiClient: PCloudAPIClient
    ) async throws -> [WebDAVItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }

        var matches: [[String: Any]] = []
        matches.reserveCapacity(maxResults)
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

        return try await PCloudPathResolver.resolveSearchItems(
            entries: matches,
            credentials: credentials,
            apiClient: apiClient
        )
    }
}
