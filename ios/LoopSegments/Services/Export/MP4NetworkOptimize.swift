import AVFoundation
import Foundation

/// Puts the MP4 `moov` atom near the start so HTTP/WebDAV players (Skybox, DLNA) can open without a full download.
enum MP4NetworkOptimize {
    private static let moovScanBytes: Int = 768 * 1024

    static func ensureMoovAtStartIfNeeded(
        at fileURL: URL,
        log: @escaping (String) -> Void
    ) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 8192 else { return }

        if sourceAlreadyNetworkOptimized(at: fileURL) {
            log("Segment moov in file head — OK for Skybox / LAN streaming")
            return
        }
        if await shouldSkipFaststartRemuxToPreserveAudio(at: fileURL, log: log) {
            return
        }

        log("Segment has moov-at-end — remuxing with network optimize (Skybox / WebDAV)")
        try await remuxWithFastStart(from: fileURL, to: fileURL, log: log)
        if moovPresentInFirstBytes(of: fileURL, scanBytes: moovScanBytes) {
            log("Faststart remux finished — moov now in file head")
        } else {
            log("Faststart remux finished (moov scan still past head — file may be very large)")
        }
    }

    static func moovPresentInFirstBytes(of fileURL: URL, scanBytes: Int) -> Bool {
        let fm = FileManager.default
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        let toRead = min(
            scanBytes,
            Int((try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? scanBytes)
        )
        guard toRead > 8 else { return false }
        guard let data = try? handle.read(upToCount: toRead), data.count > 8 else { return false }
        return data.range(of: Data("moov".utf8)) != nil
    }

    /// True when the first ~768 KiB already contain `moov` (pCloud / upload faststart).
    static func sourceAlreadyNetworkOptimized(at fileURL: URL) -> Bool {
        moovPresentInFirstBytes(of: fileURL, scanBytes: moovScanBytes)
    }

    /// AVAssetExport passthrough keeps AAC; AC-3 / E-AC-3 / DTS / PCM become silent — skip those segments.
    private static func audioSurvivesFaststartPassthrough(_ format: CMFormatDescription) -> Bool {
        if CodecSupport.canPassthroughAudio(format) { return true }
        let codec = CMFormatDescriptionGetMediaSubType(format)
        return codec == kAudioFormatMPEG4AAC_HE
            || codec == kAudioFormatMPEG4AAC_HE_V2
            || codec == kAudioFormatMPEG4AAC_LD
            || codec == kAudioFormatMPEG4AAC_ELD
            || codec == kAudioFormatMPEG4AAC_ELD_SBR
            || codec == kAudioFormatMPEG4AAC_ELD_V2
    }

    /// `true` = do not remux (keep source so soundtrack is not stripped).
    private static func shouldSkipFaststartRemuxToPreserveAudio(
        at fileURL: URL,
        log: @escaping (String) -> Void
    ) async -> Bool {
        let asset = AVURLAsset(url: fileURL)
        let audioTracks: [AVAssetTrack]
        let videoTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            log(
                "Faststart remux skipped — cannot inspect tracks yet " +
                    "(\(error.localizedDescription)); keeping \(fileURL.lastPathComponent)"
            )
            return true
        }
        if videoTracks.isEmpty, audioTracks.isEmpty {
            log("Faststart remux skipped — no tracks readable yet; keeping \(fileURL.lastPathComponent)")
            return true
        }

        var dropped: [String] = []
        var sawAudioFormat = false
        for track in audioTracks {
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            for format in formats {
                sawAudioFormat = true
                if !audioSurvivesFaststartPassthrough(format) {
                    dropped.append(CodecSupport.fourCCString(format))
                }
            }
        }
        if !audioTracks.isEmpty, !sawAudioFormat {
            log(
                "Faststart remux skipped — audio track present but codec unread; " +
                    "keeping \(fileURL.lastPathComponent)"
            )
            return true
        }
        if !dropped.isEmpty {
            let unique = Array(Set(dropped)).sorted()
            log(
                "Faststart remux skipped — audio \(unique.joined(separator: ", ")) " +
                    "would not survive AVFoundation passthrough (need AAC); " +
                    "keeping \(fileURL.lastPathComponent)"
            )
            return true
        }
        return false
    }

    private static func remuxWithFastStart(
        from sourceURL: URL,
        to destinationURL: URL,
        log: @escaping (String) -> Void
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw SegmentExporterError.writerSetupFailed
        }
        let temp = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".faststart-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temp) }
        try? FileManager.default.removeItem(at: temp)
        try? FileManager.default.removeItem(at: destinationURL)
        session.outputURL = temp
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }
        switch session.status {
        case .completed:
            let bytes = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?
                .int64Value ?? 0
            guard bytes > 8192 else {
                throw SegmentExporterError.segmentOutputTooSmall(0)
            }
            if destinationURL.standardizedFileURL == sourceURL.standardizedFileURL {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temp, backupItemName: nil, options: [])
            } else {
                try FileManager.default.moveItem(at: temp, to: destinationURL)
            }
        case .failed:
            let err = session.error ?? NSError(domain: "MP4NetworkOptimize", code: -1)
            log("Faststart remux failed: \(err.localizedDescription)")
            throw SegmentExporterError.writerFailed(err)
        case .cancelled:
            throw SegmentExporterError.cancelled
        default:
            throw SegmentExporterError.writerSetupFailed
        }
    }
}
