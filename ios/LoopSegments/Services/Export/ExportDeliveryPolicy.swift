import Foundation

/// Export timing and transport when delivering segments to Photos (and DLNA).
enum ExportDeliveryPolicy {
    /// Target wall time for first segment in Photos after export start.
    static let firstPhotosTargetSeconds: Double = 72
    /// Max seconds between published DLNA/Photos slot updates (wall clock).
    static let segmentPublishCadenceSeconds: Double = 60
    /// Reject passthrough if the first keyframe is farther than this into the 60s window.
    static let maxKeyframeStartOffsetSeconds: Double = 5

    /// Stream each minute from pCloud (no sparse + dense temp). Favors speed and correct MP4 ranges over disk/cellular savings.
    static var preferStreamPerSegment: Bool {
        PhotosSegmentPublisher.isEnabled
    }

    /// Publish first segment to Photos/DLNA as soon as it is ready (no wall-clock hold).
    static var prioritizeFirstPhotosPublish: Bool {
        PhotosSegmentPublisher.isEnabled
    }
}
