import Foundation

enum PCloudRegion: String, CaseIterable, Identifiable, Codable {
    case us
    case eu

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .us: return "United States"
        case .eu: return "Europe"
        }
    }

    var webDAVHost: String {
        switch self {
        case .us: return "webdav.pcloud.com"
        case .eu: return "ewebdav.pcloud.com"
        }
    }

    var baseURL: URL {
        URL(string: "https://\(webDAVHost)/")!
    }

    /// JSON API host for search and other REST calls (same region as WebDAV).
    var apiHost: String {
        switch self {
        case .us: return "api.pcloud.com"
        case .eu: return "eapi.pcloud.com"
        }
    }

    var apiBaseURL: URL {
        URL(string: "https://\(apiHost)/")!
    }

    var alternate: PCloudRegion {
        switch self {
        case .us: return .eu
        case .eu: return .us
        }
    }
}
