import Foundation

/// Removes rotating segment files from app storage and the Photos library.
enum SegmentCleanup {
    /// Stop: segment MP4s + Photos only (`_working.mp4` kept until next export or Clear media).
    static func removeAllSegments(log: ((String) -> Void)? = nil) async {
        removeExportFiles(log: log)
        await PhotosSegmentPublisher.removeAllPublished(log: log)
    }

    /// Segment MP4s, staging files, and `_working.mp4` in `Exports/` (not Photos).
    @discardableResult
    static func removeExportMedia(log: ((String) -> Void)? = nil) -> Int {
        var removed = removeExportFiles(log: log)
        if ExportPaths.removeWorkingSourceCopy(log: log) {
            removed += 1
        }
        if ExportPaths.removeTranscodedWorkingCopy(log: log) {
            removed += 1
        }
        if ExportPaths.removeVanillaDownloadCopies(log: log) {
            removed += 1
        }
        return removed
    }

    @discardableResult
    static func removeExportFiles(log: ((String) -> Void)? = nil) -> Int {
        var removed = 0
        for index in 0 ..< ExportPaths.segmentFileCount {
            let staging = ExportPaths.segmentStagingURL(index: index)
            if FileManager.default.fileExists(atPath: staging.path) {
                try? FileManager.default.removeItem(at: staging)
                removed += 1
                log?("Removed \(staging.lastPathComponent) from Exports")
            }
            let url = ExportPaths.segmentURL(index: index)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
                log?("Removed \(url.lastPathComponent) from Exports")
            } catch {
                log?("Could not remove \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        for legacy in [
            "3d_op_00.mp4", "3d_op_01.mp4",
            "3d_op_00.staging.mp4", "3d_op_01.staging.mp4",
            "op_00.mp4", "op_01.mp4", "op_00.staging.mp4", "op_01.staging.mp4",
            "_export_source_working.mp4", "_export_source_working.sparse.json",
        ] {
            let url = ExportPaths.exportsDirectory.appendingPathComponent(legacy)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.removeItem(at: url)
            removed += 1
            log?("Removed legacy \(legacy) from Exports")
        }
        let legacyLoop = ExportPaths.exportsDirectory.appendingPathComponent("loop", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyLoop.path),
           (try? FileManager.default.contentsOfDirectory(atPath: legacyLoop.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: legacyLoop)
            removed += 1
            log?("Removed empty legacy loop/ folder")
        }
        return removed
    }
}
