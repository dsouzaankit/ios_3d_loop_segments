import AVFoundation
import CoreMedia
import Foundation
import Photos

/// Publishes finished segment MP4s to the Photos library (visible for Recents and PC import).
/// Uses a temporary passthrough remux only — never modifies `3d_op_*.mp4` (DLNA/USB keep full HEVC).
enum PhotosSegmentPublisher {
    private static let enabledKey = "publishSegmentsToPhotos"
    private static let assetIdsKey = "photos_segment_asset_local_ids"
    /// Legacy visible album id (removed assets from old builds when cleaning up).
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    @discardableResult
    static func ensureAccess(log: ((String) -> Void)? = nil) async -> Bool {
        let status = await requestAuthorizationIfNeeded()
        switch status {
        case .authorized:
            return true
        case .limited:
            log?("Photos: Limited access — use Settings → Loop Segments → Photos → Full Access for reliable PC import.")
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
        guard await videoIsPlayableForPhotos(url: videoURL, log: log) else { return }

        do {
            try await deletePreviousAsset(slot: segmentSlot)
            let filename = videoURL.lastPathComponent
            let importURL = try await photosCompatibleCopy(from: videoURL, preferredFilename: filename, log: log)
            defer { try? FileManager.default.removeItem(at: importURL) }
            let assetId = try await importVideo(url: importURL, originalFilename: filename)
            storeAssetId(assetId, slot: segmentSlot)
            log("Photos: saved as \(filename) (\(bytes / 1024) KB) → Photos library")
        } catch {
            log("Photos: failed \(videoURL.lastPathComponent) — \(describePhotosError(error))")
        }
    }

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
                log?("Photos: removed \(fetch.count) segment clip(s)")
            }
            clearStoredAssetIds()
        } catch {
            log?("Photos: could not remove clips — \(error.localizedDescription)")
            clearStoredAssetIds()
        }
    }

    // MARK: - Private

    private static func videoIsPlayableForPhotos(url: URL, log: @escaping (String) -> Void) async -> Bool {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else {
                log("Photos: skipped \(url.lastPathComponent) — no video track (file may still be writing)")
                return false
            }
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, CMTimeGetSeconds(duration) > 0.5 else {
                log("Photos: skipped \(url.lastPathComponent) — duration too short for Photos")
                return false
            }
            return true
        } catch {
            log("Photos: skipped \(url.lastPathComponent) — not readable yet (\(error.localizedDescription))")
            return false
        }
    }

    /// Passthrough remux for Photos only (same HEVC/H.264 — no downscale; DLNA slot file is not touched).
    private static func photosCompatibleCopy(
        from source: URL,
        preferredFilename: String,
        log: @escaping (String) -> Void
    ) async throws -> URL {
        let safeName = sanitizedPhotosFilename(preferredFilename)
        log("Photos: passthrough remux for library import (DLNA \(source.lastPathComponent) unchanged)")
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw PhotosPublishError.changeFailed
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoopSegments-\(safeName)")
        try? FileManager.default.removeItem(at: dest)
        session.outputURL = dest
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        let ok = await runExportSession(session)
        guard ok, fileByteCount(dest) > 8192 else {
            if let err = session.error {
                throw err
            }
            throw PhotosPublishError.changeFailed
        }
        log("Photos: remux ready (\(fileByteCount(dest) / 1024) KB, same codec as DLNA file)")
        return dest
    }

    private static func runExportSession(_ session: AVAssetExportSession) async -> Bool {
        await withCheckedContinuation { continuation in
            session.exportAsynchronously {
                continuation.resume(returning: session.status == .completed)
            }
        }
    }

    private static func describePhotosError(_ error: Error) -> String {
        let ns = error as NSError
        var parts = [error.localizedDescription]
        if ns.domain == PHPhotosErrorDomain || ns.domain == "PHPhotosErrorDomain" {
            parts.append("code \(ns.code)")
            if ns.code == 3302 {
                parts.append(
                    "(invalidResource — DLNA file unchanged; use USB/Exports copy. Try Photos Full Access or disable Photos export.)"
                )
            }
        }
        return parts.joined(separator: " ")
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

    private static func importVideo(url: URL, originalFilename: String) async throws -> String {
        var createdId: String?
        let filename = sanitizedPhotosFilename(originalFilename)
        try await performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            options.uniformTypeIdentifier = "public.mpeg-4"
            request.addResource(with: .video, fileURL: url, options: options)
            createdId = request.placeholderForCreatedAsset?.localIdentifier
        }

        guard let createdId else {
            throw PhotosPublishError.noAssetCreated
        }
        return createdId
    }

    /// Photos uses the import file name unless `originalFilename` is set; avoid random `photos-import-<uuid>.mp4`.
    private static func sanitizedPhotosFilename(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "3d_op_segment.mp4"
        guard !base.isEmpty else { return fallback }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = String(base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? fallback : cleaned
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
    case changeFailed

    var errorDescription: String? {
        switch self {
        case .noAssetCreated: return "Could not add video to Photos."
        case .changeFailed: return "Photos library update failed."
        }
    }
}
