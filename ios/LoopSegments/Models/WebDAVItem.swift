import Foundation

struct WebDAVItem: Identifiable, Hashable {
    let href: String
    let name: String
    let isDirectory: Bool
    let contentLength: Int64?
    let lastModified: Date?

    init(
        href: String,
        name: String,
        isDirectory: Bool,
        contentLength: Int64?,
        lastModified: Date? = nil
    ) {
        self.href = href
        self.name = name
        self.isDirectory = isDirectory
        self.contentLength = contentLength
        self.lastModified = lastModified
    }

    var id: String { href }

    var fileKey: String {
        let data = Data(href.utf8)
        return data.sha256Hex
    }

    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "avi", "mov", "m4v", "webm", "wmv", "ts"
    ]

    var isVideo: Bool {
        guard !isDirectory else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return Self.videoExtensions.contains(ext)
    }

    func mediaURL(credentials: WebDAVCredentials) -> URL {
        WebDAVURLBuilder.fileURL(href: href, baseURL: credentials.region.baseURL)
    }
}

private extension Data {
    var sha256Hex: String {
        // Lightweight stable id without CryptoKit import in model layer
        var hash: UInt64 = 5381
        for byte in self {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "%016llx", hash)
    }
}
