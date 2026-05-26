import Foundation

/// Browse search: optional pCloud REST (`search` + folder index) vs WebDAV-only (bookmarks + browse).
enum PCloudSearchSettings {
    static let restAPISearchEnabledKey = "pcloud_rest_api_search_enabled"

    /// Off by default — WebDAV folder walk on bookmarks + current path only (no API token required).
    static var restAPISearchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: restAPISearchEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: restAPISearchEnabledKey) }
    }
}
