import Foundation

/// Removes rotating segment files from app storage and the Photos library.
enum SegmentCleanup {
    static func removeAllSegments(log: ((String) -> Void)? = nil) async {
        removeExportFiles(log: log)
        await PhotosSegmentPublisher.removeAllPublished(log: log)
    }

    static func removeExportFiles(log: ((String) -> Void)? = nil) {
        for index in 0 ..< ExportPaths.segmentFileCount {
            let url = ExportPaths.segmentURL(index: index)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                log?("Removed \(url.lastPathComponent) from Exports")
            } catch {
                log?("Could not remove \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}
