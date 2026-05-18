import Foundation

/// Removes rotating segment files from app storage and the Photos library.
enum SegmentCleanup {
    static func removeAllSegments(log: ((String) -> Void)? = nil) async {
        removeExportFiles(log: log)
        await PhotosSegmentPublisher.removeAllPublished(log: log)
    }

    static func removeExportFiles(log: ((String) -> Void)? = nil) {
        ExportPaths.removeWorkingSourceCopy(log: log)
        for index in 0 ..< ExportPaths.segmentFileCount {
            let staging = ExportPaths.segmentStagingURL(index: index)
            if FileManager.default.fileExists(atPath: staging.path) {
                try? FileManager.default.removeItem(at: staging)
                log?("Removed \(staging.lastPathComponent) from Exports")
            }
            let url = ExportPaths.segmentURL(index: index)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                log?("Removed \(url.lastPathComponent) from Exports")
            } catch {
                log?("Could not remove \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        for legacy in ["3d_op_01.mp4", "3d_op_01.staging.mp4"] {
            let url = ExportPaths.exportsDirectory.appendingPathComponent(legacy)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.removeItem(at: url)
            log?("Removed legacy \(legacy) from Exports")
        }
    }
}
