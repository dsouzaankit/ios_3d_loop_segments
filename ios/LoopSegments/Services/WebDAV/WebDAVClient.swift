import Foundation

final class WebDAVClient {
    private let credentials: WebDAVCredentials

    init(credentials: WebDAVCredentials) {
        self.credentials = credentials
    }

    func list(path: String, context: WebDAVHTTPContext = .generic) async throws -> [WebDAVItem] {
        try await list(path: path, credentials: credentials, retriedAuth: false, context: context)
    }

    /// Lightweight sign-in check (PROPFIND Depth 0 — no folder children listing).
    func verifyAccess(path: String = "/", maxAttempts: Int = 8, context: WebDAVHTTPContext = .generic) async throws {
        try await verifyAccess(
            path: path,
            credentials: credentials,
            retriedAuth: false,
            maxAttempts: maxAttempts,
            context: context
        )
    }

    private func verifyAccess(
        path: String,
        credentials: WebDAVCredentials,
        retriedAuth: Bool,
        maxAttempts: Int,
        context: WebDAVHTTPContext
    ) async throws {
        let listingURL = resolveURL(for: path)
        var request = URLRequest(url: listingURL)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
        applySignInTimeoutIfNeeded(&request, context: context)

        let profile = mediaProfile(for: context)
        let attempts = effectiveMaxAttempts(maxAttempts, context: context)
        let (_, response) = try await WebDAVMediaSession.data(
            for: request,
            maxAttempts: attempts,
            profile: profile
        )
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.invalidResponse
        }
        if http.statusCode == 401, !retriedAuth,
           let fresh = CredentialStore().load(account: credentials.email),
           fresh.region == credentials.region {
            try await verifyAccess(
                path: path,
                credentials: fresh,
                retriedAuth: true,
                maxAttempts: maxAttempts,
                context: context
            )
            return
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw WebDAVError.httpStatus(http.statusCode, context: context)
        }
    }

    private func list(
        path: String,
        credentials: WebDAVCredentials,
        retriedAuth: Bool,
        context: WebDAVHTTPContext
    ) async throws -> [WebDAVItem] {
        let listingURL = resolveURL(for: path)
        var request = URLRequest(url: listingURL)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
        applySignInTimeoutIfNeeded(&request, context: context)

        let profile = mediaProfile(for: context)
        let (data, response) = try await WebDAVMediaSession.data(for: request, profile: profile)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.invalidResponse
        }
        if http.statusCode == 401, !retriedAuth,
           let fresh = CredentialStore().load(account: credentials.email),
           fresh.region == credentials.region {
            return try await list(path: path, credentials: fresh, retriedAuth: true, context: context)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            if context == .signIn {
                SearchDebugLog.log("sign-in: HTTP \(http.statusCode) \(listingURL.absoluteString)")
            }
            throw WebDAVError.httpStatus(http.statusCode, context: context)
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

    private func mediaProfile(for context: WebDAVHTTPContext) -> WebDAVMediaSession.Profile {
        .export
    }

    private func effectiveMaxAttempts(_ maxAttempts: Int, context: WebDAVHTTPContext) -> Int {
        context == .signIn ? 1 : maxAttempts
    }

    /// URLRequest defaults to 60s even when the session is shorter — pin sign-in probes.
    private func applySignInTimeoutIfNeeded(_ request: inout URLRequest, context: WebDAVHTTPContext) {
        guard context == .signIn else { return }
        request.timeoutInterval = 12
    }
}

enum WebDAVError: LocalizedError {
    case invalidResponse
    case httpStatus(Int, context: WebDAVHTTPContext = .generic)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid WebDAV response."
        case .httpStatus(let code, let context): return WebDAVHTTPMessages.requestFailed(code, context: context)
        case .parseFailed: return "Could not parse WebDAV listing."
        }
    }
}
