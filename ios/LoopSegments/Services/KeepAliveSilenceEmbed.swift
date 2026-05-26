import Foundation

/// Compile-time copy of `LoopSegments/Resources/KeepAlive_silence.mp3` (used when the bundle resource is missing).
enum KeepAliveSilenceEmbed {
    static let mp3Data = Data(#embed("../Resources/KeepAlive_silence.mp3"))
}
