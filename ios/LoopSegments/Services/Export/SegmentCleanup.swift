import Foundation

/// Removes rotating segment files from app storage and the Photos library.
enum SegmentCleanup {
    /// Stop: segment MP4s + Photos only (root working/vanilla copies archived separately on Stop).
    static func removeAllSegments(log: ((String) -> Void)? = nil) async {
        removeExportFiles(log: log)
        await PhotosSegmentPublisher.removeAllPublished(log: log)
    }

    /// Stop / `stop_export`: drop `loop/` (+ Photos when enabled), archive root copies, prune to retention limit.
    @discardableResult
    static func performStopCleanup(log: ((String) -> Void)? = nil) async -> Int {
        await removeAllSegments(log: log)
        let timestamp = ExportMediaArchive.newRetentionTimestamp()
        let archived = ExportMediaArchive.archiveActiveMedia(timestamp: timestamp, log: log)
        if archived > 0 {
            _ = ExportMediaArchive.pruneRetainedMedia(keepCount: ExportMediaArchive.retentionCount, log: log)
            log?(
                "Stop: archived \(archived) file(s) to pcld_ios_media/archive/ " +
                    "(<name>[_3D_<n>K]_<local-time>; loop/ removed)"
            )
        } else {
            log?("Stop: removed pcld_ios_media/loop/op_*.mp4 (no root media to archive)")
        }
        return archived
    }


    /// End of export: move active root copies into `pcld_ios_media/archive/` and prune to retention limit (`loop/` unchanged).
    @discardableResult
    static func archiveFinishedExportMedia(log: ((String) -> Void)? = nil) -> Int {
        guard ExportMediaArchive.hasActiveExportMediaOnDisk() else { return 0 }
        let timestamp = ExportMediaArchive.newRetentionTimestamp()
        let archived = ExportMediaArchive.archiveActiveMedia(timestamp: timestamp, log: log)
        if archived > 0 {
            _ = ExportMediaArchive.pruneRetainedMedia(keepCount: ExportMediaArchive.retentionCount, log: log)
        }
        return archived
    }

    /// Segment MP4s, staging files, working/vanilla copies, and archived exports under `pcld_ios_media/archive/` (not Photos).
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
        removed += ExportMediaArchive.removeAllRetainedMedia(log: log)
        return removed
    }

    /// Drop older archived exports; keep the newest `keepCount` under `pcld_ios_media/archive/` (active slot untouched).
    @discardableResult
    static func trimExportMediaArchives(keepCount: Int = ExportMediaArchive.manualKeepCount, log: ((String) -> Void)? = nil) -> Int {
        ExportMediaArchive.pruneRetainedMedia(keepCount: keepCount, log: log)
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
