import Foundation

/// Resolves remote MP4 size when WebDAV HEAD disagrees with folder search metadata.
enum WebDAVContentLength {
    /// Prefer catalog size when HEAD is clearly too small (common on pCloud WebDAV for multi‑GB files).
    static func resolve(
        headBytes: Int64?,
        catalogBytes: Int64?,
        log: ((String) -> Void)? = nil
    ) -> Int64 {
        let head = headBytes ?? 0
        let catalog = catalogBytes ?? 0
        guard catalog > 0 else { return head }
        guard head > 0 else {
            log?("File size from search: \(formatBytes(catalog))")
            return catalog
        }
        if head < catalog * 9 / 10 {
            log?(
                "HEAD reported \(formatBytes(head)) but search metadata says \(formatBytes(catalog)) — using search size for download"
            )
            return catalog
        }
        if catalog < head * 9 / 10 {
            return head
        }
        return max(head, catalog)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", Double(bytes) / 1_073_741_824.0)
        }
        if bytes >= 1024 * 1024 {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
        }
        return "\(bytes) B"
    }
}
