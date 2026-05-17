import CoreMedia
import Foundation

/// HEVC often omits `NotSync` on sample attachments; scan for IDR/CRA NAL units before starting passthrough.
enum HEVCSyncSample {
  static func isReliableSyncPoint(_ sample: CMSampleBuffer, videoFormat: CMFormatDescription) -> Bool {
    if isSyncFromAttachments(sample) {
      return true
    }
    let codec = CMFormatDescriptionGetMediaSubType(videoFormat)
    guard codec == kCMVideoCodecType_HEVC else {
      return true
    }
    return containsRandomAccessPointNAL(sample)
  }

  private static func isSyncFromAttachments(_ sample: CMSampleBuffer) -> Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[AnyHashable: Any]] else {
      return true
    }
    for dict in attachments {
      if let notSync = dict[AnyHashable(kCMSampleAttachmentKey_NotSync)] as? Bool, notSync {
        return false
      }
      if let notSync = dict[AnyHashable(kCMSampleAttachmentKey_NotSync)] as? NSNumber, notSync.boolValue {
        return false
      }
    }
    return true
  }

  /// Length-prefixed MP4 HEVC: IDR_W_RADL(19), IDR_N_LP(20), CRA_NUT(21).
  private static func containsRandomAccessPointNAL(_ sample: CMSampleBuffer) -> Bool {
    guard let block = CMSampleBufferGetDataBuffer(sample) else { return false }
    var length = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(
      block,
      atOffset: 0,
      lengthAtOffsetOut: nil,
      totalLengthOut: &length,
      dataPointerOut: &dataPointer
    ) == noErr, let dataPointer, length >= 5 else {
      return false
    }

    var offset = 0
    let randomAccessTypes: Set<UInt8> = [19, 20, 21]
    while offset + 4 < length {
      let nalSize =
        (Int(dataPointer[offset]) << 24)
        | (Int(dataPointer[offset + 1]) << 16)
        | (Int(dataPointer[offset + 2]) << 8)
        | Int(dataPointer[offset + 3])
      offset += 4
      guard nalSize > 0, offset + nalSize <= length else { break }
      let header = UInt8(bitPattern: dataPointer[offset])
      let nalType = (header >> 1) & 0x3F
      if randomAccessTypes.contains(nalType) {
        return true
      }
      offset += nalSize
    }
    return false
  }
}
