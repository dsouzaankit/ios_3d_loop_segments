import Foundation

/// Search via pCloud REST when possible; fall back to WebDAV folder walk.
enum PCloudSearchService {
    struct Result {
        let items: [WebDAVItem]
        let usedWebDAVFallback: Bool
    }

    static func search(query: String, credentials: WebDAVCredentials) async throws -> Result {
        do {
            let items = try await PCloudAPIClient(credentials: credentials).search(query: query)
            return Result(items: items, usedWebDAVFallback: false)
        } catch let error as PCloudAPIError {
            guard shouldUseWebDAVFallback(error) else { throw error }
            let items = try await WebDAVSearchClient.search(query: query, credentials: credentials)
            return Result(items: items, usedWebDAVFallback: true)
        }
    }

    private static func shouldUseWebDAVFallback(_ error: PCloudAPIError) -> Bool {
        switch error {
        case .api(let code, _):
            return code == 1000 || code == 2000
        case .authenticationFailed:
            return true
        case .unexpectedResponse, .httpStatus:
            return false
        }
    }
}
