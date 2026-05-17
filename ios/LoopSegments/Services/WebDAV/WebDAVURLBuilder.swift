import Foundation

/// Build HTTPS URLs for pCloud WebDAV file paths from PROPFIND `href` values.
enum WebDAVURLBuilder {
    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~!'()*")
        return set
    }()

    /// Path-only href for browsing (`/folder/`). Strips `https://webdav…` so region + auth stay consistent.
    static func normalizedHrefPath(_ href: String) -> String {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            var path = url.path
            if path.isEmpty { path = "/" }
            if let query = url.query, !query.isEmpty {
                path += "?\(query)"
            }
            return path
        }

        // Do not prefix "/" here — relative PROPFIND hrefs must stay relative until resolveHref.
        return trimmed
    }

    static func fileURL(href: String, baseURL: URL) -> URL {
        let path = normalizedHrefPath(href)
        return fileURLForPath(path, baseURL: baseURL)
    }

    static func displayName(fromHref href: String) -> String {
        let path = normalizedHrefPath(href).split(separator: "?", maxSplits: 1).first.map(String.init) ?? href
        let leaf = (path as NSString).lastPathComponent
        return leaf.removingPercentEncoding ?? leaf
    }

    /// Combine PROPFIND `href` with the directory that was listed (fixes relative `subdir/` entries).
    static func resolveHref(_ href: String, relativeTo listingPath: String) -> String {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") {
            return normalizedHrefPath(trimmed)
        }

        if trimmed.hasPrefix("/") {
            return normalizedHrefPath(trimmed)
        }

        var base = normalizedHrefPath(listingPath)
        if base == "/" {
            return normalizedHrefPath("/\(trimmed)")
        }
        if !base.hasSuffix("/") {
            base += "/"
        }
        return normalizedHrefPath(base + trimmed)
    }

    static func directoryListingPath(_ path: String) -> String {
        let normalized = normalizedHrefPath(path)
        if normalized == "/" { return "/" }
        return normalized.hasSuffix("/") ? normalized : normalized + "/"
    }

    static func pathsEqual(_ a: String, _ b: String) -> Bool {
        let lhs = directoryListingPath(a).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rhs = directoryListingPath(b).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return lhs == rhs
    }

    private static func fileURLForPath(_ path: String, baseURL: URL) -> URL {
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let decoded = pathOnly.removingPercentEncoding ?? pathOnly
        let segments = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let encodedPath = segments.map { encodeSegment($0) }.joined(separator: "/")
            if segments.isEmpty { return baseURL }
            return URL(string: "\(base)/\(encodedPath)")!
        }

        if segments.isEmpty {
            return baseURL
        }
        components.percentEncodedPath = "/" + segments.map { encodeSegment($0) }.joined(separator: "/")
        guard let url = components.url else {
            let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let encodedPath = segments.map { encodeSegment($0) }.joined(separator: "/")
            return URL(string: "\(base)/\(encodedPath)")!
        }
        return url
    }

    private static func encodeSegment(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? segment
    }
}
