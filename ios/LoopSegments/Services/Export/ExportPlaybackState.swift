import Foundation

/// LAN playback hints for `_export_source_working.mp4` (sparse; moov reports full duration).
final class ExportPlaybackState: @unchecked Sendable {
    static let shared = ExportPlaybackState()

    private struct Snapshot: Sendable {
        var playbackStartSeconds: Double = 0
        var exportCursorSeconds: Double = 0
        var durationSeconds: Double = 0
        var totalFileBytes: Int64 = 0
        var indexTailStart: Int64 = 0
        var headOnDisk = false
        var tailOnDisk = false
        var filledSpans: [ClosedRange<Int64>] = []
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()

    private init() {}

    func beginExport(seekSeconds: Double, durationSeconds: Double, totalBytes: Int64) {
        lock.withLock {
            snapshot.playbackStartSeconds = max(0, seekSeconds)
            snapshot.exportCursorSeconds = snapshot.playbackStartSeconds
            snapshot.durationSeconds = max(0, durationSeconds)
            snapshot.totalFileBytes = totalBytes
            snapshot.indexTailStart = max(
                0,
                totalBytes - WebDAVTempFileDownload.indexTailFetchBytes(totalLength: totalBytes)
            )
            snapshot.headOnDisk = false
            snapshot.tailOnDisk = false
            snapshot.filledSpans = []
        }
    }

    func updateCursor(seconds: Double) {
        lock.withLock {
            snapshot.exportCursorSeconds = max(0, seconds)
        }
    }

    func syncSparseLayout(
        totalBytes: Int64,
        filledSpans: [ClosedRange<Int64>],
        headOnDisk: Bool,
        tailOnDisk: Bool
    ) {
        lock.withLock {
            snapshot.totalFileBytes = totalBytes
            snapshot.filledSpans = filledSpans
            snapshot.headOnDisk = headOnDisk
            snapshot.tailOnDisk = tailOnDisk
            snapshot.indexTailStart = max(
                0,
                totalBytes - WebDAVTempFileDownload.indexTailFetchBytes(totalLength: totalBytes)
            )
        }
    }

    var playbackStartSecondsInt: Int {
        lock.withLock { Int(snapshot.playbackStartSeconds.rounded(.down)) }
    }

    func rangeIsReadable(start: Int64, end: Int64) -> Bool {
        let snap = lock.withLock { snapshot }
        guard snap.totalFileBytes > 0, start >= 0, end >= start, end < snap.totalFileBytes else {
            return false
        }
        var cursor = start
        while cursor <= end {
            guard let servedEnd = Self.endOfServedRun(from: cursor, maxEnd: end, snap: snap) else {
                return false
            }
            cursor = servedEnd + 1
        }
        return true
    }

    var frozenPlaybackStartSecondsInt: Int {
        lock.withLock { Int(snapshot.playbackStartSeconds.rounded(.down)) }
    }

    var frozenStatusPayload: [String: Any] {
        let snap = lock.withLock { snapshot }
        return [
            "playbackStartSeconds": snap.playbackStartSeconds,
            "exportCursorSeconds": snap.exportCursorSeconds,
            "durationSeconds": snap.durationSeconds,
            "totalBytes": snap.totalFileBytes,
            "indexTailStart": snap.indexTailStart,
            "headOnDisk": snap.headOnDisk,
            "tailOnDisk": snap.tailOnDisk,
        ]
    }

    private static func endOfServedRun(
        from offset: Int64,
        maxEnd: Int64,
        snap: Snapshot
    ) -> Int64? {
        if snap.headOnDisk {
            let headEnd = min(maxEnd, min(Int64(512 * 1024) - 1, snap.totalFileBytes - 1))
            if offset <= headEnd {
                return headEnd
            }
        }
        for span in snap.filledSpans {
            if offset >= span.lowerBound, offset <= span.upperBound {
                return min(maxEnd, span.upperBound)
            }
        }
        if snap.tailOnDisk, offset >= snap.indexTailStart {
            return maxEnd
        }
        return nil
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
