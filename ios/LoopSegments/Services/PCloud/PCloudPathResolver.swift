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
        let stats = ResolveStats()

        var indexed: [(Int, WebDAVItem)] = []
        indexed.reserveCapacity(capped.count)

        try await withThrowingTaskGroup(of: ResolveOutcome.self) { group in
            var inFlight = 0
            var nextIndex = 0

            func enqueue(_ index: Int) {
                let entry = capped[index]
                group.addTask {
                    try await resolveOne(
                        index: index,
                        entry: entry,
                        webDAVRoot: webDAVRoot,
                        apiClient: apiClient
                    )
                }
            }

            while nextIndex < capped.count, inFlight < pathLookupConcurrency {
                enqueue(nextIndex)
                nextIndex += 1
                inFlight += 1
            }

            while inFlight > 0 {
                if Task.isCancelled { throw CancellationError() }
                let outcome = try await group.next() ?? .skipped(reason: "empty", name: "?")
                inFlight -= 1
                switch outcome {
                case .resolved(let index, let item):
                    indexed.append((index, item))
                    stats.resolved += 1
                case .skipped(let reason, let name):
                    stats.recordSkip(reason: reason, name: name)
                }
                if nextIndex < capped.count {
                    enqueue(nextIndex)
                    nextIndex += 1
                    inFlight += 1
                }
            }
        }

        SearchDebugLog.logResolveSummary(
            inputCount: capped.count,
            resolvedCount: stats.resolved,
            skippedNoHref: stats.skippedNoHref,
            skippedNotBrowsable: stats.skippedNotBrowsable,
            webDAVRoot: webDAVRoot,
            sampleDrops: stats.sampleDrops
        )

        return indexed
            .sorted { $0.0 < $1.0 }
            .map(\.1)
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private enum ResolveOutcome {
        case resolved(index: Int, item: WebDAVItem)
        case skipped(reason: String, name: String)
    }

    private final class ResolveStats: @unchecked Sendable {
        var resolved = 0
        var skippedNoHref = 0
        var skippedNotBrowsable = 0
        var sampleDrops: [String] = []
        private let lock = NSLock()

        func recordSkip(reason: String, name: String) {
            lock.lock()
            defer { lock.unlock() }
            switch reason {
            case "noWebDAVItem": skippedNoHref += 1
            case "notBrowsable": skippedNotBrowsable += 1
            default: break
            }
            if sampleDrops.count < 8 {
                sampleDrops.append("\(name): \(reason)")
            }
        }
    }

    private static func resolveOne(
        index: Int,
        entry: [String: Any],
        webDAVRoot: String?,
        apiClient: PCloudAPIClient
    ) async throws -> ResolveOutcome {
        let normalized = PCloudMetadataParsing.normalizeSearchMetadata(entry)
        let displayName = normalized["name"] as? String ?? normalized["id"].map { "\($0)" } ?? "?"
        let enriched = try await enrichPath(normalized, apiClient: apiClient)
        guard let item = PCloudMetadataParsing.webDAVItem(
            from: enriched,
            webDAVFilesRoot: webDAVRoot
        ) else {
            let path = enriched["path"] as? String ?? "-"
            let ids = PCloudMetadataParsing.resolvedIds(from: enriched)
            let detail = "path=\(path) fileId=\(ids.fileId.map(String.init) ?? "-") root=\(webDAVRoot ?? "nil")"
            return .skipped(reason: "noWebDAVItem", name: "\(displayName) \(detail)")
        }
        let isFolder = item.isDirectory
        guard PCloudMetadataParsing.isBrowsableVideo(name: item.name, metadata: enriched, isFolder: isFolder) else {
            return .skipped(reason: "notBrowsable", name: item.name)
        }
        return .resolved(index: index, item: item)
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
