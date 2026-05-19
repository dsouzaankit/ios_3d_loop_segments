import Foundation

/// Export timing and transport for DLNA (and optional Photos when `PhotosSegmentPublisher.workflowEnabled`).
enum ExportDeliveryPolicy {
    /// Target wall time for first segment in Photos after export start.
    static let firstPhotosTargetSeconds: Double = 72
    /// Target media duration per exported segment (cut at next keyframe at/after this).
    static let targetSegmentDurationSeconds: Double = 60
    /// Max seconds between published DLNA/Photos slot updates (wall clock).
    static let segmentPublishCadenceSeconds: Double = targetSegmentDurationSeconds
    /// Reject passthrough if the first keyframe is farther than this into the segment window.
    static let maxKeyframeStartOffsetSeconds: Double = 5
    /// Read past nominal end while hunting for the closing keyframe (drop trailing non-sync frames).
    static let keyframeEndHuntSeconds: Double = 12
    /// When true, segment windows chain from keyframe to keyframe instead of a fixed 60s grid.
    static let keyframeAlignedBoundaries: Bool = true

    /// Publish first segment as soon as it is ready (no wall-clock hold). Not tied to Photos.
    static var prioritizeFirstPhotosPublish: Bool {
        true
    }
}
