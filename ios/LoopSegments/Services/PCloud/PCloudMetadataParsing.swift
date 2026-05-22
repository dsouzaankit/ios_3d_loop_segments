import Foundation

/// Parse pCloud REST metadata (search, listfolder, etc.) into WebDAV browse items.
enum PCloudMetadataParsing {
    static func extractEntries(from json: [String: Any]) -> [[String: Any]] {
        for key in ["items", "matches", "results", "entries", "files", "file"] {
            if let rows = json[key] as? [[String: Any]], !rows.isEmpty {
                return flattenMetadataRows(rows)
            }
            if let anyItems = json[key] as? [Any], !anyItems.isEmpty {
                let rows = parseSearchItemList(anyItems)
                if !rows.isEmpty { return rows }
            }
            if let single = json[key] as? [String: Any], metadataDictionary(single) != nil {
                return [single]
            }
        }
        if let metadata = json["metadata"] as? [[String: Any]], !metadata.isEmpty {
            return flattenMetadataRows(metadata)
        }
        if let metadata = json["metadata"] as? [String: Any] {
            if let contents = metadata["contents"] as? [[String: Any]], !contents.isEmpty {
                return flattenMetadataRows(contents)
            }
            if metadata["name"] != nil || metadata["fileid"] != nil || metadata["folderid"] != nil {
                return [metadata]
            }
        }
        if let rows = collectMetadataArrays(in: json), !rows.isEmpty {
            return flattenMetadataRows(rows)
        }
        return []
    }

    /// Flatten nested `contents` from `listfolder` (recursive or shallow).
    static func flattenFolderContents(_ rows: [[String: Any]]) -> [[String: Any]] {
        var flat: [[String: Any]] = []
        flat.reserveCapacity(rows.count * 4)
        for row in rows {
            guard let item = metadataDictionary(row) else { continue }
            flat.append(item)
            if let nested = item["contents"] as? [[String: Any]], !nested.isEmpty {
                flat.append(contentsOf: flattenFolderContents(nested))
            } else if let nestedAny = item["contents"] as? [Any] {
                let nestedRows = nestedAny.compactMap { metadataDictionary($0) }
                if !nestedRows.isEmpty {
                    flat.append(contentsOf: flattenFolderContents(nestedRows))
                }
            }
        }
        return flat
    }

    static func matchesSearchNeedle(_ needle: String, metadata: [String: Any], name: String) -> Bool {
        guard !needle.isEmpty else { return false }
        let path = metadata["path"] as? String ?? ""
        if name.localizedCaseInsensitiveContains(needle) { return true }
        if path.localizedCaseInsensitiveContains(needle) { return true }
        let tokens = needle.split { $0.isWhitespace }.map(String.init).filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return false }
        let nameLower = name.lowercased()
        let pathLower = path.lowercased()
        return tokens.contains { token in
            let t = token.lowercased()
            return nameLower.contains(t) || pathLower.contains(t)
        }
    }

    private static func collectMetadataArrays(in json: [String: Any]) -> [[String: Any]]? {
        var best: [[String: Any]] = []
        for value in json.values {
            if let rows = value as? [[String: Any]] {
                let parsed = rows.compactMap { metadataDictionary($0) }
                if parsed.count > best.count { best = parsed }
            } else if let dict = value as? [String: Any] {
                if let nested = collectMetadataArrays(in: dict), nested.count > best.count {
                    best = nested
                }
            }
        }
        return best.isEmpty ? nil : best
    }

    static func webDAVItem(from metadata: [String: Any], webDAVFilesRoot: String? = nil) -> WebDAVItem? {
        guard let name = metadata["name"] as? String, !name.isEmpty else { return nil }
        let isFolder = boolField(metadata["isfolder"])
        guard let apiPath = browsePath(from: metadata, name: name, isFolder: isFolder) else { return nil }
        let path = webDAVHref(apiPath: apiPath, webDAVFilesRoot: webDAVFilesRoot)

        let href = isFolder
            ? WebDAVURLBuilder.directoryListingPath(path)
            : WebDAVURLBuilder.canonicalBrowsePath(path)
        return WebDAVItem(
            href: href,
            name: name,
            isDirectory: isFolder,
            contentLength: int64Field(metadata["size"])
        )
    }

    private static func flattenMetadataRows(_ rows: [[String: Any]]) -> [[String: Any]] {
        rows.compactMap { metadataDictionary($0) }
    }

    private static func parseSearchItemList(_ items: [Any]) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        rows.reserveCapacity(items.count)
        for item in items {
            if let row = metadataDictionary(item) {
                rows.append(Self.normalizeSearchMetadata(row))
                continue
            }
            if let fileId = int64Field(item) {
                rows.append(["fileid": fileId])
            }
        }
        return rows
    }

    /// Normalize web search rows (`id` is often `d` + folderid or `f` + fileid, not a bare integer).
    static func normalizeSearchMetadata(_ row: [String: Any]) -> [String: Any] {
        var copy = row
        let ids = resolvedIds(from: copy)
        if let folderId = ids.folderId {
            copy["folderid"] = folderId
        }
        if let fileId = ids.fileId {
            copy["fileid"] = fileId
        }
        return copy
    }

    static func resolvedIds(from metadata: [String: Any]) -> (fileId: Int64?, folderId: Int64?) {
        var fileId = int64Field(metadata["fileid"])
        var folderId = int64Field(metadata["folderid"])
        if let prefixed = prefixedItemId(metadata["id"]) {
            if prefixed.isFolder {
                folderId = folderId ?? prefixed.id
            } else {
                fileId = fileId ?? prefixed.id
            }
        }
        if fileId == nil, folderId == nil, boolField(metadata["isfolder"]) {
            folderId = int64Field(metadata["id"])
        } else if fileId == nil, folderId == nil {
            fileId = int64Field(metadata["id"])
        }
        return (fileId, folderId)
    }

    private static func prefixedItemId(_ value: Any?) -> (id: Int64, isFolder: Bool)? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let first = trimmed.first, trimmed.count > 1 else { return nil }
        let digits = trimmed.dropFirst()
        guard let id = Int64(digits) else { return nil }
        switch first {
        case "d": return (id, true)
        case "f": return (id, false)
        default: return nil
        }
    }

    private static func metadataDictionary(_ value: Any) -> [String: Any]? {
        if let row = value as? [String: Any] {
            if let nested = row["metadata"] as? [String: Any] { return nested }
            if row["name"] != nil || row["fileid"] != nil || row["folderid"] != nil || row["id"] != nil {
                return row
            }
        }
        return nil
    }

    /// Map pCloud API `/folder/file` to WebDAV `/remote.php/dav/files/user/folder/file`.
    private static func webDAVHref(apiPath: String, webDAVFilesRoot: String?) -> String {
        let normalized = normalizeAPIPath(apiPath)
        if normalized.lowercased().contains("remote.php") {
            return normalized
        }
        guard let root = webDAVFilesRoot, !root.isEmpty else { return normalized }
        let rootPath = WebDAVURLBuilder.directoryListingPath(root)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let apiTrimmed = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let combined = "/\(rootPath)/\(apiTrimmed)"
        return WebDAVURLBuilder.canonicalBrowsePath(combined)
    }

    static func isBrowsableVideo(name: String, metadata: [String: Any], isFolder: Bool) -> Bool {
        if isFolder { return true }
        if WebDAVItem.videoExtensions.contains((name as NSString).pathExtension.lowercased()) {
            return true
        }
        if intField(metadata["category"]) == 2 { return true }
        if let contentType = metadata["contenttype"] as? String,
           contentType.lowercased().contains("video") {
            return true
        }
        return false
    }

    private static func browsePath(from metadata: [String: Any], name: String, isFolder: Bool) -> String? {
        if let raw = metadata["path"] as? String {
            let normalized = normalizeAPIPath(raw)
            if !normalized.isEmpty { return normalized }
        }
        // Search hits sometimes omit path; keep a root-level href so the user still sees a name.
        return WebDAVURLBuilder.canonicalBrowsePath("/\(name)")
    }

    static func normalizeAPIPathForREST(_ path: String) -> String {
        let trimmed = path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !trimmed.isEmpty else { return "" }
        return WebDAVURLBuilder.canonicalBrowsePath(trimmed)
    }

    private static func normalizeAPIPath(_ path: String) -> String {
        normalizeAPIPathForREST(path)
    }

    static func boolField(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: return flag
        case let n as Int: return n != 0
        case let n as NSNumber: return n.intValue != 0
        default: return false
        }
    }

    static func intField(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let n as NSNumber: return n.intValue
        default: return nil
        }
    }

    static func int64Field(_ value: Any?) -> Int64? {
        switch value {
        case let n as Int64: return n
        case let n as Int: return Int64(n)
        case let n as NSNumber: return n.int64Value
        case let text as String:
            if let prefixed = prefixedItemId(text) { return prefixed.id }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let n = Int64(trimmed) else { return nil }
            return n
        default: return nil
        }
    }
}
