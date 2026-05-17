import Foundation

/// Search: WebDAV folder walk first (same creds as browse), then pCloud API catalog / web search.
enum PCloudSearchService {
    struct Result {
        let items: [WebDAVItem]
        let statusNote: String
    }

    static func search(
        query: String,
        credentials: WebDAVCredentials,
        browsePaths: [String] = []
    ) async throws -> Result {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Result(items: [], statusNote: "Enter a file or folder name to search.")
        }

        var tried: [String] = []
        var apiRawCount = 0

        tried.append("folders (WebDAV)")
        let webDAV = try await WebDAVSearchClient.search(
            query: trimmed,
            credentials: credentials,
            extraRoots: browsePaths
        )
        if !webDAV.isEmpty {
            return Result(
                items: webDAV,
                statusNote: "Found \(webDAV.count) match(es) via folder search."
            )
        }

        let api = PCloudAPIClient(credentials: credentials)
        tried.append("pCloud folder index")
        if let catalog = try? await PCloudAPIFolderSearch.search(
            query: trimmed,
            credentials: credentials,
            apiClient: api
        ), !catalog.isEmpty {
            return Result(
                items: catalog,
                statusNote: "Found \(catalog.count) match(es) via pCloud folder index."
            )
        }

        tried.append("pCloud web search")
        if let apiResult = try? await api.search(query: trimmed) {
            apiRawCount = apiResult.1.rawEntryCount
            if !apiResult.0.isEmpty {
                return Result(
                    items: apiResult.0,
                    statusNote: "Found \(apiResult.0.count) match(es) via pCloud web search."
                )
            }
        }

        return Result(
            items: [],
            statusNote: emptyMessage(
                query: trimmed,
                tried: tried,
                apiRawCount: apiRawCount,
                browsePaths: browsePaths
            )
        )
    }

    private static func emptyMessage(
        query: String,
        tried: [String],
        apiRawCount: Int,
        browsePaths: [String]
    ) -> String {
        if apiRawCount > 0 {
            return """
            pCloud web search returned \(apiRawCount) hit(s) but paths could not be mapped to WebDAV. \
            Open the folder in Browse first, then search again — or sign out and sign in to refresh search login.
            """
        }
        let methods = tried.joined(separator: " → ")
        if let path = browsePaths.last, path != "/" {
            let folder = (path as NSString).lastPathComponent
            return "No matches for “\(query)” (\(methods)). Try a shorter name, open “\(folder)” in Browse, or search from the folder that contains your videos."
        }
        return "No matches for “\(query)” (\(methods)). Try a shorter fragment of the filename, confirm US/Europe region, or browse folders manually."
    }
}
