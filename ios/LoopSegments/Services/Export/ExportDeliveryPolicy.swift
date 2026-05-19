import Foundation

/// Export timing and transport for DLNA (and optional Photos when `PhotosSegmentPublisher.workflowEnabled`).
enum ExportDeliveryPolicy {
    /// Target wall time for first segment in Photos after export start.
    static let firstPhotosTargetSeconds: Double = 72
    /// Max seconds between published DLNA/Photos slot updates (wall clock).
    static let segmentPublishCadenceSeconds: Double = 60
    /// Reject passthrough if the first keyframe is farther than this into the 60s window.
    static let maxKeyframeStartOffsetSeconds: Double = 5

    /// Stream each minute from pCloud (no sparse + dense temp). Off by default; Photos uses dense fill then library import.
    static var preferStreamPerSegment: Bool {
        false
    }

    /// Publish first segment to Photos/DLNA as soon as it is ready (no wall-clock hold).
    static var prioritizeFirstPhotosPublish: Bool {
        PhotosSegmentPublisher.isEnabled
    }
}
