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

    /// True when href is `/remote.php/dav/files/<user>/` (not a virtual folder like `/_My Music_/`).
    static func isValidFilesRoot(_ href: String?) -> Bool {
        guard let href, !href.isEmpty else { return false }
        return isUserFilesRoot(WebDAVURLBuilder.directoryListingPath(href))
    }

    static func filesRoot(credentials: WebDAVCredentials) async throws -> String {
        if let cached = credentials.webDAVFilesRoot, isValidFilesRoot(cached) {
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
            let fallback = WebDAVURLBuilder.directoryListingPath(path)
            if isUserFilesRoot(fallback) { return fallback }
        }
        for item in items where item.isDirectory {
            let href = WebDAVURLBuilder.directoryListingPath(item.href)
            if isUserFilesRoot(href) { return href }
        }
        throw WebDAVError.httpStatus(404)
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
