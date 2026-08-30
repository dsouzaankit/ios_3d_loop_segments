import Foundation

enum WebDAVHTTPContext: Sendable {
    case generic
    case signIn
    case pausedFolderResolve
    case vanillaDownloadResume
    case sparseSourceRead
    case filesRootDiscovery
}

enum WebDAVHTTPMessages {
    static func requestFailed(_ statusCode: Int, context: WebDAVHTTPContext = .generic) -> String {
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
            return notFoundMessage(context: context)
        case 416:
            switch context {
            case .vanillaDownloadResume:
                return """
                pCloud range not satisfiable (HTTP 416). The on-disk partial may already be the full file — \
                retry export; the app will reconcile length from pCloud.
                """
            default:
                return """
                pCloud range not satisfiable (HTTP 416). The on-disk partial may already match pCloud — \
                retry export; the app will reconcile length from the server.
                """
            }
        default:
            return "pCloud request failed (HTTP \(statusCode))."
        }
    }

    private static func notFoundMessage(context: WebDAVHTTPContext) -> String {
        switch context {
        case .signIn:
            return """
            pCloud WebDAV not found (HTTP 404). Pick US or Europe to match my.pcloud.com \
            (the app tries both). Check Wi‑Fi and turn off VPN on the phone.
            """
        case .pausedFolderResolve:
            return """
            Saved pCloud folder not found (HTTP 404). The video may have moved or been renamed on pCloud — \
            not a problem with _working.mp4 on the phone. Use Browse or Search in Browse, then export again.
            """
        case .vanillaDownloadResume:
            return """
            pCloud file not found while downloading (HTTP 404). The file may have moved, or the download offset is \
            past the file end (stale _vanilla_download.* resume). Clear the partial in pcld_ios_media or re-pick in Browse.
            """
        case .sparseSourceRead:
            return """
            pCloud source not found (HTTP 404). The remote file may have moved or been renamed. \
            _working.mp4 on the phone may still be partial — re-pick the file in Browse to continue.
            """
        case .filesRootDiscovery:
            return """
            Could not find your pCloud files root over WebDAV (HTTP 404). Sign out, match US/Europe to my.pcloud.com, \
            and sign in again.
            """
        case .generic:
            return """
            pCloud WebDAV not found (HTTP 404). The path may have moved, or Sign in may need the other datacenter (US/Europe).
            """
        }
    }
}
