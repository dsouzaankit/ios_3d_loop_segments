import Foundation

enum LANHTTPExportAPI {
    static func pcloudListPayload(folderPath: String) async -> [String: Any] {
        let normalized = WebDAVURLBuilder.directoryListingPath(folderPath)
        guard let credentials = CredentialStore().load() else {
            return [
                "path": normalized,
                "signedIn": false,
                "error": "Not signed in to pCloud on the phone.",
                "entries": [[String: Any]](),
            ]
        }
        do {
            let client = WebDAVClient(credentials: credentials)
            let items = try await client.list(path: normalized)
            let entries: [[String: Any]] = items.map { item in
                let listingPath = item.isDirectory
                    ? WebDAVURLBuilder.directoryListingPath(item.href)
                    : item.href
                var dict: [String: Any] = [
                    "href": item.href,
                    "path": listingPath,
                    "name": item.name,
                    "isDirectory": item.isDirectory,
                    "isVideo": item.isVideo,
                ]
                if let length = item.contentLength {
                    dict["bytes"] = length
                }
                return dict
            }
            return [
                "path": normalized,
                "signedIn": true,
                "entries": entries,
            ]
        } catch {
            return [
                "path": normalized,
                "signedIn": true,
                "error": error.localizedDescription,
                "entries": [[String: Any]](),
            ]
        }
    }

    static func localTreePayload(relativeDir: String) -> [String: Any] {
        let lines = LANMediaTree.listBrowseEntries(relativeDir: relativeDir)
        let entries: [[String: Any]] = lines.map { line in
            var dict: [String: Any] = [
                "path": line.relativePath,
                "name": line.displayName,
                "isDirectory": line.isDirectory,
            ]
            if let bytes = line.byteCount, bytes > 0 {
                dict["bytes"] = bytes
            }
            return dict
        }
        return [
            "dir": relativeDir.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            "entries": entries,
        ]
    }
}
