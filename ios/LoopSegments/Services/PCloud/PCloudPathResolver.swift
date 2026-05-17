import Foundation

/// Resolves REST metadata (often without `path`) into WebDAV browse hrefs.
enum PCloudPathResolver {
    static func resolveSearchItems(
        entries: [[String: Any]],
        credentials: WebDAVCredentials,
        apiClient: PCloudAPIClient
    ) async throws -> [WebDAVItem] {
        let webDAVRoot = try await PCloudWebDAVRootResolver.filesRoot(credentials: credentials)
        var results: [WebDAVItem] = []
        results.reserveCapacity(entries.count)

        for entry in entries {
            let enriched = try await enrichPath(entry, apiClient: apiClient)
            guard let item = PCloudMetadataParsing.webDAVItem(
                from: enriched,
                webDAVFilesRoot: webDAVRoot
            ) else {
                continue
            }
            let isFolder = item.isDirectory
            if PCloudMetadataParsing.isBrowsableVideo(name: item.name, metadata: enriched, isFolder: isFolder) {
                results.append(item)
            }
        }
        return results.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func enrichPath(
        _ metadata: [String: Any],
        apiClient: PCloudAPIClient
    ) async throws -> [String: Any] {
        if let path = metadata["path"] as? String, !path.isEmpty {
            return metadata
        }
        if PCloudMetadataParsing.boolField(metadata["isfolder"]),
           let folderId = PCloudMetadataParsing.int64Field(metadata["folderid"]),
           let path = try await apiClient.apiPath(folderId: folderId) {
            var copy = metadata
            copy["path"] = path
            return copy
        }
        if let fileId = PCloudMetadataParsing.int64Field(metadata["fileid"]),
           let path = try await apiClient.apiPath(fileId: fileId) {
            var copy = metadata
            copy["path"] = path
            return copy
        }
        return metadata
    }
}
