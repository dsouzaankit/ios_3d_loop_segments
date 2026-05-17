import Foundation

/// Discovers `/remote.php/dav/files/<user>/` for mapping REST search paths to WebDAV hrefs.
enum PCloudWebDAVRootResolver {
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]

    static func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    static func filesRoot(credentials: WebDAVCredentials) async throws -> String {
        if let cached = credentials.webDAVFilesRoot, !cached.isEmpty {
            return WebDAVURLBuilder.directoryListingPath(cached)
        }
        lock.lock()
        if let hit = cache[credentials.email.lowercased()] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let discovered = try await discover(client: WebDAVClient(credentials: credentials))
        lock.lock()
        cache[credentials.email.lowercased()] = discovered
        lock.unlock()
        return discovered
    }

    private static func discover(client: WebDAVClient, path: String = "/", depth: Int = 0) async throws -> String {
        guard depth < 6 else {
            return WebDAVURLBuilder.directoryListingPath(path)
        }
        let items = try await client.list(path: path)
        for item in items where item.isDirectory {
            let href = WebDAVURLBuilder.directoryListingPath(item.href)
            if isUserFilesRoot(href) {
                return href
            }
            if depth < 5, shouldDescend(href) {
                if let nested = try? await discover(client: client, path: href, depth: depth + 1),
                   isUserFilesRoot(nested) {
                    return nested
                }
            }
        }
        if path != "/" {
            return WebDAVURLBuilder.directoryListingPath(path)
        }
        for item in items where item.isDirectory {
            return WebDAVURLBuilder.directoryListingPath(item.href)
        }
        return "/"
    }

    private static func isUserFilesRoot(_ href: String) -> Bool {
        let parts = href.split(separator: "/").map(String.init)
        guard parts.count >= 4 else { return false }
        let lower = href.lowercased()
        return lower.contains("remote.php") && lower.contains("/dav/files/")
    }

    private static func shouldDescend(_ href: String) -> Bool {
        let lower = href.lowercased()
        return lower.contains("remote.php") || lower.hasSuffix("/dav/") || lower.contains("/dav/files")
    }
}
