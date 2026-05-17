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
}
