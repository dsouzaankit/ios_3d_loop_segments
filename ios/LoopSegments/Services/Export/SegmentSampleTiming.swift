import CoreMedia
import Foundation

/// Retimes passthrough samples so segment MP4 timelines start at 0 (matches ffmpeg `-reset_timestamps 1`).
enum SegmentSampleTiming {
    static func retimeToSegmentStart(
        _ sample: CMSampleBuffer,
        subtract origin: CMTime
    ) throws -> CMSampleBuffer {
        var entryCount: CMItemCount = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &entryCount
        )
        guard status == noErr, entryCount > 0 else { return sample }

        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: entryCount)
        status = CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: entryCount,
            arrayToFill: &timing,
            entriesNeededOut: &entryCount
        )
        guard status == noErr else { return sample }

        for index in 0 ..< Int(entryCount) {
            timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, origin)
            if CMTIME_IS_VALID(timing[index].decodeTimeStamp) {
                var dts = CMTimeSubtract(timing[index].decodeTimeStamp, origin)
                if dts.seconds < 0 {
                    dts = .zero
                }
                timing[index].decodeTimeStamp = dts
            }
        }

        var output: CMSampleBuffer?
        status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: entryCount,
            sampleTimingArray: &timing,
            sampleBufferOut: &output
        )
        guard status == noErr, let output else {
            throw SegmentExporterError.writerSetupFailed
        }
        return output
    }
}
