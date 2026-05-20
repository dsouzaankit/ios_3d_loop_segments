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

        if moovPresentInFirstBytes(of: fileURL, scanBytes: moovScanBytes) {
            log("Segment moov in file head — OK for Skybox / LAN streaming")
            return
        }

        log("Segment has moov-at-end — remuxing with network optimize (Skybox / WebDAV)")
        try await remuxWithFastStart(at: fileURL, log: log)
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

    private static func remuxWithFastStart(
        at fileURL: URL,
        log: @escaping (String) -> Void
    ) async throws {
        let asset = AVURLAsset(url: fileURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw SegmentExporterError.writerSetupFailed
        }
        let temp = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".faststart-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temp) }
        try? FileManager.default.removeItem(at: temp)
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
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temp, backupItemName: nil, options: [])
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
