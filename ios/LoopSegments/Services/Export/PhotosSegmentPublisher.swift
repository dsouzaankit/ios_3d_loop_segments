import Foundation
import Photos

/// Publishes finished segment MP4s to the Photos library (Loop Segments album).
enum PhotosSegmentPublisher {
    static let albumTitle = "Loop Segments"
    private static let enabledKey = "publishSegmentsToPhotos"
    private static let assetIdsKey = "photos_segment_asset_local_ids"

    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Request read/write access (required to add and delete segment clips).
    @discardableResult
    static func ensureAccess(log: ((String) -> Void)? = nil) async -> Bool {
        let status = await requestAuthorizationIfNeeded()
        switch status {
        case .authorized, .limited:
            return true
        case .denied, .restricted:
            log?("Photos: access denied — open Settings → Loop Segments → Photos and allow access.")
            return false
        case .notDetermined:
            log?("Photos: permission not granted.")
            return false
        @unknown default:
            return false
        }
    }

    static func publish(segmentSlot: Int, videoURL: URL, log: @escaping (String) -> Void) async {
        guard isEnabled else { return }
        guard FileManager.default.fileExists(atPath: videoURL.path) else { return }
        guard await ensureAccess(log: log) else { return }

        do {
            try await deletePreviousAsset(slot: segmentSlot)
            let assetId = try await createVideoAsset(from: videoURL)
            try await addToAlbum(assetLocalIdentifier: assetId)
            storeAssetId(assetId, slot: segmentSlot)
            log("Photos: updated slot \(segmentSlot) (\(videoURL.lastPathComponent)) in album \(albumTitle)")
        } catch {
            log("Photos: \(error.localizedDescription)")
        }
    }

    static func removeAllPublished(log: ((String) -> Void)? = nil) async {
        let ids = loadAssetIds()
        guard !ids.isEmpty else { return }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            clearStoredAssetIds()
            log?("Photos: skipped delete (no library access)")
            return
        }

        let nonEmpty = ids.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else {
            clearStoredAssetIds()
            return
        }

        do {
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: nonEmpty, options: nil)
            if fetch.count > 0 {
                try await performChanges {
                    PHAssetChangeRequest.deleteAssets(fetch)
                }
                log?("Photos: removed \(fetch.count) segment clip(s) from library")
            }
            clearStoredAssetIds()
        } catch {
            log?("Photos: could not remove clips — \(error.localizedDescription)")
            clearStoredAssetIds()
        }
    }

    private static func requestAuthorizationIfNeeded() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current != .notDetermined {
            return current
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: status)
                }
            }
        }
    }

    private static func deletePreviousAsset(slot: Int) async throws {
        let ids = loadAssetIds()
        guard slot < ids.count else { return }
        let oldId = ids[slot]
        guard !oldId.isEmpty else { return }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [oldId], options: nil)
        guard fetch.count > 0 else { return }
        try await performChanges {
            PHAssetChangeRequest.deleteAssets(fetch)
        }
    }

    private static func createVideoAsset(from url: URL) async throws -> String {
        var createdId: String?
        try await performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
            createdId = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let createdId else {
            throw PhotosPublishError.noAssetCreated
        }
        return createdId
    }

    private static func addToAlbum(assetLocalIdentifier: String) async throws {
        let album = try await fetchOrCreateAlbum()
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetLocalIdentifier], options: nil)
        guard asset.count > 0 else { return }
        try await performChanges {
            let change = PHAssetCollectionChangeRequest(for: album)
            change?.addAssets(asset as NSFastEnumeration)
        }
    }

    private static func fetchOrCreateAlbum() async throws -> PHAssetCollection {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", albumTitle)
        let existing = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: options
        )
        if let album = existing.firstObject {
            return album
        }

        var albumId: String?
        try await performChanges {
            albumId = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                withTitle: albumTitle
            ).placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let albumId else { throw PhotosPublishError.noAlbumCreated }
        let created = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumId],
            options: nil
        )
        guard let album = created.firstObject else {
            throw PhotosPublishError.noAlbumCreated
        }
        return album
    }

    private static func performChanges(_ block: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                block()
            }, completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotosPublishError.changeFailed)
                }
            })
        }
    }

    private static func loadAssetIds() -> [String] {
        UserDefaults.standard.stringArray(forKey: assetIdsKey) ?? []
    }

    private static func storeAssetId(_ id: String, slot: Int) {
        var ids = loadAssetIds()
        while ids.count <= slot {
            ids.append("")
        }
        ids[slot] = id
        UserDefaults.standard.set(ids, forKey: assetIdsKey)
    }

    private static func clearStoredAssetIds() {
        UserDefaults.standard.removeObject(forKey: assetIdsKey)
    }
}

enum PhotosPublishError: LocalizedError {
    case noAssetCreated
    case noAlbumCreated
    case changeFailed

    var errorDescription: String? {
        switch self {
        case .noAssetCreated: return "Could not add video to Photos."
        case .noAlbumCreated: return "Could not create Photos album."
        case .changeFailed: return "Photos library update failed."
        }
    }
}
