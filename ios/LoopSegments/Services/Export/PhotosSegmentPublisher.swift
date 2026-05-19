import AVFoundation
import CoreMedia
import Foundation
import Photos

/// Publishes finished segment MP4s to the Photos library (optional; off by default — use LAN export to PC).
/// Uses a temporary passthrough remux only — never modifies `3d_op_*.mp4` (DLNA/USB keep full HEVC).
enum PhotosSegmentPublisher {
    /// Master switch — set `true` to re-enable Photos import UI and library sync.
    static let workflowEnabled = false

    private static let enabledKey = "publishSegmentsToPhotos"
    private static let alwaysH264Key = "photosAlwaysTranscodeH264"
    private static let assetIdsKey = "photos_segment_asset_local_ids"

    static var isEnabled: Bool {
        get {
            guard workflowEnabled else { return false }
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                return false
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            guard workflowEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    /// Skip passthrough remux/import; H.264 transcode only (slower, higher Photos acceptance on 8K HEVC).
    static var alwaysTranscodeH264ForPhotos: Bool {
        get {
            guard workflowEnabled else { return false }
            return UserDefaults.standard.bool(forKey: alwaysH264Key)
        }
        set {
            guard workflowEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: alwaysH264Key)
        }
    }

    @discardableResult
    static func ensureAccess(log: ((String) -> Void)? = nil) async -> Bool {
        guard workflowEnabled else { return false }
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

    @discardableResult
    static func publish(segmentSlot: Int, videoURL: URL, log: @escaping (String) -> Void) async -> Bool {
        guard workflowEnabled, isEnabled else { return false }
        guard await ensureAccess(log: log) else { return false }

        let bytes = fileByteCount(videoURL)
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            log("Photos: skipped slot \(segmentSlot) — file missing at \(videoURL.lastPathComponent)")
            return false
        }
        guard bytes > 8192 else {
            log("Photos: skipped \(videoURL.lastPathComponent) — file too small (\(bytes) B); wait for segment to finish writing")
            return false
        }
        guard await videoIsPlayableForPhotos(url: videoURL, log: log) else { return false }

        let probe = await probeImportResource(url: videoURL, label: "DLNA export")
        log("Photos: pre-import — \(probe.logLine)")
        for hint in probe.hints {
            log("Photos: hint — \(hint)")
        }

        do {
            try await deletePreviousAsset(slot: segmentSlot)
            let filename = videoURL.lastPathComponent
            let useH264First = alwaysTranscodeH264ForPhotos || probe.likelyNeedsH264Transcode

            let assetId: String
            if useH264First {
                if alwaysTranscodeH264ForPhotos {
                    log("Photos: H.264 transcode enabled (skipping passthrough import attempt)")
                } else {
                    log("Photos: using H.264 transcode first (\(probe.likelyH264Reason))")
                }
                let h264URL = try await transcodeH264ForPhotos(from: videoURL, preferredFilename: filename, log: log)
                defer { try? FileManager.default.removeItem(at: h264URL) }
                assetId = try await importVideo(url: h264URL, originalFilename: filename)
                log("Photos: H.264 import OK (\(fileByteCount(h264URL) / 1024) KB)")
            } else {
                let importURL = try await photosCompatibleCopy(
                    from: videoURL,
                    preferredFilename: filename,
                    log: log
                )
                defer { try? FileManager.default.removeItem(at: importURL) }
                assetId = try await importVideoWithH264Fallback(
                    importURL: importURL,
                    sourceURL: videoURL,
                    originalFilename: filename,
                    sourceProbe: probe,
                    log: log
                )
            }
            storeAssetId(assetId, slot: segmentSlot)
            log("Photos: saved as \(filename) (\(bytes / 1024) KB) → Photos library")
            return true
        } catch {
            log("Photos: failed \(videoURL.lastPathComponent) — \(describePhotosError(error))")
            return false
        }
    }

    static func publishAllSegmentsFromExports(log: @escaping (String) -> Void) async {
        guard workflowEnabled, isEnabled else { return }
        guard await ensureAccess(log: log) else { return }
        for slot in 0 ..< ExportPaths.segmentFileCount {
            let url = ExportPaths.segmentURL(index: slot)
            guard fileByteCount(url) > 8192 else { continue }
            await publish(segmentSlot: slot, videoURL: url, log: log)
        }
    }

    static func removeAllPublished(log: ((String) -> Void)? = nil) async {
        guard workflowEnabled else { return }
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

    private struct PhotosImportProbe {
        let label: String
        let videoCodec: String
        let audioCodec: String
        let dimensions: String
        let durationSeconds: Double
        let byteCount: Int64
        let hints: [String]
        let likelyNeedsH264Transcode: Bool
        let likelyH264Reason: String

        var logLine: String {
            String(
                format: "%@ — video %@ %@, audio %@, %.1fs, %lld KB",
                label,
                videoCodec,
                dimensions,
                audioCodec,
                durationSeconds,
                byteCount / 1024
            )
        }
    }

    private static func probeImportResource(url: URL, label: String) async -> PhotosImportProbe {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        var videoCodec = "?"
        var dimensions = "?"
        var audioCodec = "none"
        var durationSeconds = 0.0
        var hints: [String] = []

        if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first {
            if let formats = try? await videoTrack.load(.formatDescriptions),
               let first = formats.first {
                videoCodec = CodecSupport.fourCCString(first)
                let size = CMVideoFormatDescriptionGetDimensions(first)
                dimensions = "\(size.width)x\(size.height)"
                let codec = CMFormatDescriptionGetMediaSubType(first)
                if CodecSupport.isHEVCVideo(codec) {
                    if size.width > 1920 || size.height > 1920 {
                        hints.append("HEVC over 1920px often gets Photos 3302 (invalidResource)")
                    } else {
                        hints.append("HEVC may still get 3302 on some devices — H.264 fallback exists")
                    }
                }
            }
        } else {
            hints.append("no video track")
        }

        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let formats = try? await audioTrack.load(.formatDescriptions),
           let first = formats.first {
            audioCodec = CodecSupport.fourCCString(first)
            let codec = CMFormatDescriptionGetMediaSubType(first)
            if !isLikelyPhotosCompatibleAudio(codec) {
                hints.append("audio \(audioCodec) may trigger 3302 — H.264 transcode re-encodes to AAC")
            }
        }

        if let duration = try? await asset.load(.duration), duration.isNumeric {
            durationSeconds = CMTimeGetSeconds(duration)
            if durationSeconds < 0.5 {
                hints.append("duration under 0.5s")
            }
        }

        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if auth == .limited {
            hints.append("Photos Limited access — use Full Access in Settings")
        }

        let likelyReason: String
        let likely: Bool
        if CodecSupport.isHEVCVideo(fourCC(videoCodec)) {
            if dimensions.contains("x"),
               let dims = parseDimensions(dimensions),
               dims.width > 1920 || dims.height > 1920 {
                likely = true
                likelyReason = "HEVC \(dimensions)"
            } else {
                likely = false
                likelyReason = ""
            }
        } else if audioCodec != "none", !isLikelyPhotosCompatibleAudio(fourCC(audioCodec)) {
            likely = true
            likelyReason = "non-AAC audio \(audioCodec)"
        } else {
            likely = false
            likelyReason = ""
        }

        return PhotosImportProbe(
            label: label,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            dimensions: dimensions,
            durationSeconds: durationSeconds,
            byteCount: fileByteCount(url),
            hints: hints,
            likelyNeedsH264Transcode: likely,
            likelyH264Reason: likelyReason
        )
    }

    private static func importVideoWithH264Fallback(
        importURL: URL,
        sourceURL: URL,
        originalFilename: String,
        sourceProbe: PhotosImportProbe,
        log: @escaping (String) -> Void
    ) async throws -> String {
        do {
            return try await importVideo(url: importURL, originalFilename: originalFilename)
        } catch {
            guard isPhotosInvalidResource(error) else { throw error }
            let remuxProbe = await probeImportResource(url: importURL, label: "passthrough remux")
            log("Photos: import 3302 (invalidResource) on passthrough file — \(remuxProbe.logLine)")
            log("Photos: source was — \(sourceProbe.logLine)")
            for hint in remuxProbe.hints where !sourceProbe.hints.contains(hint) {
                log("Photos: 3302 hint — \(hint)")
            }
            if remuxProbe.hints.isEmpty, sourceProbe.hints.isEmpty {
                log(
                    "Photos: 3302 cause not exposed by iOS — common: HEVC/8K, audio codec, container; trying H.264 transcode"
                )
            }
            log("Photos: transcoding to H.264 for library only (DLNA \(sourceURL.lastPathComponent) unchanged)…")
            let h264URL = try await transcodeH264ForPhotos(
                from: sourceURL,
                preferredFilename: originalFilename,
                log: log
            )
            defer { try? FileManager.default.removeItem(at: h264URL) }
            let assetId = try await importVideo(url: h264URL, originalFilename: originalFilename)
            log("Photos: H.264 transcode import OK (\(fileByteCount(h264URL) / 1024) KB)")
            return assetId
        }
    }

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

    private static func photosCompatibleCopy(
        from source: URL,
        preferredFilename: String,
        log: @escaping (String) -> Void
    ) async throws -> URL {
        let safeName = sanitizedPhotosFilename(preferredFilename)
        log("Photos: passthrough remux for library import (DLNA \(source.lastPathComponent) unchanged)")
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let dest = try await exportToTempMP4(
            asset: asset,
            preset: AVAssetExportPresetPassthrough,
            filenamePrefix: "LoopSegments",
            safeName: safeName
        )
        log("Photos: remux ready (\(fileByteCount(dest) / 1024) KB, same codec as DLNA file)")
        return dest
    }

    private static func transcodeH264ForPhotos(
        from source: URL,
        preferredFilename: String,
        log: @escaping (String) -> Void
    ) async throws -> URL {
        let safeName = sanitizedPhotosFilename(preferredFilename)
        let isolatedSource = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoopSegments-src-\(safeName)")
        try? FileManager.default.removeItem(at: isolatedSource)
        try FileManager.default.copyItem(at: source, to: isolatedSource)
        defer { try? FileManager.default.removeItem(at: isolatedSource) }

        let asset = AVURLAsset(url: isolatedSource, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let compatible = Set(AVAssetExportSession.exportPresets(compatibleWith: asset))
        let presetCandidates = [
            AVAssetExportPreset1920x1080,
            AVAssetExportPreset1280x720,
            AVAssetExportPreset960x540,
            AVAssetExportPresetMediumQuality,
        ]
        let presets = presetCandidates.filter { compatible.contains($0) }
        guard !presets.isEmpty else {
            throw PhotosPublishError.changeFailed
        }
        log("Photos: H.264 transcode — may take 1–3 min per 60s segment on device")
        var lastFailure = "no preset succeeded"
        for preset in presets {
            log("Photos: trying \(preset)…")
            do {
                let dest = try await exportToTempMP4(
                    asset: asset,
                    preset: preset,
                    filenamePrefix: "LoopSegments-h264",
                    safeName: safeName
                )
                let outProbe = await probeImportResource(url: dest, label: "H.264 for Photos")
                log("Photos: transcode output (\(preset)) — \(outProbe.logLine)")
                return dest
            } catch {
                lastFailure = describePhotosError(error)
                log("Photos: \(preset) failed — \(lastFailure)")
            }
        }
        throw NSError(
            domain: "PhotosSegmentPublisher",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: lastFailure]
        )
    }

    private static func exportToTempMP4(
        asset: AVURLAsset,
        preset: String,
        filenamePrefix: String,
        safeName: String
    ) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw PhotosPublishError.changeFailed
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filenamePrefix)-\(preset)-\(safeName)")
        try? FileManager.default.removeItem(at: dest)
        session.outputURL = dest
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        let result = await runExportSession(session)
        guard result.succeeded, fileByteCount(dest) > 8192 else {
            throw result.error ?? PhotosPublishError.changeFailed
        }
        return dest
    }

    private static func isPhotosInvalidResource(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == PHPhotosErrorDomain || ns.domain == "PHPhotosErrorDomain" else { return false }
        return ns.code == 3302
    }

    private static func isLikelyPhotosCompatibleAudio(_ codec: FourCharCode) -> Bool {
        codec == kAudioFormatMPEG4AAC
            || codec == kAudioFormatMPEG4AAC_HE
            || codec == kAudioFormatMPEG4AAC_LD
            || codec == kAudioFormatMPEG4AAC_ELD
    }

    private static func fourCC(_ string: String) -> FourCharCode {
        guard string.count == 4 else { return 0 }
        var value: FourCharCode = 0
        for byte in string.utf8.prefix(4) {
            value = (value << 8) + FourCharCode(byte)
        }
        return value
    }

    private static func parseDimensions(_ text: String) -> (width: Int32, height: Int32)? {
        let parts = text.split(separator: "x")
        guard parts.count == 2,
              let w = Int32(parts[0]),
              let h = Int32(parts[1]) else { return nil }
        return (w, h)
    }

    private struct ExportSessionResult {
        let succeeded: Bool
        let error: Error?

        init(session: AVAssetExportSession) {
            succeeded = session.status == .completed
            error = session.error
        }
    }

    private static func runExportSession(_ session: AVAssetExportSession) async -> ExportSessionResult {
        await withCheckedContinuation { continuation in
            session.exportAsynchronously {
                continuation.resume(returning: ExportSessionResult(session: session))
            }
        }
    }

    private static func describePhotosError(_ error: Error) -> String {
        let ns = error as NSError
        var parts = [error.localizedDescription]
        if ns.domain != PHPhotosErrorDomain, ns.domain != "PHPhotosErrorDomain" {
            parts.append("\(ns.domain) \(ns.code)")
            if let reason = ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String, !reason.isEmpty {
                parts.append(reason)
            }
        }
        if ns.domain == PHPhotosErrorDomain || ns.domain == "PHPhotosErrorDomain" {
            parts.append("code \(ns.code)")
            if ns.code == 3302 {
                parts.append(
                    "(invalidResource — enable “H.264 for Photos” or use Exports/USB; DLNA file unchanged)"
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
