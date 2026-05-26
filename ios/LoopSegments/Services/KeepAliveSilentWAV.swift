import Foundation

/// Minimal PCM WAV (mono 16-bit) for `AVAudioPlayer` — no disk I/O, no CAF writer.
enum KeepAliveSilentWAV {
  static func data(durationSeconds: Double = 1.0, sampleRate: UInt32 = 22_050) -> Data {
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let blockAlign = channels * (bitsPerSample / 8)
    let byteRate = sampleRate * UInt32(blockAlign)
    let sampleCount = max(1, Int(Double(sampleRate) * durationSeconds))
    let dataByteCount = sampleCount * Int(blockAlign)

    var data = Data()
    data.reserveCapacity(44 + dataByteCount)

    func appendLE<T: FixedWidthInteger>(_ value: T) {
      var v = value.littleEndian
      withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
    appendLE(UInt32(36 + dataByteCount))
    data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
    data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // fmt
    appendLE(UInt32(16))
    appendLE(UInt16(1)) // PCM
    appendLE(channels)
    appendLE(sampleRate)
    appendLE(byteRate)
    appendLE(blockAlign)
    appendLE(bitsPerSample)
    data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
    appendLE(UInt32(dataByteCount))
    data.append(Data(count: dataByteCount))
    return data
  }
}
