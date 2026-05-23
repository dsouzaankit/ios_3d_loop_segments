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
        var exportStartedAt: Date?
        var impliedMediaBitrateMbps: Double = 0
        var averageWanDownloadMbps: Double = 0
        var lastWanBurstMbps: Double = 0
        var backgroundPrefetchEnabled = false
        var lanPrefetchHorizonToEOF = false
        var backgroundDownloadActive = false
        var backgroundFillPercent = 0
        var denseBytesOnDiskPercent = 0
        var backgroundTimelineSeconds: Double = 0
        var lanPreloadOnly = false
        var pcloudTranscodedWorkingActive = false
        var transcodedWorkingFileBytes: Int64 = 0
        var vanillaDownloadActive = false
        var vanillaLANRelativePath = ""
        var vanillaUsesFastStartForExport = false
        /// Bytes written to `_vanilla_download.*` (sequential from file start).
        var vanillaDownloadedBytes: Int64 = 0
        var vanillaLastProgressBytes: Int64 = 0
        var vanillaLastProgressAt: Date?
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
            snapshot.lanExportActive = true
            snapshot.exportStartedAt = Date()
            snapshot.impliedMediaBitrateMbps = Self.impliedMediaBitrateMbps(
                totalBytes: totalBytes,
                durationSeconds: durationSeconds
            )
            snapshot.averageWanDownloadMbps = 0
            snapshot.lastWanBurstMbps = 0
            snapshot.backgroundDownloadActive = false
            snapshot.lanPreloadOnly = false
        }
    }

    func setLANPreloadOnly(_ enabled: Bool) {
        lock.withLock {
            snapshot.lanPreloadOnly = enabled
        }
    }

    func setPCloudTranscodedWorkingActive(_ active: Bool) {
        lock.withLock {
            snapshot.pcloudTranscodedWorkingActive = active
            if !active {
                snapshot.transcodedWorkingFileBytes = 0
            }
        }
    }

    func usesPCloudTranscodedWorkingForLAN() -> Bool {
        lock.withLock { snapshot.pcloudTranscodedWorkingActive }
    }

    func setVanillaDownloadActive(_ active: Bool) {
        lock.withLock {
            snapshot.vanillaDownloadActive = active
            if !active {
                snapshot.vanillaLANRelativePath = ""
                snapshot.vanillaUsesFastStartForExport = false
                snapshot.vanillaDownloadedBytes = 0
            }
        }
    }

    func updateVanillaDownloadProgress(downloadedBytes: Int64) {
        lock.withLock {
            guard snapshot.vanillaDownloadActive else { return }
            let total = snapshot.totalFileBytes
            let downloaded = max(0, downloadedBytes)
            snapshot.vanillaDownloadedBytes = downloaded
            let duration = snapshot.durationSeconds
            if total > 0 {
                let pct = Int(min(100, downloaded * 100 / max(1, total)))
                snapshot.denseBytesOnDiskPercent = pct
                snapshot.backgroundFillPercent = pct
                snapshot.backgroundDownloadActive = downloaded < total
                if duration > 0 {
                    let linearSec = duration * Double(downloaded) / Double(total)
                    snapshot.backgroundTimelineSeconds = linearSec
                    snapshot.exportCursorSeconds = max(
                        snapshot.playbackStartSeconds,
                        min(duration, linearSec)
                    )
                }
            }
            let now = Date()
            if let lastAt = snapshot.vanillaLastProgressAt,
               downloaded > snapshot.vanillaLastProgressBytes {
                let deltaBytes = downloaded - snapshot.vanillaLastProgressBytes
                let elapsed = now.timeIntervalSince(lastAt)
                if elapsed >= 0.25, deltaBytes > 0 {
                    let burst = Double(deltaBytes) * 8.0 / elapsed / 1_000_000.0
                    snapshot.lastWanBurstMbps = max(snapshot.lastWanBurstMbps, burst)
                }
            }
            snapshot.vanillaLastProgressBytes = downloaded
            snapshot.vanillaLastProgressAt = now
            if let started = snapshot.exportStartedAt, downloaded > 0 {
                let elapsed = now.timeIntervalSince(started)
                if elapsed >= 0.5 {
                    snapshot.averageWanDownloadMbps = Double(downloaded) * 8.0 / elapsed / 1_000_000.0
                }
            }
        }
    }

    func usesVanillaDownloadForLAN() -> Bool {
        lock.withLock { snapshot.vanillaDownloadActive }
    }

    /// Dense vanilla copy finished (WebDAV bytes match expected total).
    func vanillaDownloadIsComplete() -> Bool {
        lock.withLock {
            guard snapshot.vanillaDownloadActive, snapshot.totalFileBytes > 0 else { return false }
            return snapshot.vanillaDownloadedBytes >= snapshot.totalFileBytes
        }
    }

    func clearSparseWorkingPlaybackHints() {
        lock.withLock {
            snapshot.filledSpans = []
            snapshot.headOnDisk = false
            snapshot.tailOnDisk = false
            snapshot.backgroundDownloadActive = false
            snapshot.backgroundFillPercent = 0
            snapshot.denseBytesOnDiskPercent = 0
            snapshot.backgroundPrefetchEnabled = false
            snapshot.backgroundTimelineSeconds = 0
        }
    }

    func beginVanillaExport(
        downloadRelativePath: String,
        fastStartRelativePath: String?,
        seekSeconds: Double,
        durationSeconds: Double,
        totalBytes: Int64,
        initialDownloadedBytes: Int64 = 0
    ) {
        lock.withLock {
            snapshot.vanillaDownloadActive = true
            snapshot.vanillaLANRelativePath = downloadRelativePath
            snapshot.vanillaUsesFastStartForExport = fastStartRelativePath != nil
            snapshot.pcloudTranscodedWorkingActive = false
            snapshot.vanillaDownloadedBytes = max(0, initialDownloadedBytes)
            snapshot.vanillaLastProgressBytes = max(0, initialDownloadedBytes)
            snapshot.vanillaLastProgressAt = nil
            snapshot.averageWanDownloadMbps = 0
            snapshot.lastWanBurstMbps = 0
            snapshot.filledSpans = []
            snapshot.playbackStartSeconds = max(0, seekSeconds)
            snapshot.exportCursorSeconds = snapshot.playbackStartSeconds
            snapshot.durationSeconds = max(0, durationSeconds)
            snapshot.totalFileBytes = totalBytes
            snapshot.lanExportActive = true
            snapshot.exportStartedAt = Date()
            snapshot.backgroundPrefetchEnabled = false
            snapshot.lanPreloadOnly = false
            snapshot.headOnDisk = true
            snapshot.tailOnDisk = true
        }
    }

    func vanillaLANRelativePath() -> String {
        lock.withLock { snapshot.vanillaLANRelativePath }
    }

    func vanillaDownloadUserNotice() -> String? {
        lock.withLock {
            guard snapshot.vanillaDownloadActive else { return nil }
            let path = snapshot.vanillaLANRelativePath
            let fast = snapshot.vanillaUsesFastStartForExport
                ? " Export uses \(ExportPaths.vanillaFastStartURL.lastPathComponent); original download file unchanged."
                : ""
            return """
            Vanilla download — LAN plays \(path) while download runs (growing dense file).\(fast) \
            Segments from local copy when codecs allow.
            """
        }
    }

    func updateTranscodedWorkingFileBytes(_ bytes: Int64) {
        lock.withLock {
            snapshot.transcodedWorkingFileBytes = max(0, bytes)
            snapshot.totalFileBytes = max(snapshot.totalFileBytes, bytes)
        }
    }

    func beginTranscodedExport(seekSeconds: Double, durationSeconds: Double) {
        lock.withLock {
            snapshot.pcloudTranscodedWorkingActive = true
            snapshot.playbackStartSeconds = max(0, seekSeconds)
            snapshot.exportCursorSeconds = snapshot.playbackStartSeconds
            snapshot.durationSeconds = max(0, durationSeconds)
            snapshot.lanExportActive = true
            snapshot.exportStartedAt = Date()
            snapshot.backgroundPrefetchEnabled = false
            snapshot.lanPreloadOnly = false
            snapshot.transcodedWorkingFileBytes = 0
            snapshot.totalFileBytes = 0
            snapshot.headOnDisk = false
            snapshot.tailOnDisk = false
            snapshot.filledSpans = []
        }
    }

    /// User-facing note for Export screen / logs.
    func pcloudTranscodedWorkingUserNotice() -> String? {
        lock.withLock {
            guard snapshot.pcloudTranscodedWorkingActive else { return nil }
            return """
            pCloud transcode — LAN uses pcld_ios_media/_working_pcloud_transcode.mp4 (grows with export). \
            Not the original file; op_00/op_01 also come from the transcode.
            """
        }
    }

    func setBackgroundPrefetchEnabled(_ enabled: Bool) {
        lock.withLock {
            snapshot.backgroundPrefetchEnabled = enabled
        }
    }

    func setLANPrefetchHorizonToEOF(_ toEOF: Bool) {
        lock.withLock {
            snapshot.lanPrefetchHorizonToEOF = toEOF
        }
    }

    func updateWanDownloadStats(
        averageActiveMbps: Double?,
        lastBurstMbps: Double?,
        backgroundActive: Bool,
        backgroundFillPercent: Int,
        denseBytesOnDiskPercent: Int,
        backgroundTimelineSeconds: Double
    ) {
        lock.withLock {
            snapshot.backgroundDownloadActive = backgroundActive
            snapshot.backgroundFillPercent = backgroundFillPercent
            snapshot.denseBytesOnDiskPercent = denseBytesOnDiskPercent
            snapshot.backgroundTimelineSeconds = backgroundTimelineSeconds
            if let averageActiveMbps, averageActiveMbps > 0 {
                snapshot.averageWanDownloadMbps = averageActiveMbps
            }
            if let lastBurstMbps, lastBurstMbps > 0 {
                snapshot.lastWanBurstMbps = max(snapshot.lastWanBurstMbps, lastBurstMbps)
            }
        }
    }

    static func impliedMediaBitrateMbps(totalBytes: Int64, durationSeconds: Double) -> Double {
        guard totalBytes > 0, durationSeconds > 0 else { return 0 }
        let effective = WebDAVTempFileDownload.effectiveDurationSeconds(
            reported: durationSeconds,
            totalBytes: totalBytes
        )
        guard effective > 0 else { return 0 }
        return (Double(totalBytes) * 8.0) / (effective * 1_000_000.0)
    }

    /// Human-readable lines for the LAN HTTP index (export timing + bitrates).
    func lanDashboardLines() -> [String] {
        let snap = lock.withLock { snapshot }
        var lines: [String] = []
        if snap.vanillaDownloadActive, snap.totalFileBytes > 0 {
            let downloaded = max(0, snap.vanillaDownloadedBytes)
            let total = snap.totalFileBytes
            let pct = Int(min(100, downloaded * 100 / max(1, total)))
            if total > 0 {
                lines.append(
                    String(
                        format: "Vanilla download: %d%% (%.1f / %.1f MB)",
                        pct,
                        Self.fileSizeMB(downloaded),
                        Self.fileSizeMB(total)
                    )
                )
            }
            if snap.durationSeconds > 0, snap.backgroundTimelineSeconds > 0 {
                lines.append(
                    "Downloaded timeline: ~\(Self.formatClock(snap.backgroundTimelineSeconds)) of \(Self.formatClock(snap.durationSeconds))"
                )
            }
            if snap.backgroundDownloadActive {
                lines.append("Vanilla WebDAV download — active now")
            } else if downloaded >= total, total > 0 {
                lines.append("Vanilla WebDAV download — complete")
            }
        }
        if snap.totalFileBytes > 0 {
            lines.append(String(format: "Media file size: %.1f MB", Self.fileSizeMB(snap.totalFileBytes)))
        }
        if snap.durationSeconds > 0 {
            lines.append("Media duration: \(Self.formatClock(snap.durationSeconds))")
        }
        if snap.impliedMediaBitrateMbps > 0 {
            lines.append(String(format: "Media bitrate (est.): %.1f Mbps", snap.impliedMediaBitrateMbps))
        }
        if let started = snap.exportStartedAt, snap.lanExportActive {
            let elapsed = max(0, Date().timeIntervalSince(started))
            lines.append("Export elapsed: \(Self.formatClock(elapsed))")
        }
        if snap.lastWanBurstMbps > 0 {
            lines.append(String(format: "Peak WAN burst (session): %.1f Mbps", snap.lastWanBurstMbps))
        }
        if snap.averageWanDownloadMbps > 0 {
            lines.append(String(format: "Avg WAN (active bursts): %.1f Mbps", snap.averageWanDownloadMbps))
        }
        let live = Self.liveFillStats(snap: snap)
        if snap.lanExportActive, snap.backgroundPrefetchEnabled {
            lines.append(
                "LAN browser cap = furthest contiguous dense from playback start (sequential prefetch)"
            )
            lines.append(
                String(
                    format: "Sequential prefetch from start: %d%% (~%@ reachable)",
                    live.backgroundFillPercent,
                    Self.formatClock(live.backgroundTimelineSeconds)
                )
            )
        }
        if live.denseBytesOnDiskPercent > 0 {
            lines.append("Dense bytes on disk: \(live.denseBytesOnDiskPercent)% of file")
        }
        if snap.lanExportActive, snap.backgroundPrefetchEnabled {
            let cutoff = Int(ExportLANServer.backgroundPrefetchCutoffMbps.rounded())
            let horizon = snap.lanPrefetchHorizonToEOF
                ? "toward EOF (below \(cutoff) Mbps est.; no op_*.mp4)"
                : "tracks export cursor (≥\(cutoff) Mbps est.; op_*.mp4 + LAN)"
            var prefetch = "on — \(horizon)"
            if snap.lanPreloadOnly {
                prefetch += " — LAN preload only (no op_*.mp4)"
            }
            prefetch += snap.backgroundDownloadActive ? " — active now" : " — paused (minute dense fill)"
            lines.append("LAN sequential prefetch: \(prefetch)")
        }
        return lines
    }

    private struct LiveFillStats {
        let backgroundFillPercent: Int
        let backgroundTimelineSeconds: Double
        let denseBytesOnDiskPercent: Int
    }

    /// Dashboard metrics derived live from `snap.filledSpans` (refreshed from disk on each HTTP request).
    private static func liveFillStats(snap: Snapshot) -> LiveFillStats {
        guard snap.totalFileBytes > 0 else {
            return LiveFillStats(backgroundFillPercent: 0, backgroundTimelineSeconds: 0, denseBytesOnDiskPercent: 0)
        }
        if snap.vanillaDownloadActive {
            let total = snap.totalFileBytes
            let downloaded = max(0, snap.vanillaDownloadedBytes)
            let duration = snap.durationSeconds
            let pct = Int(min(100, downloaded * 100 / max(1, total)))
            let timeline = duration > 0 ? duration * Double(downloaded) / Double(total) : 0
            return LiveFillStats(
                backgroundFillPercent: pct,
                backgroundTimelineSeconds: timeline,
                denseBytesOnDiskPercent: pct
            )
        }
        let total = snap.totalFileBytes
        let duration = snap.durationSeconds
        let anchor: Int64 = {
            guard snap.playbackStartSeconds > 0.5, duration > 0 else { return 0 }
            return WebDAVTempFileDownload.lanPlaybackDenseAnchorByte(
                playbackStartSeconds: snap.playbackStartSeconds,
                totalLength: total,
                durationSeconds: duration
            )
        }()
        let frontier = contiguousDenseEndFromByte(anchor, spans: snap.filledSpans)
        let horizonByte = total
        let filled = max(0, frontier - anchor)
        let range = max(1, horizonByte - anchor)
        let bgPercent = Int(min(100, filled * 100 / range))
        let bgTimeline: Double = duration > 0
            ? WebDAVTempFileDownload.timelineSecondsForByteOffset(frontier, totalLength: total, durationSeconds: duration)
            : 0
        var dense: Int64 = 0
        for span in snap.filledSpans { dense += span.upperBound - span.lowerBound + 1 }
        let densePercent = Int(min(100, dense * 100 / max(1, total)))
        return LiveFillStats(
            backgroundFillPercent: bgPercent,
            backgroundTimelineSeconds: bgTimeline,
            denseBytesOnDiskPercent: densePercent
        )
    }

    private static func contiguousDenseEndFromByte(_ startByte: Int64, spans: [ClosedRange<Int64>]) -> Int64 {
        var frontier = startByte
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if span.upperBound < frontier { continue }
            if span.lowerBound > frontier { break }
            frontier = max(frontier, span.upperBound + 1)
        }
        return frontier
    }

    private static func fileSizeMB(_ bytes: Int64) -> Double {
        Double(bytes) / 1_048_576.0
    }

    private static func formatClock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    func setLANExportActive(_ active: Bool) {
        lock.withLock {
            snapshot.lanExportActive = active
        }
    }

    var isLANExportActive: Bool {
        lock.withLock { snapshot.lanExportActive }
    }

    var lanPrefetchHorizonToEOF: Bool {
        lock.withLock { snapshot.lanPrefetchHorizonToEOF }
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

    /// Updates dense spans / head / tail from disk without changing playback start or export cursor.
    func updateDiskLayout(
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
            if let playbackStartSeconds {
                snapshot.playbackStartSeconds = max(0, playbackStartSeconds)
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

    var exportDurationSeconds: Double {
        lock.withLock { snapshot.durationSeconds }
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
        let live = Self.liveFillStats(snap: snap)
        var payload: [String: Any] = [
            "playbackStartSeconds": snap.playbackStartSeconds,
            "exportCursorSeconds": snap.exportCursorSeconds,
            "durationSeconds": snap.durationSeconds,
            "totalBytes": snap.totalFileBytes,
            "mediaFileSizeMB": Self.fileSizeMB(snap.totalFileBytes),
            "indexTailStart": snap.indexTailStart,
            "headOnDisk": snap.headOnDisk,
            "tailOnDisk": snap.tailOnDisk,
            "lanPlayableTillSeconds": till,
            "lanPlayableStatusLine": Self.lanPlayableStatusLine(snap: snap),
            "impliedMediaBitrateMbps": snap.impliedMediaBitrateMbps,
            "averageWanDownloadMbps": snap.averageWanDownloadMbps,
            "lastWanBurstMbps": snap.lastWanBurstMbps,
            "backgroundPrefetchEnabled": snap.backgroundPrefetchEnabled,
            "backgroundDownloadActive": snap.backgroundDownloadActive,
            "backgroundFillPercent": live.backgroundFillPercent,
            "denseBytesOnDiskPercent": live.denseBytesOnDiskPercent,
            "backgroundTimelineSeconds": live.backgroundTimelineSeconds,
            "vanillaDownloadActive": snap.vanillaDownloadActive,
            "vanillaDownloadedBytes": snap.vanillaDownloadedBytes,
            "vanillaDownloadPercent": snap.totalFileBytes > 0
                ? Int(min(100, snap.vanillaDownloadedBytes * 100 / max(1, snap.totalFileBytes)))
                : 0,
        ]
        if let started = snap.exportStartedAt {
            payload["exportStartedAt"] = ISO8601DateFormatter().string(from: started)
            payload["exportElapsedSeconds"] = max(0, Date().timeIntervalSince(started))
        }
        return payload
    }

    private static func maxBrowserPlayableTimelineSeconds(
        snap: Snapshot,
        playbackStartSeconds: Double? = nil,
        durationSeconds: Double? = nil
    ) -> Double {
        let duration = durationSeconds ?? snap.durationSeconds
        if snap.vanillaDownloadActive, snap.totalFileBytes > 0 {
            let downloaded = max(0, snap.vanillaDownloadedBytes)
            if duration > 0 {
                return min(duration, duration * Double(downloaded) / Double(snap.totalFileBytes))
            }
            return 0
        }
        let start = max(0, playbackStartSeconds ?? snap.playbackStartSeconds)
        guard duration > 0, snap.totalFileBytes > 0 else { return start }
        let startByte = WebDAVTempFileDownload.lanPlaybackDenseAnchorByte(
            playbackStartSeconds: start,
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
        let tillNote = snap.vanillaDownloadActive
            ? "sequential download from file start (use index #t= for export seek)"
            : "contiguous dense from playback start"
        let exportLabel: String
        if export + 1 < from {
            exportLabel =
                "\(ExportTimelineLog.wallClock(seconds: export)) (before start — stale manifest or resume?)"
        } else {
            exportLabel = ExportTimelineLog.wallClock(seconds: export)
        }
        let progressLabel = snap.lanPreloadOnly ? "filled" : "exported"
        return
            "LAN playable till \(ExportTimelineLog.wallClock(seconds: till)) (\(tillNote)), " +
            "\(progressLabel) \(exportLabel), " +
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
