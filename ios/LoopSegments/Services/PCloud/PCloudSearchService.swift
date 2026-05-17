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
        var diagnostics = PCloudAPIClient.SearchDiagnostics(rawEntryCount: 0, resolvedCount: 0)

        if let apiResult = try? await api.search(query: query) {
            diagnostics = apiResult.1
            if !apiResult.0.isEmpty {
                return Result(items: apiResult.0, usedWebDAVFallback: false, statusNote: nil)
            }
        }

        if let catalog = try? await PCloudAPIFolderSearch.search(
            query: query,
            credentials: credentials,
            apiClient: api
        ), !catalog.isEmpty {
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
                : noteForWebDAVFallback(apiDiagnostics: diagnostics)
        )
    }

    private static func noteForWebDAVFallback(apiDiagnostics: PCloudAPIClient.SearchDiagnostics) -> String {
        if apiDiagnostics.rawEntryCount > 0 {
            return "pCloud web search had \(apiDiagnostics.rawEntryCount) hit(s) but none were usable — used WebDAV folder walk."
        }
        return "pCloud API found nothing — used WebDAV folder walk instead."
    }

    private static func emptySearchNote(apiRawCount: Int, apiResolved: Int) -> String {
        if apiRawCount > 0, apiResolved == 0 {
            return "pCloud returned \(apiRawCount) hit(s) but paths could not be mapped — try browsing folders, or sign out and sign in again."
        }
        return "No matches in pCloud web search, folder catalog, or WebDAV walk (check spelling or browse folders)."
    }
}
