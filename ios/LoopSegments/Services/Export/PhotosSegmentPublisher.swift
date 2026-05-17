import Foundation
import Photos

/// Publishes finished segment MP4s to the Photos library (Loop Segments album).
enum PhotosSegmentPublisher {
    static let albumTitle = "Loop Segments"
    private static let enabledKey = "publishSegmentsToPhotos"
    private static let assetIdsKey = "photos_segment_asset_local_ids"
    private static let albumIdKey = "photos_loop_segments_album_local_id"

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
        case .authorized:
            return true
        case .limited:
            log?("Photos: Limited access — clips save to Recents; use Settings → Loop Segments → Photos → Full Access for the album.")
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
        guard await ensureAccess(log: log) else { return }

        let bytes = fileByteCount(videoURL)
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            log("Photos: skipped slot \(segmentSlot) — file missing at \(videoURL.lastPathComponent)")
            return
        }
        guard bytes > 8192 else {
            log("Photos: skipped \(videoURL.lastPathComponent) — file too small (\(bytes) B); wait for segment to finish writing")
            return
        }

        do {
            try await deletePreviousAsset(slot: segmentSlot)
            let assetId = try await importVideoIntoAlbum(url: videoURL)
            storeAssetId(assetId, slot: segmentSlot)
            log("Photos: saved \(videoURL.lastPathComponent) (\(bytes / 1024) KB) → Albums → \(albumTitle) and Recents")
        } catch {
            log("Photos: failed \(videoURL.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    /// Re-publish any segment files on disk (covers a failed per-slot publish).
    static func publishAllSegmentsFromExports(log: @escaping (String) -> Void) async {
        guard isEnabled else { return }
        guard await ensureAccess(log: log) else { return }
        for slot in 0 ..< ExportPaths.segmentFileCount {
            let url = ExportPaths.segmentURL(index: slot)
            guard fileByteCount(url) > 8192 else { continue }
            await publish(segmentSlot: slot, videoURL: url, log: log)
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

    // MARK: - Private

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

    private static func importVideoIntoAlbum(url: URL) async throws -> String {
        let album = try await ensureAlbumExists()

        var createdId: String?
        try await performChanges {
            let resourceOptions = PHAssetResourceCreationOptions()
            resourceOptions.shouldMoveFile = false
            resourceOptions.uniformTypeIdentifier = "public.mpeg-4"

            let create = PHAssetCreationRequest.forAsset()
            create.addResource(with: .video, fileURL: url, options: resourceOptions)
            guard let assetPlaceholder = create.placeholderForCreatedAsset else { return }
            createdId = assetPlaceholder.localIdentifier
            PHAssetCollectionChangeRequest(for: album)?.addAssets([assetPlaceholder] as NSArray)
        }

        guard let createdId else {
            throw PhotosPublishError.noAssetCreated
        }
        return createdId
    }

    private static func ensureAlbumExists() async throws -> PHAssetCollection {
        if let existing = resolveAlbumCollection() {
            return existing
        }

        var albumId: String?
        try await performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
            albumId = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let albumId else { throw PhotosPublishError.noAlbumCreated }
        rememberAlbum(localIdentifier: albumId)
        let fetch = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumId], options: nil)
        guard let album = fetch.firstObject else { throw PhotosPublishError.noAlbumCreated }
        return album
    }

    private static func resolveAlbumCollection() -> PHAssetCollection? {
        if let id = UserDefaults.standard.string(forKey: albumIdKey), !id.isEmpty {
            let byId = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil)
            if let album = byId.firstObject {
                return album
            }
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", albumTitle)
        let byTitle = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: options
        )
        if let album = byTitle.firstObject {
            rememberAlbum(album)
            return album
        }
        return nil
    }

    private static func rememberAlbum(_ collection: PHAssetCollection) {
        rememberAlbum(localIdentifier: collection.localIdentifier)
    }

    private static func rememberAlbum(localIdentifier: String) {
        UserDefaults.standard.set(localIdentifier, forKey: albumIdKey)
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

    private static func performChanges(_ block: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
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
    }

    private static func fileByteCount(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber else { return 0 }
        return n.int64Value
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
