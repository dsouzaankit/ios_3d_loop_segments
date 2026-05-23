import Foundation

enum WebDAVHTTPMessages {
    static func requestFailed(_ statusCode: Int) -> String {
        switch statusCode {
        case 401:
            return """
            pCloud login rejected (HTTP 401). Check email and password, then sign in again. \
            Pick US or Europe to match my.pcloud.com (the app tries both). \
            If you use two-factor authentication, create a security password at my.pcloud.com → \
            Settings → Security and use that here instead of your main password.
            """
        case 403:
            return "pCloud denied access (HTTP 403). Check folder permissions or sign in again."
        case 404:
            return """
            pCloud request failed (HTTP 404). The file may have moved, or the download offset is past the \
            file end (stale resume). Clear _vanilla_download.* in Exports or retry export to start fresh.
            """
        case 416:
            return """
            pCloud range not satisfiable (HTTP 416). The on-disk partial may already be the full file — \
            retry export; the app will reconcile length from pCloud.
            """
        default:
            return "pCloud request failed (HTTP \(statusCode))."
        }
    }
}
