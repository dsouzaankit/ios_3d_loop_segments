import Foundation

enum PCloudAPIRequest {
    static func get(
        host: String,
        method: String,
        parameters: [String: String] = [:],
        session: URLSession = .shared
    ) async throws -> [String: Any] {
        guard let url = url(host: host, method: method, parameters: parameters) else {
            throw PCloudAPIError.unexpectedResponse
        }
        let (data, response) = try await session.data(from: url)
        try validateHTTP(response)
        return try decodeJSONObject(data)
    }

    static func url(host: String, method: String, parameters: [String: String]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = "/\(method)"
        if !parameters.isEmpty {
            let query = parameters
                .sorted { $0.key < $1.key }
                .map { percentEncodedQueryPair(name: $0.key, value: $0.value) }
                .joined(separator: "&")
            components.percentEncodedQuery = query
        }
        return components.url
    }

    /// RFC 3986 query encoding (`+` stays `%2B`, not a space).
    private static func percentEncodedQueryPair(name: String, value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(encodedName)=\(encodedValue)"
    }

    static func resultCode(_ json: [String: Any]) -> Int {
        switch json["result"] {
        case let code as Int:
            return code
        case let code as NSNumber:
            return code.intValue
        case let code as String:
            return Int(code.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        default:
            return -1
        }
    }

    static func isSuccess(_ json: [String: Any]) -> Bool {
        resultCode(json) == 0
    }

    static func errorMessage(_ json: [String: Any]) -> String? {
        if let message = json["error"] as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func throwIfAPIError(_ json: [String: Any]) throws {
        let code = resultCode(json)
        guard code == 0 else {
            throw PCloudAPIError.api(code: code, message: errorMessage(json))
        }
    }

    private static func decodeJSONObject(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw PCloudAPIError.unexpectedResponse
        }
        return dict
    }

    private static func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PCloudAPIError.unexpectedResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw PCloudAPIError.httpStatus(http.statusCode)
        }
    }
}
