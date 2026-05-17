import Foundation

enum WebDAVHTTPMessages {
    static func requestFailed(_ statusCode: Int) -> String {
        switch statusCode {
        case 401:
            return """
            pCloud login rejected (HTTP 401). Sign out → Sign in again with the correct \
            US or Europe region and an app password if 2FA is on (my.pcloud.com → Settings → \
            Security → App passwords). If this happens ~30s into export, install build 1.2.5+ \
            (avoids system HTTP without auth).
            """
        case 403:
            return "pCloud denied access (HTTP 403). Check folder permissions or sign in again."
        default:
            return "pCloud request failed (HTTP \(statusCode))."
        }
    }
}
