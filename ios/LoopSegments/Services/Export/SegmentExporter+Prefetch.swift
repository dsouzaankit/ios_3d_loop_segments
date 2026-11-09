import AVFoundation
import CoreMedia
import Foundation

/// LAN working-file prefetch and passthrough asset selection.
extension SegmentExporter {
    /// LAN: head+index + sequential prefetch; horizon EOF when below Mbps cutoff, else minimal lead on segment export.
    struct LANWorkingPrefetchPolicy {
        let prepareHeadAndIndex: Bool
        let prefetchHorizonToEOF: Bool
        let waitForBackgroundAtEnd: Bool
        let lanPreloadOnly: Bool
    }

    static func impliedAverageMbps(fileBytes: Int64, durationSeconds: Double) -> Double {
        guard fileBytes > 0, durationSeconds > 0 else { return 0 }
        let effective = WebDAVTempFileDownload.effectiveDurationSeconds(
            reported: durationSeconds,
            totalBytes: fileBytes
        )
        guard effective > 0 else { return 0 }
        return (Double(fileBytes) * 8.0) / (effective * 1_000_000.0)
    }

    static func lanWorkingPrefetchPolicy(
        seekSeconds: Double,
        impliedMbps: Double
    ) -> LANWorkingPrefetchPolicy {
        guard ExportLANServer.isEnabled else {
            return LANWorkingPrefetchPolicy(
                prepareHeadAndIndex: false,
                prefetchHorizonToEOF: false,
                waitForBackgroundAtEnd: false,
                lanPreloadOnly: false
            )
        }
        let lanPreloadOnly = !ExportDeliveryPolicy.shouldRun60sSegments(impliedMbps: impliedMbps)
        return LANWorkingPrefetchPolicy(
            prepareHeadAndIndex: true,
            prefetchHorizonToEOF: lanPreloadOnly,
            waitForBackgroundAtEnd: seekSeconds <= 0.5 && lanPreloadOnly,
            lanPreloadOnly: lanPreloadOnly
        )
    }

    static func lanPrefetchHorizonSeconds(
        playbackStartSeconds: Double,
        exportCursorSeconds: Double,
        durationSeconds: Double,
        prefetchHorizonToEOF: Bool
    ) -> Double {
        if prefetchHorizonToEOF {
            return durationSeconds
        }
        return min(
            durationSeconds,
            exportCursorSeconds + ExportDeliveryPolicy.lanSegmentPrefetchLeadSeconds
        )
    }

    /// Head + index; sequential dense prefetch from playback start (horizon grows each minute).
    func preloadWorkingSourceForLANPlayback(
        downloader: WebDAVTempFileDownload,
        fileSize: Int64,
        seekSeconds: Double,
        durationSeconds: Double,
        lanPrefetch: LANWorkingPrefetchPolicy,
        impliedMbps: Double,
        log: @escaping (String) -> Void
    ) async throws {
        downloader.setPlaybackAnchor(seekSeconds: seekSeconds, durationSeconds: durationSeconds)
        let full = TimelineByteRange(start: 0, end: fileSize)
        try await downloader.ensureFileHeadOnDisk()
        try await downloader.ensureIndexTailOnDisk()
        if seekSeconds <= 0.5, downloader.isByteRangeFullyOnDisk(full) {
            downloader.recordFullDenseFileForLANIfNeeded()
            log("LAN _working.mp4 — full file already on disk (seek anywhere)")
            return
        }
        let horizonSeconds = Self.lanPrefetchHorizonSeconds(
            playbackStartSeconds: seekSeconds,
            exportCursorSeconds: seekSeconds,
            durationSeconds: durationSeconds,
            prefetchHorizonToEOF: lanPrefetch.prefetchHorizonToEOF
        )
        downloader.updateLANSequentialPrefetchHorizon(
            playbackStartSeconds: seekSeconds,
            horizonTimelineSeconds: horizonSeconds,
            durationSeconds: durationSeconds
        )
        let horizonLabel = lanPrefetch.prefetchHorizonToEOF
            ? "EOF (\(Self.formatBytes(fileSize)))"
            : "export cursor (high bitrate ~\(String(format: "%.1f", impliedMbps)) Mbps; dense fill per minute)"
        log(
            "LAN preload — sequential dense fill from \(ExportTimelineLog.wallClock(seconds: seekSeconds)) toward \(horizonLabel); " +
                "LAN :8765 serves contiguous bytes only"
        )
        if seekSeconds > 0.5 {
            if lanPrefetch.prefetchHorizonToEOF {
                log(
                    "LAN prefix — dense fill 0:00 → \(ExportTimelineLog.wallClock(seconds: seekSeconds)) from pCloud first (below cutoff)…"
                )
                try await downloader.ensureLANPrefixBeforeSeekFilled(
                    seekSeconds: seekSeconds,
                    durationSeconds: durationSeconds
                )
            }
            let firstWindowEnd = min(
                durationSeconds,
                seekSeconds + Self.segmentDurationSeconds
            )
            let firstRange = downloader.byteRangeForTimeline(
                timelineStartSeconds: seekSeconds,
                timelineEndSeconds: firstWindowEnd,
                durationSeconds: durationSeconds
            )
            try await downloader.ensureContiguousRange(
                firstRange,
                bridgeLANGapBeforeWindow: lanPrefetch.prefetchHorizonToEOF
            )
            try await downloader.ensureLANPlaybackPrerollGapFilled(
                seekSeconds: seekSeconds,
                durationSeconds: durationSeconds
            )
        }
        downloader.publishLANPlaybackState(mediaCursorSeconds: seekSeconds)
        log(
            downloader.maxBrowserPlayableStatusLog(
                playbackStartSeconds: seekSeconds,
                durationSeconds: durationSeconds,
                exportCursorSeconds: seekSeconds
            )
        )
    }

    func ensureSeekZeroRemainderOnDiskIfBeneficial(
        downloader: WebDAVTempFileDownload,
        byteRange: TimelineByteRange,
        log: @escaping (String) -> Void
    ) async throws {
        guard byteRange.start == 0 else { return }
        let fileLength = downloader.totalLength
        guard fileLength > byteRange.end else { return }
        let tail = TimelineByteRange(start: byteRange.end, end: fileLength)
        guard !downloader.isByteRangeFullyOnDisk(tail) else { return }
        let tailBytes = fileLength - byteRange.end
        if ExportLANServer.isEnabled {
            log(
                "Seek 0 — skip remainder dense fill (\(Self.formatBytes(tailBytes)); LAN background prefetch + per-minute windows)"
            )
            return
        }
        let shouldFill =
            tailBytes <= Self.seekZeroDenseTailMaxBytes
            || fileLength <= Self.seekZeroDenseEntireFileMaxBytes
        guard shouldFill else {
            log(
                "Seek 0 — leaving \(Self.formatBytes(tailBytes)) sparse after window (file too large for full tail fill; hybrid/export session)"
            )
            return
        }
        log(
            "Seek 0 — dense-filling \(Self.formatBytes(tailBytes)) after window (\(Self.formatBytes(fileLength)) file on disk for passthrough)"
        )
        try await downloader.ensureContiguousRange(tail)
    }

    /// `file://` when the minute window is dense on `_working.mp4` (seek 0 or mid-file after dense fill).
    func shouldUseOnDiskFileURLForPassthrough(
        downloader: WebDAVTempFileDownload,
        byteRange: TimelineByteRange,
        windowDense: Bool
    ) -> Bool {
        guard windowDense, byteRange.length > 0 else { return false }
        if isFullSourceOnDisk(downloader: downloader) {
            return true
        }
        return downloader.isByteRangeFullyOnDisk(byteRange)
    }

    func prepareMidFileTempForReader(
        downloader: WebDAVTempFileDownload,
        byteRange: TimelineByteRange,
        bridgeLANGapBeforeWindow: Bool = false,
        log: @escaping (String) -> Void
    ) async throws {
        log("Mid-file temp: ensuring file header + MP4 index + dense window before reader…")
        try await downloader.ensureFileHeadOnDisk()
        try await downloader.ensureIndexTailOnDisk()
        try await downloader.ensureContiguousRange(
            byteRange,
            bridgeLANGapBeforeWindow: bridgeLANGapBeforeWindow
        )
    }

    func makeHTTPSPassthroughAsset(
        remoteURL: URL,
        authorizationProvider: @escaping WebDAVAuthorizationProvider
    ) -> AVURLAsset {
        let headers = ["Authorization": authorizationProvider()]
        return AVURLAsset(
            url: remoteURL,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": headers,
                AVURLAssetPreferPreciseDurationAndTimingKey: false,
            ]
        )
    }

    /// Start-of-file dense window: `file://` temp. Mid-file: hybrid (capped) or HTTPS range reads if custom URL is rejected.
    func resolvePassthroughReadAsset(
        downloader: WebDAVTempFileDownload,
        tempURL: URL,
        remoteURL: URL,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        rangeCache: WebDAVRangeCache,
        trustedLength: Int64,
        byteRange: TimelineByteRange,
        useOnDiskFileURL: Bool,
        forceHTTPSRangeReads: Bool,
        log: @escaping (String) -> Void
    ) async throws -> (AVURLAsset, WebDAVResourceLoader?) {
        if useOnDiskFileURL {
            log("Passthrough reader: on-disk temp file")
            let asset = AVURLAsset(
                url: tempURL,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
            )
            return (asset, nil)
        }
        if forceHTTPSRangeReads {
            log(
                "Passthrough reader: HTTPS byte-range from pCloud (reader timeRange limits the segment; dense temp not used for reads)"
            )
            return (makeHTTPSPassthroughAsset(remoteURL: remoteURL, authorizationProvider: authorizationProvider), nil)
        }

        let fileLength = trustedLength > 0 ? trustedLength : downloader.totalLength
        let readPolicy = StreamReadPolicy.forExportWindow(
            fileLength: fileLength,
            window: byteRange,
            indexTailBytes: WebDAVTempFileDownload.indexTailFetchBytes(totalLength: fileLength)
        )
        log(
            "Passthrough reader: hybrid with capped reads — head, window \(Self.formatBytes(byteRange.start))–\(Self.formatBytes(byteRange.end)), MP4 index at EOF (no full-file pull)"
        )
        let loader = WebDAVResourceLoader(
            remoteURL: remoteURL,
            authorizationProvider: authorizationProvider,
            rangeCache: rangeCache,
            trustedContentLength: fileLength > 0 ? fileLength : nil,
            readPolicy: readPolicy,
            localTempURL: tempURL,
            readLocalBytes: { offset, length in
                downloader.readLocalBytes(offset: offset, length: length)
            },
            log: log
        )
        let asset = AVURLAsset(
            url: loader.customAssetURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        do {
            _ = try await asset.loadTracks(withMediaType: .video)
            return (asset, loader)
        } catch {
            asset.resourceLoader.setDelegate(nil, queue: nil)
            loader.cancelOutstandingWork()
            guard Self.isUnsupportedAssetURLError(error) else { throw error }
            log(
                "Custom asset URL rejected (\(error.localizedDescription)) — using HTTPS byte-range reads from pCloud"
            )
            return (makeHTTPSPassthroughAsset(remoteURL: remoteURL, authorizationProvider: authorizationProvider), nil)
        }
    }
}
