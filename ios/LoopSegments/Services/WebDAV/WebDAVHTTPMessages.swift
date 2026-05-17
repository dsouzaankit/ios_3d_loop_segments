import Foundation

enum WebDAVHTTPMessages {
    static func requestFailed(_ statusCode: Int) -> String {
        switch statusCode {
        case 401:
            return """
            pCloud login rejected (HTTP 401). Sign out → Sign in again with the correct \
            US or Europe region. If 2FA is on, create an app password at my.pcloud.com \
            (Settings → Security → App passwords) and use that instead of your main password.
            """
        case 403:
            return "pCloud denied access (HTTP 403). Check folder permissions or sign in again."
        default:
            return "pCloud request failed (HTTP \(statusCode))."
        }
    }
}
