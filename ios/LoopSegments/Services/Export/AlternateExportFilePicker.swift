import Foundation

/// Pick another pCloud video for export from the LAN / Export screen (same folder or bookmarks).
enum AlternateExportFileSource: String, CaseIterable, Identifiable {
    case sameFolder
    case bookmarks

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sameFolder: return "This folder"
        case .bookmarks: return "Bookmarks"
        }
    }

    private static let storageKey = "alternate_export_file_source"

    static var stored: AlternateExportFileSource {
        get {
            guard let raw = UserDefaults.standard.string(forKey: storageKey),
                  let value = AlternateExportFileSource(rawValue: raw) else {
                return .sameFolder
            }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }
}

enum AlternateExportFilePicker {
    enum PickerError: LocalizedError {
        case notSignedIn
        case noParentFolder
        case noVideos
        case noOtherVideos
        case noBookmarks
        case fileNotFound(displayName: String, folderPath: String)
        case ambiguousName(displayName: String, count: Int)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Sign in to pCloud first."
            case .noParentFolder:
                return "Could not resolve the folder for this file."
            case .noVideos:
                return "No videos found in the chosen source."
            case .noOtherVideos:
                return "No other videos in the chosen source (only this file)."
            case .noBookmarks:
                return "No folder bookmarks — bookmark folders in Browse, or use “This folder”."
            case .fileNotFound(let displayName, let folderPath):
                return "No video named “\(displayName)” in \(folderPath) (one-level list only)."
            case .ambiguousName(let displayName, let count):
                return "\(count) videos named “\(displayName)” in that folder — use a unique name."
            }
        }
    }

    static func parentFolderPath(for item: WebDAVItem) -> String? {
        WebDAVRenameReconcile.parentBrowsePath(forFileHref: item.href)
    }

    static func listVideos(in path: String, credentials: WebDAVCredentials) async throws -> [WebDAVItem] {
        let client = WebDAVClient(credentials: credentials)
        let listed = try await client.list(path: path)
        return listed
            .filter(\.isVideo)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func randomVideo(excluding fileKey: String?, from candidates: [WebDAVItem]) -> WebDAVItem? {
        let others = candidates.filter { $0.fileKey != fileKey }
        if let pick = others.randomElement() { return pick }
        return candidates.randomElement()
    }

    static func collectCandidates(
        source: AlternateExportFileSource,
        currentItem: WebDAVItem,
        credentials: WebDAVCredentials
    ) async throws -> [WebDAVItem] {
        switch source {
        case .sameFolder:
            guard let parent = parentFolderPath(for: currentItem) else {
                throw PickerError.noParentFolder
            }
            return try await listVideos(in: parent, credentials: credentials)
        case .bookmarks:
            let bookmarks = await MainActor.run { FolderBookmarkStore.shared.bookmarks() }
            guard !bookmarks.isEmpty else { throw PickerError.noBookmarks }
            var merged: [WebDAVItem] = []
            var seen = Set<String>()
            for bookmark in bookmarks {
                let videos = try await listVideos(in: bookmark.listingPath, credentials: credentials)
                for video in videos where seen.insert(video.fileKey).inserted {
                    merged.append(video)
                }
            }
            return merged.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    static func pickRandom(
        excluding fileKey: String?,
        source: AlternateExportFileSource,
        currentItem: WebDAVItem,
        credentials: WebDAVCredentials
    ) async throws -> WebDAVItem {
        let candidates = try await collectCandidates(
            source: source,
            currentItem: currentItem,
            credentials: credentials
        )
        return try pickRandom(excluding: fileKey, from: candidates)
    }

    static func pickRandom(
        excluding fileKey: String?,
        folderPath: String,
        credentials: WebDAVCredentials
    ) async throws -> WebDAVItem {
        let candidates = try await listVideos(in: folderPath, credentials: credentials)
        return try pickRandom(excluding: fileKey, from: candidates)
    }

    /// One-level PROPFIND in `folderPath` — match `displayName` (case/diacritic-insensitive). No recursive walk.
    static func findVideo(
        named displayName: String,
        in folderPath: String,
        credentials: WebDAVCredentials
    ) async throws -> WebDAVItem {
        let target = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw PickerError.noVideos }
        let folder = WebDAVURLBuilder.directoryListingPath(folderPath)
        let candidates = try await listVideos(in: folder, credentials: credentials)
        let matches = candidates.filter { WebDAVRenameReconcile.namesEqual($0.name, target) }
        if matches.count == 1 { return matches[0] }
        if matches.isEmpty {
            throw PickerError.fileNotFound(displayName: target, folderPath: folder)
        }
        throw PickerError.ambiguousName(displayName: target, count: matches.count)
    }

    private static func pickRandom(excluding fileKey: String?, from candidates: [WebDAVItem]) throws -> WebDAVItem {
        guard !candidates.isEmpty else { throw PickerError.noVideos }
        guard let picked = randomVideo(excluding: fileKey, from: candidates) else {
            throw PickerError.noOtherVideos
        }
        return picked
    }
}
