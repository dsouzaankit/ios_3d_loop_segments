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
        quickRootDiscovery: Bool = false,
        timeoutSeconds: Double = 0,
        progress: (@Sendable (WebDAVSearchProgress) -> Void)? = nil
    ) async throws -> [WebDAVItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }

        let started = Date()
        let folderLimit = max(1, maxFoldersToVisit)
        var throttle = ProgressThrottle(minInterval: 0.2)

        func elapsedSeconds() -> Double {
            Date().timeIntervalSince(started)
        }

        func report(
            phase: WebDAVSearchProgress.Phase,
            folderPath: String? = nil,
            foldersVisited: Int = 0,
            queueDepth: Int = 0,
            resultsFound: Int = 0,
            force: Bool = false
        ) {
            guard let progress else { return }
            let snapshot = WebDAVSearchProgress(
                phase: phase,
                folderPath: folderPath,
                foldersVisited: foldersVisited,
                folderLimit: folderLimit,
                queueDepth: queueDepth,
                resultsFound: resultsFound,
                elapsedSeconds: elapsedSeconds(),
                timeoutSeconds: timeoutSeconds
            )
            throttle.fire(snapshot, force: force, handler: progress)
        }

        report(phase: .discoveringRoots, force: true)

        let client = WebDAVClient(credentials: credentials)
        let roots = try await discoverSearchRoots(
            client: client,
            credentials: credentials,
            extraRoots: extraRoots,
            quick: quickRootDiscovery
        )
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

            report(
                phase: .listingFolder,
                folderPath: listingPath,
                foldersVisited: foldersVisited,
                queueDepth: queue.count,
                resultsFound: results.count,
                force: foldersVisited == 1
            )

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

            report(
                phase: .listingFolder,
                folderPath: listingPath,
                foldersVisited: foldersVisited,
                queueDepth: queue.count,
                resultsFound: results.count
            )
        }

        report(
            phase: .listingFolder,
            folderPath: nil,
            foldersVisited: foldersVisited,
            queueDepth: 0,
            resultsFound: results.count,
            force: true
        )

        if results.isEmpty, foldersVisited > 0, listFailures == foldersVisited {
            throw WebDAVError.httpStatus(401)
        }
        return results.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// pCloud WebDAV root is often `/remote.php/dav/files/<user>/`, not flat children of `/`.
    /// `extraRoots` (recent search folders, bookmarks, browse path) stay **first** — not moved after user files root.
    private static func discoverSearchRoots(
        client: WebDAVClient,
        credentials: WebDAVCredentials,
        extraRoots: [String],
        quick: Bool
    ) async throws -> [String] {
        let pinned = dedupePreserveOrder(
            extraRoots.map { WebDAVURLBuilder.directoryListingPath($0) }
        )
        var supplemental: [String] = []
        if let stored = credentials.webDAVFilesRoot, !stored.isEmpty {
            supplemental.append(WebDAVURLBuilder.directoryListingPath(stored))
        }
        if let userRoot = try? await PCloudWebDAVRootResolver.filesRoot(credentials: credentials) {
            supplemental.append(userRoot)
        }
        guard !quick else {
            return pinned + prioritizeUserRoot(supplemental)
        }
        supplemental.append("/")
        let top = try await client.list(path: "/")
        for dir in top where dir.isDirectory {
            let path = WebDAVURLBuilder.directoryListingPath(dir.href)
            supplemental.append(path)
            let lower = path.lowercased()
            if lower.contains("remote.php") || lower.hasSuffix("/dav/") {
                if let children = try? await client.list(path: path) {
                    for child in children where child.isDirectory {
                        supplemental.append(WebDAVURLBuilder.directoryListingPath(child.href))
                    }
                }
            }
        }
        return pinned + prioritizeUserRoot(supplemental)
    }

    private static func dedupePreserveOrder(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in paths {
            let normalized = WebDAVURLBuilder.directoryListingPath(path)
            guard seen.insert(normalized).inserted else { continue }
            out.append(normalized)
        }
        return out
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

    private struct ProgressThrottle: Sendable {
        let minInterval: Double
        private var lastAt: Date?
        private var lastVisited = 0

        init(minInterval: Double) {
            self.minInterval = minInterval
        }

        mutating func fire(
            _ snapshot: WebDAVSearchProgress,
            force: Bool,
            handler: @Sendable (WebDAVSearchProgress) -> Void
        ) {
            let now = Date()
            let visited = snapshot.foldersVisited
            let intervalElapsed: Bool
            if let lastAt {
                intervalElapsed = now.timeIntervalSince(lastAt) >= minInterval
            } else {
                intervalElapsed = true
            }
            guard force || intervalElapsed || visited - lastVisited >= 4 else { return }
            lastAt = now
            lastVisited = visited
            handler(snapshot)
        }
    }
}
