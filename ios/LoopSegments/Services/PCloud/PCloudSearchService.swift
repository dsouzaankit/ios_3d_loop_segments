import Foundation

/// Search via pCloud REST when possible; fall back to WebDAV folder walk.
enum PCloudSearchService {
    struct Result {
        let items: [WebDAVItem]
        let usedWebDAVFallback: Bool
        let statusNote: String?
    }

    static func search(query: String, credentials: WebDAVCredentials) async throws -> Result {
        do {
            let items = try await PCloudAPIClient(credentials: credentials).search(query: query)
            if !items.isEmpty {
                return Result(items: items, usedWebDAVFallback: false, statusNote: nil)
            }
            let walked = try await WebDAVSearchClient.search(query: query, credentials: credentials)
            return Result(
                items: walked,
                usedWebDAVFallback: true,
                statusNote: walked.isEmpty
                    ? "pCloud web search returned nothing — folder walk also found no matches (check spelling or browse folders)."
                    : "pCloud web search returned nothing — used folder walk instead."
            )
        } catch let error as PCloudAPIError {
            guard shouldUseWebDAVFallback(error) else { throw error }
            let items = try await WebDAVSearchClient.search(query: query, credentials: credentials)
            return Result(
                items: items,
                usedWebDAVFallback: true,
                statusNote: items.isEmpty
                    ? "pCloud search login failed — folder walk found no matches. Sign out, confirm US/Europe, sign in again."
                    : "pCloud search API unavailable — used folder walk."
            )
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
