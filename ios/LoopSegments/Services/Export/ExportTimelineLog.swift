import CoreMedia
import Foundation

/// Human-readable source media times for export logs (wall clock + ms).
enum ExportTimelineLog {
    static func wallClock(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "?:??" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func wallClock(_ time: CMTime) -> String {
        wallClock(seconds: CMTimeGetSeconds(time))
    }

    static func milliseconds(_ seconds: Double) -> Int64 {
        Int64((max(0, seconds) * 1000).rounded())
    }

    /// e.g. `15:00–16:00 (900000–960000 ms)`
    static func sourceRange(startSeconds: Double, endSeconds: Double) -> String {
        let startMs = milliseconds(startSeconds)
        let endMs = milliseconds(endSeconds)
        return "\(wallClock(seconds: startSeconds))–\(wallClock(seconds: endSeconds)) (\(startMs)–\(endMs) ms)"
    }

    static func sourceRange(start: CMTime, end: CMTime) -> String {
        sourceRange(
            startSeconds: CMTimeGetSeconds(start),
            endSeconds: CMTimeGetSeconds(end)
        )
    }

    static func processingMinute(index: Int, startSeconds: Double, endSeconds: Double) -> String {
        "Processing minute \(index + 1) — source \(sourceRange(startSeconds: startSeconds, endSeconds: endSeconds))"
    }
}
