import Foundation

/// Resolves REST metadata (often without `path`) into WebDAV browse hrefs.
enum PCloudPathResolver {
    private static let maxResults = 80
    private static let pathLookupConcurrency = 12

    static func resolveSearchItems(
        entries: [[String: Any]],
        credentials: WebDAVCredentials,
        apiClient: PCloudAPIClient
    ) async throws -> [WebDAVItem] {
        let webDAVRoot = (try? await PCloudWebDAVRootResolver.filesRoot(credentials: credentials))
            ?? credentials.webDAVFilesRoot
        let capped = Array(entries.prefix(maxResults))

        var indexed: [(Int, WebDAVItem)] = []
        indexed.reserveCapacity(capped.count)

        try await withThrowingTaskGroup(of: (Int, WebDAVItem?).self) { group in
            var inFlight = 0
            var nextIndex = 0

            func enqueue(_ index: Int) {
                let entry = capped[index]
                group.addTask {
                    let item = try await resolveOne(
                        entry: entry,
                        webDAVRoot: webDAVRoot,
                        apiClient: apiClient
                    )
                    return (index, item)
                }
            }

            while nextIndex < capped.count, inFlight < pathLookupConcurrency {
                enqueue(nextIndex)
                nextIndex += 1
                inFlight += 1
            }

            while inFlight > 0 {
                if Task.isCancelled { throw CancellationError() }
                let (index, item) = try await group.next() ?? (0, nil)
                inFlight -= 1
                if let item {
                    indexed.append((index, item))
                }
                if nextIndex < capped.count {
                    enqueue(nextIndex)
                    nextIndex += 1
                    inFlight += 1
                }
            }
        }

        return indexed
            .sorted { $0.0 < $1.0 }
            .map(\.1)
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private static func resolveOne(
        entry: [String: Any],
        webDAVRoot: String?,
        apiClient: PCloudAPIClient
    ) async throws -> WebDAVItem? {
        let normalized = PCloudMetadataParsing.normalizeSearchMetadata(entry)
        let enriched = try await enrichPath(normalized, apiClient: apiClient)
        guard let item = PCloudMetadataParsing.webDAVItem(
            from: enriched,
            webDAVFilesRoot: webDAVRoot
        ) else {
            return nil
        }
        let isFolder = item.isDirectory
        guard PCloudMetadataParsing.isBrowsableVideo(name: item.name, metadata: enriched, isFolder: isFolder) else {
            return nil
        }
        return item
    }

    private static func enrichPath(
        _ metadata: [String: Any],
        apiClient: PCloudAPIClient
    ) async throws -> [String: Any] {
        if let path = metadata["path"] as? String, !path.isEmpty {
            return metadata
        }
        let ids = PCloudMetadataParsing.resolvedIds(from: metadata)
        if PCloudMetadataParsing.boolField(metadata["isfolder"]),
           let folderId = ids.folderId,
           let path = try await apiClient.apiPath(folderId: folderId) {
            var copy = metadata
            copy["path"] = path
            return copy
        }
        if let fileId = ids.fileId,
           let path = try await apiClient.apiPath(fileId: fileId) {
            var copy = metadata
            copy["path"] = path
            return copy
        }
        return metadata
    }
}
