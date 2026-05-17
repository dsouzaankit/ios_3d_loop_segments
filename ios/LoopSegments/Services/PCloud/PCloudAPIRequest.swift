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
            components.queryItems = parameters
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }

    static func resultCode(_ json: [String: Any]) -> Int {
        if let code = json["result"] as? Int { return code }
        if let code = json["result"] as? NSNumber { return code.intValue }
        return -1
    }

    static func errorMessage(_ json: [String: Any]) -> String? {
        json["error"] as? String
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
