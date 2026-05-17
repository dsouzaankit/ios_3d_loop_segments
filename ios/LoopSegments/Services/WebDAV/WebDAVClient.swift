import Foundation

final class WebDAVClient {
    private let credentials: WebDAVCredentials
    private let session: URLSession

    init(credentials: WebDAVCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    func list(path: String) async throws -> [WebDAVItem] {
        let url = resolveURL(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.authorizationHeaderValue, forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw WebDAVError.httpStatus(http.statusCode)
        }

        return try WebDAVResponseParser.parse(data: data, baseHost: credentials.region.webDAVHost)
    }

    private func resolveURL(for path: String) -> URL {
        var normalized = path
        if !normalized.hasPrefix("/") { normalized = "/" + normalized }
        if normalized == "/" {
            return credentials.region.baseURL
        }
        let trimmed = String(normalized.dropFirst())
        return credentials.region.baseURL.appendingPathComponent(trimmed)
    }
}

enum WebDAVError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid WebDAV response."
        case .httpStatus(let code): return "WebDAV request failed (HTTP \(code))."
        case .parseFailed: return "Could not parse WebDAV listing."
        }
    }
}
