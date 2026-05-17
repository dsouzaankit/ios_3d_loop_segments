import Foundation

struct WebDAVItem: Identifiable, Hashable {
    let href: String
    let name: String
    let isDirectory: Bool
    let contentLength: Int64?

    var id: String { href }

    var fileKey: String {
        let data = Data(href.utf8)
        return data.sha256Hex
    }

    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "avi", "mov", "m4v", "webm"
    ]

    var isVideo: Bool {
        guard !isDirectory else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return Self.videoExtensions.contains(ext)
    }

    func mediaURL(credentials: WebDAVCredentials) -> URL {
        var base = credentials.region.baseURL
        let path = href.hasPrefix("/") ? String(href.dropFirst()) : href
        return base.appendingPathComponent(path)
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
