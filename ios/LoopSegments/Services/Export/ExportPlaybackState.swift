import Foundation

/// LAN playback hints for `_export_source_working.mp4` (sparse; moov reports full duration).
@MainActor
final class ExportPlaybackState {
    static let shared = ExportPlaybackState()

    private struct Frozen: Sendable {
        var playbackStartSeconds: Double = 0
        var exportCursorSeconds: Double = 0
        var durationSeconds: Double = 0
        var totalFileBytes: Int64 = 0
        var indexTailStart: Int64 = 0
        var headOnDisk = false
        var tailOnDisk = false
        var filledSpans: [ClosedRange<Int64>] = []
    }

    private var frozen = Frozen()
    private let frozenLock = NSLock()

    private(set) var playbackStartSeconds: Double = 0
    private(set) var exportCursorSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    private(set) var totalFileBytes: Int64 = 0
    private(set) var indexTailStart: Int64 = 0
    private(set) var headOnDisk = false
    private(set) var tailOnDisk = false
    private(set) var filledSpans: [ClosedRange<Int64>] = []

    private init() {}

    func beginExport(seekSeconds: Double, durationSeconds: Double, totalBytes: Int64) {
        playbackStartSeconds = max(0, seekSeconds)
        exportCursorSeconds = playbackStartSeconds
        self.durationSeconds = max(0, durationSeconds)
        totalFileBytes = totalBytes
        indexTailStart = max(0, totalBytes - WebDAVTempFileDownload.indexTailFetchBytes(totalLength: totalBytes))
        headOnDisk = false
        tailOnDisk = false
        filledSpans = []
        freeze()
    }

    func updateCursor(seconds: Double) {
        exportCursorSeconds = max(0, seconds)
        freeze()
    }

    func syncSparseLayout(
        totalBytes: Int64,
        filledSpans: [ClosedRange<Int64>],
        headOnDisk: Bool,
        tailOnDisk: Bool
    ) {
        totalFileBytes = totalBytes
        self.filledSpans = filledSpans
        self.headOnDisk = headOnDisk
        self.tailOnDisk = tailOnDisk
        indexTailStart = max(0, totalBytes - WebDAVTempFileDownload.indexTailFetchBytes(totalLength: totalBytes))
        freeze()
    }

    var playbackStartSecondsInt: Int {
        Int(playbackStartSeconds.rounded(.down))
    }

    var statusPayload: [String: Any] {
        [
            "playbackStartSeconds": playbackStartSeconds,
            "exportCursorSeconds": exportCursorSeconds,
            "durationSeconds": durationSeconds,
            "totalBytes": totalFileBytes,
            "indexTailStart": indexTailStart,
            "headOnDisk": headOnDisk,
            "tailOnDisk": tailOnDisk,
        ]
    }

    /// Thread-safe for `ExportLANServer` connection handlers.
    nonisolated func rangeIsReadable(start: Int64, end: Int64) -> Bool {
        let snap = frozenLock.withLock { frozen }
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

    nonisolated var frozenPlaybackStartSecondsInt: Int {
        let sec = frozenLock.withLock { frozen.playbackStartSeconds }
        return Int(sec.rounded(.down))
    }

    nonisolated var frozenStatusPayload: [String: Any] {
        let snap = frozenLock.withLock { frozen }
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

    private func freeze() {
        let next = Frozen(
            playbackStartSeconds: playbackStartSeconds,
            exportCursorSeconds: exportCursorSeconds,
            durationSeconds: durationSeconds,
            totalFileBytes: totalFileBytes,
            indexTailStart: indexTailStart,
            headOnDisk: headOnDisk,
            tailOnDisk: tailOnDisk,
            filledSpans: filledSpans
        )
        frozenLock.withLock { frozen = next }
    }

    private nonisolated static func endOfServedRun(
        from offset: Int64,
        maxEnd: Int64,
        snap: Frozen
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
