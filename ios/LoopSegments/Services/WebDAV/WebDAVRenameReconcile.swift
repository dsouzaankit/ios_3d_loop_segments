import Foundation

/// Match pCloud WebDAV items after rename/move (`fileKey` is href-derived and changes when `href` changes).
enum WebDAVRenameReconcile {
    static func namesEqual(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    static func parentListingPath(for href: String) -> String {
        WebDAVURLBuilder.directoryListingPath(href)
    }

    /// Folder path for PROPFIND when a file `href` returns 404 (parent of the file).
    static func parentBrowsePath(forFileHref href: String) -> String? {
        let path = WebDAVURLBuilder.normalizedHrefPath(href)
        let withoutQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        guard withoutQuery != "/", !withoutQuery.isEmpty else { return nil }
        let parent = (withoutQuery as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return "/" }
        return WebDAVURLBuilder.directoryListingPath(parent)
    }

    static func matchResumeEntry(_ entry: ResumeEntry, in videos: [WebDAVItem]) -> WebDAVItem? {
        if let exact = videos.first(where: { $0.fileKey == entry.fileKey }) {
            return exact
        }

        if let byName = uniqueNameMatch(entry.displayName, in: videos) {
            return byName
        }

        if let expectedLength = expectedContentLength(for: entry) {
            let bySize = videos.filter { $0.contentLength == expectedLength }
            if bySize.count == 1 {
                return bySize[0]
            }
            if let oldHref = entry.href, !oldHref.isEmpty {
                let parent = parentListingPath(for: oldHref)
                let inFolder = bySize.filter { parentListingPath(for: $0.href) == parent }
                if inFolder.count == 1 {
                    return inFolder[0]
                }
            }
        }

        if let oldHref = entry.href, !oldHref.isEmpty {
            let parent = parentListingPath(for: oldHref)
            let inFolder = videos.filter { parentListingPath(for: $0.href) == parent }
            if inFolder.count == 1 {
                return inFolder[0]
            }
        }

        return nil
    }

    static func matchManifest(
        fileKey: String,
        totalLength: Int64,
        href: String?,
        in videos: [WebDAVItem]
    ) -> WebDAVItem? {
        if videos.contains(where: { $0.fileKey == fileKey }) {
            return videos.first { $0.fileKey == fileKey }
        }

        let bySize = videos.filter { $0.contentLength == totalLength }
        if bySize.count == 1 {
            return bySize[0]
        }

        if let href, !href.isEmpty {
            let parent = parentListingPath(for: href)
            let inFolder = bySize.filter { parentListingPath(for: $0.href) == parent }
            if inFolder.count == 1 {
                return inFolder[0]
            }
            let leaf = WebDAVURLBuilder.displayName(fromHref: href)
            if let byLeaf = uniqueNameMatch(leaf, in: bySize) {
                return byLeaf
            }
        }

        return nil
    }

    private static func uniqueNameMatch(_ name: String, in videos: [WebDAVItem]) -> WebDAVItem? {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let matches = videos.filter { namesEqual($0.name, target) }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private static func expectedContentLength(for entry: ResumeEntry) -> Int64? {
        if let manifest = VanillaDownloadResumeCatalog.readManifest() {
            if manifest.fileKey == entry.fileKey {
                return manifest.totalLength
            }
            if let entryHref = entry.href,
               let manifestHref = manifest.href,
               parentListingPath(for: entryHref) == parentListingPath(for: manifestHref),
               manifest.totalLength > 0 {
                return manifest.totalLength
            }
        }
        if let manifest = WorkingSourceSparseCatalog.readManifest() {
            if manifest.fileKey == entry.fileKey {
                return manifest.totalLength
            }
            if let entryHref = entry.href,
               let manifestHref = manifest.href,
               !manifestHref.isEmpty,
               parentListingPath(for: entryHref) == parentListingPath(for: manifestHref),
               manifest.totalLength > 0 {
                return manifest.totalLength
            }
        }
        return nil
    }
}
