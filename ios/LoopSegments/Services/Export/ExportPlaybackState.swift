import Foundation

/// LAN playback hints for `_working.mp4` (sparse; moov reports full duration).
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
        var lanExportActive = false
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
            snapshot.lanExportActive = true
        }
    }

    func setLANExportActive(_ active: Bool) {
        lock.withLock {
            snapshot.lanExportActive = active
        }
    }

    var isLANExportActive: Bool {
        lock.withLock { snapshot.lanExportActive }
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
        tailOnDisk: Bool,
        playbackStartSeconds: Double? = nil
    ) {
        restoreLANPlayback(
            totalBytes: totalBytes,
            filledSpans: filledSpans,
            headOnDisk: headOnDisk,
            tailOnDisk: tailOnDisk,
            playbackStartSeconds: playbackStartSeconds,
            durationSeconds: nil,
            exportCursorSeconds: nil
        )
    }

    /// Reload LAN gating from disk manifest (export may be idle).
    func restoreLANPlayback(
        totalBytes: Int64,
        filledSpans: [ClosedRange<Int64>],
        headOnDisk: Bool,
        tailOnDisk: Bool,
        playbackStartSeconds: Double?,
        durationSeconds: Double?,
        exportCursorSeconds: Double?
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
            if let playbackStartSeconds, playbackStartSeconds > 0 {
                snapshot.playbackStartSeconds = playbackStartSeconds
            }
            if let durationSeconds, durationSeconds > 0 {
                snapshot.durationSeconds = durationSeconds
            }
            if let exportCursorSeconds {
                snapshot.exportCursorSeconds = max(0, exportCursorSeconds)
            }
        }
    }

    /// First contiguous readable span from `start` (one HTTP Range response must not chain sparse gaps).
    func maxContiguousReadableEnd(from start: Int64, maxEnd: Int64) -> Int64? {
        let snap = lock.withLock { snapshot }
        guard snap.totalFileBytes > 0, start >= 0, start <= maxEnd else { return nil }
        return Self.endOfServedRun(from: start, maxEnd: maxEnd, snap: snap)
    }

    /// Whether timeline `seconds` lies inside a dense byte window on disk.
    func timelineSecondsIsReadable(_ seconds: Double) -> Bool {
        let snap = lock.withLock { snapshot }
        guard snap.durationSeconds > 0, snap.totalFileBytes > 0 else { return false }
        let range = WebDAVTempFileDownload.byteRangeForTimeline(
            totalLength: snap.totalFileBytes,
            timelineStartSeconds: seconds,
            timelineEndSeconds: min(seconds + 1, snap.durationSeconds),
            durationSeconds: snap.durationSeconds
        )
        let end = max(range.start, range.end - 1)
        guard end >= range.start, end < snap.totalFileBytes else { return false }
        var cursor = range.start
        while cursor <= end {
            guard let servedEnd = Self.endOfServedRun(from: cursor, maxEnd: end, snap: snap) else {
                return false
            }
            cursor = servedEnd + 1
        }
        return true
    }

    var playbackStartSeconds: Double {
        lock.withLock { snapshot.playbackStartSeconds }
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

    var exportCursorSeconds: Double {
        lock.withLock { snapshot.exportCursorSeconds }
    }

    var frozenPlaybackStartSecondsInt: Int {
        lock.withLock { Int(snapshot.playbackStartSeconds.rounded(.down)) }
    }

    var indexTailStartByte: Int64 {
        lock.withLock { snapshot.indexTailStart }
    }

    var tailOnDiskForLAN: Bool {
        lock.withLock { snapshot.tailOnDisk }
    }

    func maxBrowserPlayableTimelineSeconds(
        playbackStartSeconds: Double? = nil,
        durationSeconds: Double? = nil
    ) -> Double {
        let snap = lock.withLock { snapshot }
        return Self.maxBrowserPlayableTimelineSeconds(
            snap: snap,
            playbackStartSeconds: playbackStartSeconds,
            durationSeconds: durationSeconds
        )
    }

    func lanPlayableStatusLine(
        playbackStartSeconds: Double? = nil,
        exportCursorSeconds: Double? = nil,
        durationSeconds: Double? = nil
    ) -> String {
        let snap = lock.withLock { snapshot }
        return Self.lanPlayableStatusLine(
            snap: snap,
            playbackStartSeconds: playbackStartSeconds,
            exportCursorSeconds: exportCursorSeconds,
            durationSeconds: durationSeconds
        )
    }

    var frozenStatusPayload: [String: Any] {
        let snap = lock.withLock { snapshot }
        let till = Self.maxBrowserPlayableTimelineSeconds(snap: snap)
        return [
            "playbackStartSeconds": snap.playbackStartSeconds,
            "exportCursorSeconds": snap.exportCursorSeconds,
            "durationSeconds": snap.durationSeconds,
            "totalBytes": snap.totalFileBytes,
            "indexTailStart": snap.indexTailStart,
            "headOnDisk": snap.headOnDisk,
            "tailOnDisk": snap.tailOnDisk,
            "lanPlayableTillSeconds": till,
            "lanPlayableStatusLine": Self.lanPlayableStatusLine(snap: snap),
        ]
    }

    private static func maxBrowserPlayableTimelineSeconds(
        snap: Snapshot,
        playbackStartSeconds: Double? = nil,
        durationSeconds: Double? = nil
    ) -> Double {
        let start = max(0, playbackStartSeconds ?? snap.playbackStartSeconds)
        let duration = durationSeconds ?? snap.durationSeconds
        guard duration > 0, snap.totalFileBytes > 0 else { return start }
        let startByte = WebDAVTempFileDownload.timelineByteOffsetForSeconds(
            start,
            totalLength: snap.totalFileBytes,
            durationSeconds: duration
        )
        let maxEnd = snap.totalFileBytes - 1
        if let servedEnd = endOfServedRun(from: startByte, maxEnd: maxEnd, snap: snap) {
            return WebDAVTempFileDownload.timelineSecondsForByteOffset(
                servedEnd + 1,
                totalLength: snap.totalFileBytes,
                durationSeconds: duration
            )
        }
        return start
    }

    private static func lanPlayableStatusLine(
        snap: Snapshot,
        playbackStartSeconds: Double? = nil,
        exportCursorSeconds: Double? = nil,
        durationSeconds: Double? = nil
    ) -> String {
        let from = max(0, playbackStartSeconds ?? snap.playbackStartSeconds)
        let export = max(0, exportCursorSeconds ?? snap.exportCursorSeconds)
        let duration = durationSeconds ?? snap.durationSeconds
        let till = maxBrowserPlayableTimelineSeconds(
            snap: snap,
            playbackStartSeconds: from,
            durationSeconds: duration
        )
        return
            "LAN playable till \(ExportTimelineLog.wallClock(seconds: till)), " +
            "exported \(ExportTimelineLog.wallClock(seconds: export)), " +
            "started \(ExportTimelineLog.wallClock(seconds: from))"
    }

    /// Furthest byte reachable from `offset` without crossing a sparse gap (chains head → dense spans → tail).
    private static func endOfServedRun(
        from offset: Int64,
        maxEnd: Int64,
        snap: Snapshot
    ) -> Int64? {
        guard offset <= maxEnd else { return nil }
        guard var runEnd = endOfReadableRunCovering(offset: offset, maxEnd: maxEnd, snap: snap) else {
            return nil
        }
        while runEnd < maxEnd {
            let nextStart = runEnd + 1
            guard let nextEnd = endOfReadableRunCovering(offset: nextStart, maxEnd: maxEnd, snap: snap) else {
                break
            }
            runEnd = nextEnd
        }
        return runEnd
    }

    private static func endOfReadableRunCovering(
        offset: Int64,
        maxEnd: Int64,
        snap: Snapshot
    ) -> Int64? {
        var runEnd: Int64?
        if snap.headOnDisk {
            let headEnd = min(maxEnd, min(Int64(512 * 1024) - 1, snap.totalFileBytes - 1))
            if offset <= headEnd {
                runEnd = headEnd
            }
        }
        for span in snap.filledSpans {
            if offset >= span.lowerBound, offset <= span.upperBound {
                runEnd = max(runEnd ?? span.lowerBound - 1, min(maxEnd, span.upperBound))
            }
        }
        if snap.tailOnDisk, offset >= snap.indexTailStart {
            runEnd = max(runEnd ?? snap.indexTailStart - 1, maxEnd)
        }
        return runEnd
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
