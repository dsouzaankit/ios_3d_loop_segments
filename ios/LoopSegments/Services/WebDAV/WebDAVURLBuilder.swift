import Foundation

/// Build HTTPS URLs for pCloud WebDAV file paths from PROPFIND `href` values.
enum WebDAVURLBuilder {
    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~!'()*")
        return set
    }()

    static func fileURL(href: String, baseURL: URL) -> URL {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if let absolute = URL(string: trimmed),
           let scheme = absolute.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            return absolute
        }

        var path = trimmed
        if !path.hasPrefix("/") { path = "/" + path }

        let decoded = path.removingPercentEncoding ?? path
        let segments = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let encodedPath = segments.map { encodeSegment($0) }.joined(separator: "/")
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

    static func displayName(fromHref href: String) -> String {
        let path = href.split(separator: "?", maxSplits: 1).first.map(String.init) ?? href
        let leaf = (path as NSString).lastPathComponent
        return leaf.removingPercentEncoding ?? leaf
    }

    private static func encodeSegment(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? segment
    }
}
