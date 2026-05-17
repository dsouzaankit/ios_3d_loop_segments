import Foundation

/// Parse pCloud REST metadata (search, listfolder, etc.) into WebDAV browse items.
enum PCloudMetadataParsing {
    static func extractEntries(from json: [String: Any]) -> [[String: Any]] {
        if let rows = json["items"] as? [[String: Any]], !rows.isEmpty {
            return rows
        }
        if let anyItems = json["items"] as? [Any] {
            let rows = anyItems.compactMap { $0 as? [String: Any] }
            if !rows.isEmpty { return rows }
        }
        if let rows = json["matches"] as? [[String: Any]], !rows.isEmpty {
            return rows
        }
        if let metadata = json["metadata"] as? [[String: Any]], !metadata.isEmpty {
            return metadata
        }
        if let metadata = json["metadata"] as? [String: Any] {
            if let contents = metadata["contents"] as? [[String: Any]], !contents.isEmpty {
                return contents
            }
            if metadata["name"] != nil {
                return [metadata]
            }
        }
        return []
    }

    static func webDAVItem(from metadata: [String: Any]) -> WebDAVItem? {
        guard let name = metadata["name"] as? String, !name.isEmpty else { return nil }
        let isFolder = boolField(metadata["isfolder"])
        guard let path = browsePath(from: metadata, name: name, isFolder: isFolder) else { return nil }

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

    static func isBrowsableVideo(name: String, metadata: [String: Any], isFolder: Bool) -> Bool {
        if isFolder { return true }
        if WebDAVItem.videoExtensions.contains((name as NSString).pathExtension.lowercased()) {
            return true
        }
        if intField(metadata["category"]) == 2 { return true }
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

    private static func normalizeAPIPath(_ path: String) -> String {
        let trimmed = path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !trimmed.isEmpty else { return "" }
        return WebDAVURLBuilder.canonicalBrowsePath(trimmed)
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
        default: return nil
        }
    }
}
