import CoreMedia
import Foundation

/// Timing result from one passthrough segment (source media timeline).
struct SegmentPassThroughResult {
    let segmentStart: CMTime
    let segmentEnd: CMTime
    /// Start of the next segment (sync frame after nominal cut); use for the following export window.
    let nextSegmentStart: CMTime

    var segmentDurationSeconds: Double {
        let seconds = CMTimeGetSeconds(CMTimeSubtract(segmentEnd, segmentStart))
        return seconds.isFinite ? max(0, seconds) : 0
    }

    var nextSegmentStartSeconds: Double {
        let seconds = CMTimeGetSeconds(nextSegmentStart)
        return seconds.isFinite ? max(0, seconds) : 0
    }

    /// Wall-clock window when passthrough does not report keyframe boundaries (export session fallback).
    static func nominal(rangeStart: CMTime, rangeDuration: CMTime) -> SegmentPassThroughResult {
        let end = CMTimeAdd(rangeStart, rangeDuration)
        return SegmentPassThroughResult(
            segmentStart: rangeStart,
            segmentEnd: end,
            nextSegmentStart: end
        )
    }
}
