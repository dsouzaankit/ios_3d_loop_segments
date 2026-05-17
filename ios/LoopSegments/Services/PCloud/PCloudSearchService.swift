import Foundation

/// Search via pCloud REST when possible; fall back to API folder walk, then WebDAV.
enum PCloudSearchService {
    struct Result {
        let items: [WebDAVItem]
        let usedWebDAVFallback: Bool
        let statusNote: String?
    }

    static func search(query: String, credentials: WebDAVCredentials) async throws -> Result {
        let api = PCloudAPIClient(credentials: credentials)
        do {
            let (apiItems, diagnostics) = try await api.search(query: query)
            if !apiItems.isEmpty {
                return Result(items: apiItems, usedWebDAVFallback: false, statusNote: nil)
            }

            let catalog = try await PCloudAPIFolderSearch.search(
                query: query,
                credentials: credentials,
                apiClient: api
            )
            if !catalog.isEmpty {
                return Result(
                    items: catalog,
                    usedWebDAVFallback: false,
                    statusNote: diagnostics.rawEntryCount > 0
                        ? "pCloud web search had \(diagnostics.rawEntryCount) hit(s) but none were usable — used folder catalog instead."
                        : "pCloud web search returned nothing — used folder catalog instead."
                )
            }

            let walked = try await WebDAVSearchClient.search(query: query, credentials: credentials)
            return Result(
                items: walked,
                usedWebDAVFallback: true,
                statusNote: walked.isEmpty
                    ? emptySearchNote(apiRawCount: diagnostics.rawEntryCount, apiResolved: diagnostics.resolvedCount)
                    : "pCloud API found nothing — used WebDAV folder walk instead."
            )
        } catch let error as PCloudAPIError {
            guard shouldUseWebDAVFallback(error) else { throw error }

            if let catalog = try? await PCloudAPIFolderSearch.search(
                query: query,
                credentials: credentials,
                apiClient: api
            ), !catalog.isEmpty {
                return Result(
                    items: catalog,
                    usedWebDAVFallback: false,
                    statusNote: "pCloud web search unavailable — used folder catalog instead."
                )
            }

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

    private static func emptySearchNote(apiRawCount: Int, apiResolved: Int) -> String {
        if apiRawCount > 0, apiResolved == 0 {
            return "pCloud returned \(apiRawCount) hit(s) but paths could not be mapped — try browsing folders, or sign out and sign in again."
        }
        return "No matches in pCloud web search, folder catalog, or WebDAV walk (check spelling or browse folders)."
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
