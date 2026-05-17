import AVFoundation
import CoreMedia
import Foundation

/// Confirms a local temp file can supply a full passthrough window before we write a segment.
enum SegmentLocalReadiness {
  private static let minVideoSamplesFor60s = 24
  private static let minOutputBytes: Int64 = 512 * 1024

  static func waitUntilReadable(
    fileURL: URL,
    rangeStart: CMTime,
    rangeDuration: CMTime,
    contiguousBytesOnDisk: () -> Int64,
    bytesRequiredOnDisk: Int64,
    isCancelled: () -> Bool,
    log: (String) -> Void
  ) async throws {
    var lastLog = CFAbsoluteTimeGetCurrent()
    while true {
      if isCancelled() { throw SegmentExporterError.cancelled }
      let contiguous = contiguousBytesOnDisk()
      if contiguous < bytesRequiredOnDisk {
        try await Task.sleep(nanoseconds: 250_000_000)
        continue
      }

      switch probeWindow(fileURL: fileURL, rangeStart: rangeStart, rangeDuration: rangeDuration) {
      case .ok(let videoSamples):
        log("Readiness OK — \(videoSamples) video samples in window (\(formatBytes(contiguous)) on disk)")
        return
      case .needsMoreData(let reason):
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLog >= 15 {
          lastLog = now
          log("Waiting for clearer source — \(reason) (\(formatBytes(contiguous)) / \(formatBytes(bytesRequiredOnDisk)))")
        }
      case .failed(let error):
        throw error
      }
      try await Task.sleep(nanoseconds: 400_000_000)
    }
  }

  static func validateOutputFile(at url: URL, log: (String) -> Void) throws {
    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
      .int64Value ?? 0
    guard bytes >= minOutputBytes else {
      throw SegmentExporterError.segmentOutputTooSmall(bytes)
    }
    log("Segment size OK — \(bytes / 1024) KB")
  }

  private enum ProbeResult {
    case ok(videoSamples: Int)
    case needsMoreData(String)
    case failed(Error)
  }

  private static func probeWindow(
    fileURL: URL,
    rangeStart: CMTime,
    rangeDuration: CMTime
  ) -> ProbeResult {
    let asset = AVURLAsset(
      url: fileURL,
      options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
      return .needsMoreData("no video track visible yet")
    }

    let rangeEnd = CMTimeAdd(rangeStart, rangeDuration)
    guard let reader = try? AVAssetReader(asset: asset) else {
      return .needsMoreData("cannot open reader")
    }
    reader.timeRange = CMTimeRange(start: rangeStart, end: rangeEnd)

    let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output), reader.startReading() else {
      return .needsMoreData("reader not ready")
    }

    var videoCount = 0
    var sawKeyframe = false
    var lastPTS = rangeStart

    while reader.status == .reading {
      guard let sample = output.copyNextSampleBuffer() else { break }
      videoCount += 1
      let pts = CMSampleBufferGetPresentationTimeStamp(sample)
      if CMTimeCompare(pts, rangeStart) >= 0, isSyncVideoSample(sample) {
        sawKeyframe = true
      }
      if CMTimeCompare(pts, rangeStart) >= 0 {
        lastPTS = pts
      }
    }

    if reader.status == .failed {
      return .needsMoreData("read stopped early")
    }

    let coveredSeconds = CMTimeGetSeconds(CMTimeSubtract(lastPTS, rangeStart))
    let needSeconds = CMTimeGetSeconds(rangeDuration) * 0.85

    if !sawKeyframe {
      return .needsMoreData("no keyframe in window yet")
    }
    if videoCount < minVideoSamplesFor60s {
      return .needsMoreData("only \(videoCount) video samples (incomplete)")
    }
    if coveredSeconds < needSeconds {
      return .needsMoreData(String(format: "timeline covers %.0fs, need ~%.0fs", coveredSeconds, needSeconds))
    }
    return .ok(videoSamples: videoCount)
  }

  private static func isSyncVideoSample(_ sample: CMSampleBuffer) -> Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[AnyHashable: Any]],
          let first = attachments.first else {
      return true
    }
    if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
      return !notSync
    }
    return true
  }

  private static func formatBytes(_ bytes: Int64) -> String {
    if bytes >= 1024 * 1024 {
      return String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
    }
    return "\(bytes) B"
  }
}
