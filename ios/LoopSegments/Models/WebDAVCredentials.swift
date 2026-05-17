import Foundation

struct WebDAVCredentials: Codable, Equatable {
    var region: PCloudRegion
    var email: String
    var password: String

    var authorizationHeaderValue: String {
        let raw = "\(email):\(password)"
        let data = Data(raw.utf8)
        return "Basic \(data.base64EncodedString())"
    }
}
