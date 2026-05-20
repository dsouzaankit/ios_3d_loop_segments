import Foundation

final class WebDAVClient {
    private let credentials: WebDAVCredentials

    init(credentials: WebDAVCredentials) {
        self.credentials = credentials
    }

    func list(path: String) async throws -> [WebDAVItem] {
        try await list(path: path, credentials: credentials, retriedAuth: false)
    }

    /// Lightweight sign-in check (PROPFIND Depth 0 — no folder children listing).
    func verifyAccess(path: String = "/") async throws {
        try await verifyAccess(path: path, credentials: credentials, retriedAuth: false)
    }

    private func verifyAccess(
        path: String,
        credentials: WebDAVCredentials,
        retriedAuth: Bool
    ) async throws {
        let listingURL = resolveURL(for: path)
        var request = URLRequest(url: listingURL)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.authorizationHeaderValue, forHTTPHeaderField: "Authorization")

        let (_, response) = try await WebDAVMediaSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.invalidResponse
        }
        if http.statusCode == 401, !retriedAuth,
           let fresh = CredentialStore().load(account: credentials.email),
           fresh.region == credentials.region {
            try await verifyAccess(path: path, credentials: fresh, retriedAuth: true)
            return
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw WebDAVError.httpStatus(http.statusCode)
        }
    }

    private func list(
        path: String,
        credentials: WebDAVCredentials,
        retriedAuth: Bool
    ) async throws -> [WebDAVItem] {
        let listingURL = resolveURL(for: path)
        var request = URLRequest(url: listingURL)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.authorizationHeaderValue, forHTTPHeaderField: "Authorization")

        let (data, response) = try await WebDAVMediaSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.invalidResponse
        }
        if http.statusCode == 401, !retriedAuth,
           let fresh = CredentialStore().load(account: credentials.email),
           fresh.region == credentials.region {
            return try await list(path: path, credentials: fresh, retriedAuth: true)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw WebDAVError.httpStatus(http.statusCode)
        }

        let listingPath = WebDAVURLBuilder.directoryListingPath(path)
        let parsed = try WebDAVResponseParser.parse(data: data, baseHost: credentials.region.webDAVHost)
        return parsed.compactMap { item in
            let resolved = WebDAVURLBuilder.resolveHref(item.href, relativeTo: listingURL)
            if WebDAVURLBuilder.pathsEqual(resolved, listingPath) {
                return nil
            }
            let dirPath = item.isDirectory
                ? WebDAVURLBuilder.directoryListingPath(resolved)
                : resolved
            return WebDAVItem(
                href: dirPath,
                name: item.name,
                isDirectory: item.isDirectory,
                contentLength: item.contentLength
            )
        }
    }

    private func resolveURL(for path: String) -> URL {
        let normalized = WebDAVURLBuilder.directoryListingPath(path)
        if normalized == "/" {
            return credentials.region.baseURL
        }
        return WebDAVURLBuilder.fileURL(href: normalized, baseURL: credentials.region.baseURL)
    }
}

enum WebDAVError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid WebDAV response."
        case .httpStatus(let code): return WebDAVHTTPMessages.requestFailed(code)
        case .parseFailed: return "Could not parse WebDAV listing."
        }
    }
}
