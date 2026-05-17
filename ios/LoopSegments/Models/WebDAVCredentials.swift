import Foundation

struct WebDAVCredentials: Codable, Equatable {
    var region: PCloudRegion
    var email: String
    var password: String
    /// pCloud REST token from sign-in (search). Optional for keychain entries saved before API verify.
    var apiAuthToken: String?
    var apiAuthHost: String?
    /// e.g. `/remote.php/dav/files/user@email.com/` — used to map API `/path` hits to WebDAV hrefs.
    var webDAVFilesRoot: String?

    var authorizationHeaderValue: String {
        let raw = "\(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\(password)"
        let data = Data(raw.utf8)
        return "Basic \(data.base64EncodedString())"
    }
}
