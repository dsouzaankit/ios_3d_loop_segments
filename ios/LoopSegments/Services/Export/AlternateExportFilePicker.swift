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
        guard !candidates.isEmpty else {
            if source == .bookmarks {
                throw PickerError.noVideos
            }
            throw PickerError.noVideos
        }
        guard let picked = randomVideo(excluding: fileKey, from: candidates) else {
            throw PickerError.noOtherVideos
        }
        return picked
    }
}
