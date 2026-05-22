import AVFoundation
import Foundation

/// Grows `pcld_ios_media/_working_pcloud_transcode.mp4` from pCloud HLS (0 → export cursor).
enum PCloudTranscodedWorkingWriter {
    private static let exportPresets = [
        AVAssetExportPresetPassthrough,
        AVAssetExportPreset1280x720,
        AVAssetExportPresetHighestQuality,
    ]

    static func prepareForNewExport(log: @escaping (String) -> Void) {
        ExportPaths.removeWorkingSourceCopy(log: log)
        ExportPaths.removeTranscodedWorkingCopy(log: log)
        ExportPlaybackState.shared.setPCloudTranscodedWorkingActive(true)
    }

    static func updateProgressive(
        asset: AVURLAsset,
        throughSeconds: Double,
        log: @escaping (String) -> Void
    ) async throws {
        guard throughSeconds > 0.5 else { return }
        let outputURL = ExportPaths.workingTranscodedURL
        let stagingURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("_working_pcloud_transcode.staging.mp4")
        let fm = FileManager.default
        try? fm.removeItem(at: stagingURL)

        let duration = CMTime(seconds: throughSeconds, preferredTimescale: 600)
        var lastError: Error?
        for preset in exportPresets {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            session.outputURL = stagingURL
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            session.timeRange = CMTimeRange(start: .zero, duration: duration)
            await session.export()
            switch session.status {
            case .completed:
                if fm.fileExists(atPath: outputURL.path) {
                    _ = try fm.replaceItemAt(outputURL, withItemAt: stagingURL)
                } else {
                    try fm.moveItem(at: stagingURL, to: outputURL)
                }
                let bytes = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                ExportPlaybackState.shared.updateTranscodedWorkingFileBytes(bytes)
                log(
                    "Transcoded LAN copy — \(ExportPaths.pathRelativeToExports(outputURL)) " +
                        "updated through \(ExportTimelineLog.wallClock(seconds: throughSeconds)) " +
                        "(\(formatBytes(bytes)); pCloud HLS, not original file)"
                )
                return
            case .cancelled:
                throw CancellationError()
            case .failed:
                lastError = session.error
                try? fm.removeItem(at: stagingURL)
            default:
                try? fm.removeItem(at: stagingURL)
                lastError = SegmentExporterError.writerSetupFailed
            }
        }
        throw lastError ?? SegmentExporterError.writerSetupFailed
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", Double(bytes) / 1_073_741_824.0)
        }
        if bytes >= 1024 * 1024 {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
        }
        return "\(bytes) B"
    }
}
