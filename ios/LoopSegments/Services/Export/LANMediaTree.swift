import Foundation

struct LANMediaTreeLine: Identifiable, Hashable {
    let relativePath: String
    let depth: Int
    let isDirectory: Bool
    let byteCount: Int64?

    var id: String { relativePath }

    var displayName: String {
        (relativePath as NSString).lastPathComponent
    }

    var indentLabel: String {
        let prefix = String(repeating: "  ", count: depth)
        if isDirectory {
            return "\(prefix)\(displayName)/"
        }
        let sizeNote: String
        if let byteCount, byteCount > 0 {
            sizeNote = " (\(Self.formatBytes(byteCount)))"
        } else {
            sizeNote = ""
        }
        return "\(prefix)\(displayName)\(sizeNote)"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
        if bytes >= 1024 {
            return String(format: "%.0f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }
}

enum LANMediaTree {
    static func snapshotLines(maxDepth: Int = 5) -> [LANMediaTreeLine] {
        var lines: [LANMediaTreeLine] = []
        appendLines(relativeDir: ExportPaths.mediaExportFolderName, depth: 0, maxDepth: maxDepth, into: &lines)
        for rel in ExportPaths.rootLogRelativePathsForLAN().sorted() {
            let url = ExportPaths.urlUnderExports(relativePath: rel)
            let bytes = fileSize(at: url)
            lines.append(
                LANMediaTreeLine(relativePath: rel, depth: 0, isDirectory: false, byteCount: bytes)
            )
        }
        return lines
    }

    static func listBrowseEntries(relativeDir: String) -> [LANMediaTreeLine] {
        let normalized = relativeDir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized.isEmpty {
            var lines: [LANMediaTreeLine] = []
            let media = ExportPaths.mediaExportFolderName
            let mediaURL = ExportPaths.urlUnderExports(relativePath: media)
            if FileManager.default.fileExists(atPath: mediaURL.path) {
                lines.append(
                    LANMediaTreeLine(relativePath: media, depth: 0, isDirectory: true, byteCount: nil)
                )
            }
            for rel in ExportPaths.rootLogRelativePathsForLAN().sorted() {
                let url = ExportPaths.urlUnderExports(relativePath: rel)
                lines.append(
                    LANMediaTreeLine(
                        relativePath: rel,
                        depth: 0,
                        isDirectory: false,
                        byteCount: fileSize(at: url)
                    )
                )
            }
            return lines
        }
        return ExportPaths.listLANMediaDirectory(relativeDir: normalized).map { entry in
            let url = ExportPaths.urlUnderExports(relativePath: entry.relativePath)
            let bytes = entry.isDirectory ? nil : fileSize(at: url)
            return LANMediaTreeLine(
                relativePath: entry.relativePath,
                depth: 0,
                isDirectory: entry.isDirectory,
                byteCount: bytes
            )
        }
    }

    private static func appendLines(
        relativeDir: String,
        depth: Int,
        maxDepth: Int,
        into lines: inout [LANMediaTreeLine]
    ) {
        if depth > maxDepth { return }
        let children = ExportPaths.listLANMediaDirectory(relativeDir: relativeDir)
        for entry in children {
            let url = ExportPaths.urlUnderExports(relativePath: entry.relativePath)
            let bytes = entry.isDirectory ? nil : fileSize(at: url)
            lines.append(
                LANMediaTreeLine(
                    relativePath: entry.relativePath,
                    depth: depth,
                    isDirectory: entry.isDirectory,
                    byteCount: bytes
                )
            )
            if entry.isDirectory, depth < maxDepth {
                appendLines(
                    relativeDir: entry.relativePath,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    into: &lines
                )
            }
        }
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let num = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return num.int64Value
    }
}

private extension ExportPaths {
    static func rootLogRelativePathsForLAN() -> [String] {
        [
            latestLogTextURL.lastPathComponent,
            latestLogURL.lastPathComponent,
            exportProgressURL.lastPathComponent,
        ].filter { FileManager.default.fileExists(atPath: urlUnderExports(relativePath: $0).path) }
    }
}
