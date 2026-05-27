import AVFoundation
import CoreMedia
import Foundation

struct SegmentExportResult {
    let lastMediaTimeMs: Int64
    let reachedEnd: Bool
    /// Minutes that failed after retries; export continued and dense-filled later windows when possible.
    let skippedSegmentCount: Int
    /// Below LAN bitrate cutoff: filled `_working.mp4` only (no `op_*.mp4` segments).
    let lanPreloadOnly: Bool
}

/// Stream-copy export to one rotating 60s MP4 on the phone (AVFoundation, WebDAV input).
final class SegmentExporter {
    static let segmentDurationSeconds = ExportDeliveryPolicy.targetSegmentDurationSeconds
    static var segmentFileCount: Int { ExportPaths.segmentFileCount }

    private let cancelLock = NSLock()
    private var isCancelled = false
    private var retainedWebDAVLoader: WebDAVResourceLoader?
    private var retainedAsset: AVURLAsset?
    private var tempDownload: WebDAVTempFileDownload?

    func cancel() {
        cancelLock.lock()
        isCancelled = true
        cancelLock.unlock()
    }

    private func checkCancelled() throws {
        cancelLock.lock()
        let cancelled = isCancelled
        cancelLock.unlock()
        if cancelled { throw SegmentExporterError.cancelled }
    }

    private func mapReaderFailure(_ error: Error?) -> SegmentExporterError? {
        guard let error else { return nil }
        if isCancelled { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSUserCancelledError {
            return .readerInterrupted
        }
        if error is CancellationError {
            return .readerInterrupted
        }
        let text = error.localizedDescription.lowercased()
        if text.contains("cancel") || text.contains("interrupted") {
            return .readerInterrupted
        }
        return .readerFailed(error)
    }

    func run(
        item: WebDAVItem,
        inputURL: URL,
        credentials: WebDAVCredentials,
        catalogContentLength: Int64? = nil,
        seekMs: Int64,
        continueLANExport: Bool = false,
        resumeCursorMs: Int64? = nil,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        logHandler: @escaping (String) -> Void,
        onMediaProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> SegmentExportResult {
        cancelLock.lock()
        isCancelled = false
        cancelLock.unlock()
        ExportPlaybackState.shared.setLANExportActive(true)
        defer {
            tempDownload?.flushLANPlaybackManifestForExportEnd()
            ExportPlaybackState.shared.setLANExportActive(false)
            ExportPlaybackState.shared.setLANPreloadOnly(false)
            tempDownload?.cancel()
            tempDownload = nil
            retainedWebDAVLoader = nil
            retainedAsset = nil
            ExportPlaybackState.shared.setPCloudTranscodedWorkingActive(false)
            if !ExportPaths.vanillaDownloadCopyExistsOnDisk() {
                ExportPlaybackState.shared.setVanillaDownloadActive(false)
            }
            WorkingSourceSparseCatalog.refreshPlaybackState(for: ExportPaths.workingSourceURL)
        }

        let rangeCache = WebDAVRangeCache()
        let containerFormat = MediaContainerFormat.from(filename: item.name)
        let vanillaOnlyContainer = containerFormat.usesVanillaOnlyOnDevice
        logHandler(
            vanillaOnlyContainer
                ? "Prefetching from pCloud (file size only — \(containerFormat.displayName) is vanilla-only on device)…"
                : containerFormat.needsMP4IndexAtEOF
                    ? "Prefetching from pCloud (size + MP4 index)…"
                    : "Prefetching from pCloud (size + \(containerFormat.displayName) header)…"
        )
        try await WebDAVPrefetch.warmUp(
            remoteURL: inputURL,
            authorization: authorizationProvider(),
            cache: rangeCache,
            container: containerFormat,
            catalogContentLength: catalogContentLength,
            headOnly: vanillaOnlyContainer,
            log: logHandler
        )

        let cancelCheck: () -> Bool = { [weak self] in
            guard let self else { return true }
            self.cancelLock.lock()
            let cancelled = self.isCancelled
            self.cancelLock.unlock()
            return cancelled
        }

        let fileSize = rangeCache.contentLengthValue() ?? 0
        ExportPaths.syncVanillaDownloadWithExportItem(
            item: item,
            totalLength: fileSize > 0 ? fileSize : (item.contentLength ?? 0),
            continueLANExport: continueLANExport,
            log: logHandler
        )

        if vanillaOnlyContainer {
            logHandler(
                "\(containerFormat.displayName) — 60s segment export not supported on device; " +
                    "vanilla WebDAV download (skipping sparse probe and remote duration wait)"
            )
            return try await attemptRecoveryExport(
                probeError: SegmentExporterError.containerProbeFailed(containerFormat),
                item: item,
                inputURL: inputURL,
                credentials: credentials,
                containerFormat: containerFormat,
                fileBytes: fileSize,
                seekMs: seekMs,
                continueLANExport: continueLANExport,
                resumeCursorMs: resumeCursorMs,
                authorizationProvider: authorizationProvider,
                rangeCache: rangeCache,
                isCancelled: cancelCheck,
                logHandler: logHandler,
                onMediaProgress: onMediaProgress
            )
        }

        logHandler(
            "Dense fill — each minute downloads to temp before passthrough (mid-file uses capped hybrid reader; seek 0 uses on-disk file when dense)."
        )
        try Self.ensureExportDiskSpace(fileBytes: fileSize)

        if fileSize > Self.streamOnlyThresholdBytes {
            logHandler(
                "Large file (\(Self.formatBytes(fileSize))) — sparse temp copy (only bytes needed per minute, not full \(Self.formatBytes(fileSize)))"
            )
        }

        let durationSeconds: Double
        let videoFormat: CMFormatDescription
        let audioFormat: CMFormatDescription?
        let reuseSparseWorking = Self.canReuseSparseWorkingForResume(
            item: item,
            fileSize: fileSize,
            continueLANExport: continueLANExport
        )
        let downloader: WebDAVTempFileDownload

        if reuseSparseWorking {
            logHandler("Resuming sparse _working.mp4 from paused export…")
            downloader = try WebDAVTempFileDownload(
                fileKey: item.fileKey,
                sourceHref: item.href,
                remoteURL: inputURL,
                rangeCache: rangeCache,
                containerFormat: containerFormat,
                authorizationProvider: authorizationProvider,
                isCancelled: cancelCheck,
                log: logHandler
            )
            tempDownload = downloader
            downloader.logDownloadStarted()
            try await downloader.ensureIndexTailOnDisk()
            do {
                (durationSeconds, videoFormat, audioFormat) = try await probeExportMetadata(
                    containerFormat: containerFormat,
                    fileURL: downloader.fileURL,
                    inputURL: inputURL,
                    authorizationProvider: authorizationProvider,
                    rangeCache: rangeCache,
                    log: logHandler
                )
            } catch {
                abandonSparseWorkingForRecovery(logHandler: logHandler)
                return try await attemptRecoveryExport(
                    probeError: error,
                    item: item,
                    inputURL: inputURL,
                    credentials: credentials,
                    containerFormat: containerFormat,
                    fileBytes: fileSize,
                    seekMs: seekMs,
                    continueLANExport: continueLANExport,
                    resumeCursorMs: resumeCursorMs,
                    authorizationProvider: authorizationProvider,
                    rangeCache: rangeCache,
                    isCancelled: cancelCheck,
                    logHandler: logHandler,
                    onMediaProgress: onMediaProgress
                )
            }
        } else {
            logHandler(
                "Probing \(containerFormat.displayName) via pCloud before sparse temp — " +
                    "skips _working.mp4 shell when vanilla/HLS recovery will run"
            )
            do {
                (durationSeconds, videoFormat, audioFormat) = try await probeStreamMetadataOnly(
                    inputURL: inputURL,
                    authorizationProvider: authorizationProvider,
                    rangeCache: rangeCache,
                    containerFormat: containerFormat,
                    log: logHandler
                )
            } catch {
                return try await attemptRecoveryExport(
                    probeError: error,
                    item: item,
                    inputURL: inputURL,
                    credentials: credentials,
                    containerFormat: containerFormat,
                    fileBytes: fileSize,
                    seekMs: seekMs,
                    continueLANExport: continueLANExport,
                    resumeCursorMs: resumeCursorMs,
                    authorizationProvider: authorizationProvider,
                    rangeCache: rangeCache,
                    isCancelled: cancelCheck,
                    logHandler: logHandler,
                    onMediaProgress: onMediaProgress
                )
            }
            downloader = try WebDAVTempFileDownload(
                fileKey: item.fileKey,
                sourceHref: item.href,
                remoteURL: inputURL,
                rangeCache: rangeCache,
                containerFormat: containerFormat,
                authorizationProvider: authorizationProvider,
                isCancelled: cancelCheck,
                log: logHandler
            )
            tempDownload = downloader
            downloader.logDownloadStarted()
            try await downloader.ensureIndexTailOnDisk()
        }

        let durationMs = Int64(durationSeconds * 1000)
        let seekSeconds = Double(seekMs) / 1000.0
        if durationMs > 0, seekMs >= durationMs - 250 {
            logHandler(
                "Seek \(formatSeekMs(seekMs)) is at or past file duration (~\(formatSeekMs(durationMs))) — choose 0 min or a shorter start preset"
            )
            throw SegmentExporterError.seekPastEnd
        }
        let impliedMbps = Self.impliedAverageMbps(fileBytes: fileSize, durationSeconds: durationSeconds)
        let lanPrefetch = Self.lanWorkingPrefetchPolicy(
            seekSeconds: seekSeconds,
            impliedMbps: impliedMbps
        )
        ExportPlaybackState.shared.setBackgroundPrefetchEnabled(lanPrefetch.prepareHeadAndIndex)
        ExportPlaybackState.shared.setLANPrefetchHorizonToEOF(lanPrefetch.prefetchHorizonToEOF)
        ExportPlaybackState.shared.beginExport(
            seekSeconds: seekSeconds,
            durationSeconds: durationSeconds,
            totalBytes: fileSize
        )
        if continueLANExport {
            logHandler(
                "LAN dashboard — resume export (started \(ExportTimelineLog.wallClock(seconds: seekSeconds)), " +
                    "exported cursor from checkpoint/manifest)"
            )
        } else {
            logHandler(
                "LAN dashboard — fresh export (reset manifest playback/export cursor to " +
                    "\(ExportTimelineLog.wallClock(seconds: seekSeconds)))"
            )
        }
        WorkingSourceSparseCatalog.bootstrapLANMetricsForExport(
            fileURL: downloader.fileURL,
            fileKey: item.fileKey,
            href: item.href,
            seekSeconds: seekSeconds,
            durationSeconds: durationSeconds,
            resume: continueLANExport,
            resumeCursorSeconds: resumeCursorMs.map { Double($0) / 1000.0 }
        )
        if lanPrefetch.prepareHeadAndIndex {
            if seekSeconds <= 0.5 {
                try Self.ensureExportDiskSpace(
                    fileBytes: fileSize,
                    lanPrefetchToEOF: lanPrefetch.prefetchHorizonToEOF
                )
            } else {
                try Self.ensureExportDiskSpace(fileBytes: fileSize)
            }
            try await preloadWorkingSourceForLANPlayback(
                downloader: downloader,
                fileSize: fileSize,
                seekSeconds: seekSeconds,
                durationSeconds: durationSeconds,
                lanPrefetch: lanPrefetch,
                impliedMbps: impliedMbps,
                log: logHandler
            )
        }
        tempDownload?.beginExport(
            seekSeconds: seekSeconds,
            durationSeconds: durationSeconds,
            sequentialLANPrefetch: lanPrefetch.prepareHeadAndIndex,
            lanPreloadExclusive: lanPrefetch.lanPreloadOnly
        )
        ExportPlaybackState.shared.setLANPreloadOnly(lanPrefetch.lanPreloadOnly)
        await MainActor.run {
            ResumeStore.shared.setSourceDurationMs(durationMs, for: item)
        }
        let lanExportCursorSeconds = ExportPlaybackState.shared.exportCursorSeconds
        if lanPrefetch.prepareHeadAndIndex {
            downloader.updateLANSequentialPrefetchHorizon(
                playbackStartSeconds: seekSeconds,
                horizonTimelineSeconds: Self.lanPrefetchHorizonSeconds(
                    playbackStartSeconds: seekSeconds,
                    exportCursorSeconds: lanExportCursorSeconds,
                    durationSeconds: durationSeconds,
                    prefetchHorizonToEOF: lanPrefetch.prefetchHorizonToEOF
                ),
                durationSeconds: durationSeconds
            )
        }
        downloader.publishLANPlaybackState(mediaCursorSeconds: lanExportCursorSeconds)

        let reportProgress: @Sendable (Int64) -> Void = { [weak self] mediaMs in
            onMediaProgress?(mediaMs)
            let seconds = Double(mediaMs) / 1000.0
            ExportPlaybackState.shared.updateCursor(seconds: seconds)
            self?.tempDownload?.publishLANPlaybackState(mediaCursorSeconds: seconds)
        }

        logHandler(
            "Video codec \(CodecSupport.fourCCString(videoFormat))" +
                (audioFormat.map { ", audio \(CodecSupport.fourCCString($0))" } ?? ", no audio")
        )
        if seekMs > 0 {
            logHandler(
                "Export seek — start at source \(ExportTimelineLog.wallClock(seconds: seekSeconds)), " +
                    "duration ~\(ExportTimelineLog.wallClock(seconds: durationSeconds))"
            )
        }

        let dlnaPublishOrigin = CFAbsoluteTimeGetCurrent()
        var minuteIndex = 0
        var mediaCursorSeconds = lanExportCursorSeconds
        var lastMediaTimeMs = Int64(lanExportCursorSeconds * 1000)
        var reachedEnd = false

            logHandler(
            "Phone export: pcld_ios_media/loop/op_00 ↔ op_01 per ~\(Int(Self.segmentDurationSeconds))s " +
                (ExportDeliveryPolicy.keyframeAlignedBoundaries ? "(keyframe borders)" : "") +
                "; PC: Mount-LoopSegmentsRclone.ps1"
        )

            guard let downloader = tempDownload else {
                throw SegmentExporterError.readerSetupFailed
            }

        if lanPrefetch.lanPreloadOnly {
            logHandler(
                ExportDeliveryPolicy.skip60sSegmentsLogReason(impliedMbps: impliedMbps)
            )
            return try await runLANPreloadOnly(
                downloader: downloader,
                seekSeconds: seekSeconds,
                durationSeconds: durationSeconds,
                durationMs: durationMs,
                fileSize: fileSize,
                impliedMbps: impliedMbps,
                reportProgress: reportProgress,
                logHandler: logHandler
            )
        }

        logHandler(
            "Publishing ~\(Int(Self.segmentDurationSeconds))s segments — dense fill each window, then passthrough " +
                "(per-minute failsafe: skip on error and continue; op_*.mp4 + LAN _working when server on)"
        )

        var skippedSegmentCount = 0
        var publishedSegmentCount = 0
            while true {
                try checkCancelled()

                let windowStartSeconds = mediaCursorSeconds
                if windowStartSeconds >= durationSeconds - 0.05 {
                    reachedEnd = true
                    break
                }

                let windowEndSeconds = min(windowStartSeconds + Self.segmentDurationSeconds, durationSeconds)
                let windowSeconds = windowEndSeconds - windowStartSeconds
                if windowSeconds < 0.5 {
                    logHandler(
                        String(
                            format: "End of file — segment window %.1fs at %d:%02d (nothing left to export)",
                            windowSeconds,
                            Int(windowStartSeconds / 60),
                            Int(windowStartSeconds) % 60
                        )
                    )
                    reachedEnd = true
                    break
                }
                let byteRangeEndSeconds = min(
                    windowEndSeconds + (
                        ExportDeliveryPolicy.keyframeAlignedBoundaries
                            ? ExportDeliveryPolicy.keyframeEndHuntSeconds
                            : 0
                    ),
                    durationSeconds
                )
                let byteRange = downloader.byteRangeForTimeline(
                    timelineStartSeconds: windowStartSeconds,
                    timelineEndSeconds: byteRangeEndSeconds,
                    durationSeconds: durationSeconds
                )
                let effectiveDuration = WebDAVTempFileDownload.effectiveDurationSeconds(
                    reported: durationSeconds,
                    totalBytes: fileSize
                )
                if abs(effectiveDuration - durationSeconds) > 1 {
                    logHandler(
                        String(
                            format: "Timeline bytes use %.0f s duration (index %.0f s) for %d:%02d–%d:%02d",
                            effectiveDuration,
                            durationSeconds,
                            Int(windowStartSeconds / 60),
                            Int(windowStartSeconds) % 60,
                            Int(windowEndSeconds / 60),
                            Int(windowEndSeconds) % 60
                        )
                    )
                }
                logHandler(
                    ExportTimelineLog.processingMinute(
                        index: minuteIndex,
                        startSeconds: windowStartSeconds,
                        endSeconds: windowEndSeconds
                )
                )
                logHandler(
                    "Need ~\(Self.formatBytes(byteRange.length)) at file \(Self.formatBytes(byteRange.start))–\(Self.formatBytes(byteRange.end)) " +
                        "for \(ExportTimelineLog.sourceRange(startSeconds: windowStartSeconds, endSeconds: windowEndSeconds))"
                )
                let rangeStart = CMTime(seconds: windowStartSeconds, preferredTimescale: 600)
                let rangeDuration = CMTime(
                    seconds: windowEndSeconds - windowStartSeconds,
                    preferredTimescale: 600
                )
                let slot = minuteIndex % Self.segmentFileCount
                let stagingURL = ExportPaths.segmentStagingURL(index: slot)
                do {
                let midFileRemotePassthrough = shouldUseRemotePassthroughForMidFile(
                    byteRange: byteRange,
                    downloader: downloader
                )
                let largeHEVCDenseLocal = midFileRemotePassthrough
                    && fileSize >= Self.streamOnlyThresholdBytes
                    && Self.isHEVCFormat(videoFormat)
                let skipDenseMidFileRemote = midFileRemotePassthrough
                    && fileSize >= Self.streamOnlyThresholdBytes
                    && !Self.isHEVCFormat(videoFormat)
                    && !lanPrefetch.prefetchHorizonToEOF
                let lanDenseMidFileOnWorking = midFileRemotePassthrough
                    && fileSize >= Self.streamOnlyThresholdBytes
                    && !Self.isHEVCFormat(videoFormat)
                    && lanPrefetch.prefetchHorizonToEOF
                if largeHEVCDenseLocal {
                    logHandler(
                        "Large HEVC (\(Self.formatBytes(fileSize))) — dense fill + capped hybrid for " +
                            "\(Int(windowStartSeconds / 60)):\(String(format: "%02d", Int(windowStartSeconds) % 60))–" +
                            "\(Int(windowEndSeconds / 60)):\(String(format: "%02d", Int(windowEndSeconds) % 60)) " +
                            "(~\(Self.formatBytes(byteRange.length)); remote passthrough skipped on multi‑GB HEVC)"
                    )
                } else if lanDenseMidFileOnWorking {
                    logHandler(
                        "LAN (<\(Int(ExportLANServer.backgroundPrefetchCutoffMbps)) Mbps est.) — dense fill on _working.mp4 for " +
                            "\(Int(windowStartSeconds / 60)):\(String(format: "%02d", Int(windowStartSeconds) % 60))–" +
                            "\(Int(windowEndSeconds / 60)):\(String(format: "%02d", Int(windowEndSeconds) % 60)) " +
                            "(~\(Self.formatBytes(byteRange.length)); grows contiguous LAN, not remote passthrough)"
                    )
                } else if skipDenseMidFileRemote {
                    logHandler(
                        "Large sparse file (\(Self.formatBytes(fileSize))) — remote passthrough for " +
                            "\(Int(windowStartSeconds / 60)):\(String(format: "%02d", Int(windowStartSeconds) % 60))–" +
                            "\(Int(windowEndSeconds / 60)):\(String(format: "%02d", Int(windowEndSeconds) % 60)) " +
                            "(pCloud range reads for this 60s; skipping ~\(Self.formatBytes(byteRange.length)) dense download)"
                    )
                } else if midFileRemotePassthrough {
                    logHandler(
                        "Mid-file segment — remote passthrough from pCloud for " +
                            "\(Int(windowStartSeconds / 60)):\(String(format: "%02d", Int(windowStartSeconds) % 60))–" +
                            "\(Int(windowEndSeconds / 60)):\(String(format: "%02d", Int(windowEndSeconds) % 60)) " +
                            "(sparse hybrid reader skipped)"
                    )
                }
                if skipDenseMidFileRemote {
                    // remote passthrough reads ranges from pCloud; no dense window on sparse temp
                } else if isDenseWindowReady(downloader: downloader, byteRange: byteRange) {
                    logHandler(
                        "Minute window already dense on _working.mp4 — passthrough from disk (no pCloud read for this segment)"
                    )
                    logHandler(
                        "Dense window + MP4 head/index on disk — skipping readiness probe " +
                            "(AVAssetReader preflight often reports 0 samples on sparse HEVC)"
                    )
                } else {
                    logHandler(
                        "Verifying reader for \(Int(windowStartSeconds / 60)):\(String(format: "%02d", Int(windowStartSeconds) % 60))–\(Int(windowEndSeconds / 60)):\(String(format: "%02d", Int(windowEndSeconds) % 60)) (large sparse files can take a few minutes)…"
                    )
                try await downloader.ensureFileHeadOnDisk()
                try await downloader.ensureIndexTailOnDisk()
                try await downloader.ensureContiguousRange(
                    byteRange,
                    bridgeLANGapBeforeWindow: lanPrefetch.prefetchHorizonToEOF
                )
                    if isDenseWindowReady(downloader: downloader, byteRange: byteRange) {
                        logHandler(
                            "Minute window already dense on _working.mp4 — passthrough from disk (no pCloud read for this segment)"
                        )
                        logHandler(
                            "Dense window + MP4 head/index on disk — skipping readiness probe " +
                                "(AVAssetReader preflight often reports 0 samples on sparse HEVC)"
                        )
                    } else {
                try await SegmentLocalReadiness.waitUntilReadable(
                    fileURL: downloader.fileURL,
                    rangeStart: rangeStart,
                    rangeDuration: rangeDuration,
                    totalFileBytes: downloader.totalLength,
                    requiredByteRange: byteRange,
                    isWindowDenseFilled: { downloader.isRangeFilled(byteRange) },
                    windowFilledBytes: { downloader.exportWindowFilledBytes(for: byteRange) },
                    filledByteSpan: { downloader.filledSpan() },
                    indexTailOnDisk: { downloader.hasIndexTailOnDisk() },
                    refreshMP4Index: { try await downloader.ensureIndexTailOnDisk(force: true) },
                    prepareSparseFileForReader: {
                        try await downloader.ensureFileHeadOnDisk()
                        try await downloader.ensureIndexTailOnDisk()
                        try await downloader.ensureContiguousRange(
                            byteRange,
                            bridgeLANGapBeforeWindow: lanPrefetch.prefetchHorizonToEOF
                        )
                    },
                    isCancelled: cancelCheck,
                    log: logHandler
                )
                    }
                }

                let boundary = try await exportSegmentFromTempOrStream(
                    downloader: downloader,
                    tempURL: downloader.fileURL,
                    remoteURL: inputURL,
                    authorizationProvider: authorizationProvider,
                    rangeCache: rangeCache,
                    trustedLength: fileSize,
                    byteRange: byteRange,
                    videoFormat: videoFormat,
                    audioFormat: audioFormat,
                    rangeStart: rangeStart,
                    rangeDuration: rangeDuration,
                    outputURL: stagingURL,
                    preferDenseFillOnWorkingForLAN: lanPrefetch.prefetchHorizonToEOF,
                    isCancelled: cancelCheck,
                    log: logHandler
                )
                let actualDuration = CMTime(
                    seconds: boundary.segmentDurationSeconds,
                    preferredTimescale: 600
                )
                if ExportDeliveryPolicy.keyframeAlignedBoundaries {
                    logHandler(
                        "Segment \(minuteIndex + 1) — source \(ExportTimelineLog.sourceRange(start: boundary.segmentStart, end: boundary.segmentEnd)); " +
                            "next window at \(ExportTimelineLog.wallClock(boundary.nextSegmentStart))"
                    )
                }
                try await publishValidatedSegment(
                    minuteIndex: minuteIndex,
                    slot: slot,
                    stagingURL: stagingURL,
                    rangeDuration: actualDuration,
                    wallOrigin: dlnaPublishOrigin,
                    log: logHandler
                )
                publishedSegmentCount += 1
                    mediaCursorSeconds = boundary.nextSegmentStartSeconds
                } catch {
                    try checkCancelled()
                    if !Self.shouldSkipMinuteAndContinue(after: error) {
                        throw error
                    }
                    skippedSegmentCount += 1
                    try? FileManager.default.removeItem(at: stagingURL)
                    logHandler(
                        "Minute skipped (failsafe) — source \(ExportTimelineLog.sourceRange(startSeconds: windowStartSeconds, endSeconds: windowEndSeconds)): \(error.localizedDescription)"
                    )
                    logHandler(
                        "Continuing — next minute will dense-fill on _working.mp4 " +
                            "(LAN :8765 when serve is on)"
                    )
                    mediaCursorSeconds = windowEndSeconds
                }

                lastMediaTimeMs = Int64(mediaCursorSeconds * 1000)
                reportProgress(lastMediaTimeMs)
                if lanPrefetch.prepareHeadAndIndex {
                    downloader.updateLANSequentialPrefetchHorizon(
                        playbackStartSeconds: seekSeconds,
                        horizonTimelineSeconds: Self.lanPrefetchHorizonSeconds(
                            playbackStartSeconds: seekSeconds,
                            exportCursorSeconds: mediaCursorSeconds,
                            durationSeconds: durationSeconds,
                            prefetchHorizonToEOF: lanPrefetch.prefetchHorizonToEOF
                        ),
                        durationSeconds: durationSeconds
                    )
                }
                if ExportLANServer.isEnabled {
                    downloader.syncLANPlaybackManifestNow(mediaCursorSeconds: mediaCursorSeconds)
                    logHandler(
                        downloader.maxBrowserPlayableStatusLog(
                            playbackStartSeconds: seekSeconds,
                            durationSeconds: durationSeconds,
                            exportCursorSeconds: mediaCursorSeconds
                        )
                    )
                }
                minuteIndex += 1
            }

            if lanPrefetch.waitForBackgroundAtEnd {
                try await downloader.waitUntilComplete()
            }

        if skippedSegmentCount > 0 {
            logHandler(
                "Export finished — \(publishedSegmentCount) segment(s) published, " +
                    "\(skippedSegmentCount) minute(s) skipped; see log above. " +
                    (reachedEnd ? "Reached end of file." : "Export stopped before EOF.")
            )
        } else {
        logHandler(reachedEnd ? "Reached end of file — all segments published." : "Export stopped.")
        }
        return SegmentExportResult(
            lastMediaTimeMs: lastMediaTimeMs,
            reachedEnd: reachedEnd,
            skippedSegmentCount: skippedSegmentCount,
            lanPreloadOnly: false
        )
    }

    /// pCloud `gethlslink` → segments + progressive `_working_pcloud_transcode.mp4` (not sparse WebDAV).
    private func runPCloudHLSExport(
        item: WebDAVItem,
        credentials: WebDAVCredentials,
        fileBytes: Int64,
        seekMs: Int64,
        continueLANExport: Bool,
        resumeCursorMs: Int64?,
        isCancelled: @escaping () -> Bool,
        logHandler: @escaping (String) -> Void,
        onMediaProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> SegmentExportResult {
        PCloudTranscodedWorkingWriter.prepareForNewExport(log: logHandler)
        if let notice = ExportPlaybackState.shared.pcloudTranscodedWorkingUserNotice() {
            logHandler(notice)
        }
        logHandler(
            "pCloud transcode export — \(item.name); original file stays on pCloud; " +
                "LAN plays \(ExportPaths.pathRelativeToExports(ExportPaths.workingTranscodedURL)) as export advances"
        )

        let link = try await PCloudHLSLink.resolveMasterPlaylist(
            credentials: credentials,
            sourceHref: item.href,
            log: logHandler
        )
        let hlsAsset = AVURLAsset(
            url: link.masterPlaylistURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        retainedAsset = hlsAsset
        defer { retainedAsset = nil }

        let (durationSeconds, videoFormat, audioFormat) = try await probeStreamMetadata(asset: hlsAsset, log: logHandler)
        let effectiveBytes = fileBytes > 0 ? fileBytes : (item.contentLength ?? 0)
        let impliedSourceMbps = Self.impliedAverageMbps(
            fileBytes: effectiveBytes,
            durationSeconds: durationSeconds
        )
        guard Self.sourceQualifiesForPCloudHLSTranscode(
            fileBytes: effectiveBytes,
            durationSeconds: durationSeconds
        ) else {
            logHandler(
                String(
                    format: "Source ~%.1f Mbps (file %@, %.0f s) — at or below %.1f Mbps cutoff; " +
                        "pCloud HLS transcode not used",
                    impliedSourceMbps,
                    Self.formatBytes(effectiveBytes),
                    durationSeconds,
                    PCloudHLSLink.transcodeMinSourceMbps
                )
            )
            throw SegmentExporterError.containerProbeFailed(.asf)
        }
        logHandler(
            String(
                format: "Source ~%.1f Mbps — above %.1f Mbps cutoff; pCloud HLS max %@ @ %d kbps video",
                impliedSourceMbps,
                PCloudHLSLink.transcodeMinSourceMbps,
                PCloudHLSLink.maxTranscodeResolution,
                PCloudHLSLink.maxTranscodeVideoKbps
            )
        )
        let durationMs = Int64(durationSeconds * 1000)
        let seekSeconds = Double(seekMs) / 1000.0
        if durationMs > 0, seekMs >= durationMs - 250 {
            throw SegmentExporterError.seekPastEnd
        }

        ExportPlaybackState.shared.beginTranscodedExport(
            seekSeconds: seekSeconds,
            durationSeconds: durationSeconds,
            sourceFileBytes: effectiveBytes
        )
        ExportPlaybackState.shared.setBackgroundPrefetchEnabled(false)
        await MainActor.run {
            ResumeStore.shared.setSourceDurationMs(durationMs, for: item)
        }

        let reportProgress: @Sendable (Int64) -> Void = { mediaMs in
            onMediaProgress?(mediaMs)
            let seconds = Double(mediaMs) / 1000.0
            ExportPlaybackState.shared.updateCursor(seconds: seconds)
        }

        var mediaCursorSeconds = seekSeconds
        if continueLANExport, let resumeCursorMs, resumeCursorMs > 0 {
            mediaCursorSeconds = min(durationSeconds, Double(resumeCursorMs) / 1000.0)
        }
        reportProgress(Int64(mediaCursorSeconds * 1000))

        logHandler(
            "Video codec \(CodecSupport.fourCCString(videoFormat))" +
                (audioFormat.map { ", audio \(CodecSupport.fourCCString($0))" } ?? ", no audio") +
                " (pCloud HLS transcode)"
        )
        logHandler(
            "Publishing ~\(Int(Self.segmentDurationSeconds))s segments from HLS — " +
                "op_00/op_01 + growing \(ExportPaths.pathRelativeToExports(ExportPaths.workingTranscodedURL))"
        )

        let dlnaPublishOrigin = CFAbsoluteTimeGetCurrent()
        var minuteIndex = 0
        var lastMediaTimeMs = Int64(mediaCursorSeconds * 1000)
        var reachedEnd = false
        var skippedSegmentCount = 0
        var publishedSegmentCount = 0

        while true {
            if isCancelled() { throw SegmentExporterError.cancelled }

            let windowStartSeconds = mediaCursorSeconds
            if windowStartSeconds >= durationSeconds - 0.05 {
                reachedEnd = true
                break
            }
            let windowEndSeconds = min(windowStartSeconds + Self.segmentDurationSeconds, durationSeconds)
            if windowEndSeconds - windowStartSeconds < 0.5 {
                reachedEnd = true
                break
            }

            logHandler(
                ExportTimelineLog.processingMinute(
                    index: minuteIndex,
                    startSeconds: windowStartSeconds,
                    endSeconds: windowEndSeconds
                )
            )

            let rangeStart = CMTime(seconds: windowStartSeconds, preferredTimescale: 600)
            let rangeDuration = CMTime(
                seconds: windowEndSeconds - windowStartSeconds,
                preferredTimescale: 600
            )
            let slot = minuteIndex % Self.segmentFileCount
            let stagingURL = ExportPaths.segmentStagingURL(index: slot)

            do {
                let boundary = try await SegmentPassThroughExporter.exportWindow(
                    asset: hlsAsset,
                    videoFormat: videoFormat,
                    audioFormat: audioFormat,
                    rangeStart: rangeStart,
                    rangeDuration: rangeDuration,
                    outputURL: stagingURL,
                    sourceLabel: "pCloud HLS",
                    isCancelled: isCancelled,
                    log: logHandler
                )
                try await publishValidatedSegment(
                    minuteIndex: minuteIndex,
                    slot: slot,
                    stagingURL: stagingURL,
                    rangeDuration: CMTime(seconds: boundary.segmentDurationSeconds, preferredTimescale: 600),
                    wallOrigin: dlnaPublishOrigin,
                    log: logHandler
                )
                publishedSegmentCount += 1
                mediaCursorSeconds = boundary.nextSegmentStartSeconds
                try await PCloudTranscodedWorkingWriter.updateProgressive(
                    asset: hlsAsset,
                    throughSeconds: windowEndSeconds,
                    log: logHandler
                )
            } catch {
                if isCancelled() { throw SegmentExporterError.cancelled }
                if !Self.shouldSkipMinuteAndContinue(after: error) { throw error }
                skippedSegmentCount += 1
                try? FileManager.default.removeItem(at: stagingURL)
                logHandler("Minute skipped (HLS failsafe): \(error.localizedDescription)")
                mediaCursorSeconds = windowEndSeconds
            }

            lastMediaTimeMs = Int64(mediaCursorSeconds * 1000)
            reportProgress(lastMediaTimeMs)
            minuteIndex += 1
        }

        logHandler(
            skippedSegmentCount > 0
                ? "HLS export finished — \(publishedSegmentCount) segment(s), \(skippedSegmentCount) skipped"
                : (reachedEnd ? "HLS export reached end of transcode." : "HLS export stopped.")
        )
        return SegmentExportResult(
            lastMediaTimeMs: lastMediaTimeMs,
            reachedEnd: reachedEnd,
            skippedSegmentCount: skippedSegmentCount,
            lanPreloadOnly: false
        )
    }

    private func finishVanillaWithout60sSegments(
        downloadURL: URL,
        downloadRel: String,
        fastStartRelative: String?,
        seekMs: Int64,
        effectiveBytes: Int64,
        reason: String,
        logHandler: @escaping (String) -> Void
    ) async throws -> SegmentExportResult {
        let durationSeconds = (try? await probeLocalDurationSeconds(fileURL: downloadURL, log: logHandler)) ?? 0
        let seekSeconds = Double(seekMs) / 1000.0
        ExportPlaybackState.shared.beginVanillaExport(
            downloadRelativePath: downloadRel,
            fastStartRelativePath: fastStartRelative,
            seekSeconds: seekSeconds,
            durationSeconds: durationSeconds,
            totalBytes: effectiveBytes
        )
        ExportPlaybackState.shared.updateVanillaDownloadProgress(downloadedBytes: effectiveBytes)
        logHandler("Vanilla download complete — \(downloadRel). \(reason)")
        return SegmentExportResult(
            lastMediaTimeMs: seekMs,
            reachedEnd: false,
            skippedSegmentCount: 0,
            lanPreloadOnly: false
        )
    }

    private static let vanillaDurationProbeByteThresholds: [Int64] = [
        4 * 1024 * 1024,
        16 * 1024 * 1024,
        64 * 1024 * 1024,
        256 * 1024 * 1024,
    ]

    private struct VanillaDurationResolve {
        let seconds: Double
        let isEstimated: Bool
    }

    /// Size-only guess before index is readable — scales assumed Mbps with file size (avoids 10 Mbps on ~300 MB WMV).
    private static func vanillaDurationFallbackAssumedMbps(fileBytes: Int64) -> Double {
        let gb = Double(fileBytes) / (1024 * 1024 * 1024)
        let mb = Double(fileBytes) / (1024 * 1024)
        let cutoff = ExportLANServer.backgroundPrefetchCutoffMbps
        if gb >= 10 { return max(cutoff, 30) }
        if gb >= 3 { return max(cutoff, 25) }
        if gb >= 1 { return 15 }
        if mb >= 200 { return 25 }
        if mb >= 80 { return 20 }
        return 10
    }

    private func persistVanillaSourceDuration(seconds: Double, item: WebDAVItem) {
        guard seconds.isFinite, seconds > 0 else { return }
        let ms = Int64(seconds * 1000)
        Task { @MainActor in
            ResumeStore.shared.setSourceDurationMs(ms, for: item)
        }
    }

    private static func estimatedVanillaDurationFromFileBytes(_ fileBytes: Int64) -> (seconds: Double, assumedMbps: Double) {
        guard fileBytes > 0 else { return (0, 10) }
        let assumedMbps = vanillaDurationFallbackAssumedMbps(fileBytes: fileBytes)
        let seconds = Double(fileBytes) * 8.0 / (assumedMbps * 1_000_000.0)
        return (seconds, assumedMbps)
    }

    private static func logVanillaDurationSizeEstimate(
        estimated: Double,
        assumedMbps: Double,
        containerFormat: MediaContainerFormat,
        fastPath: Bool,
        log: @escaping (String) -> Void
    ) {
        guard estimated > 0 else { return }
        let updatesNote = containerFormat.supportsIOSegmentExport
            ? "updates when moov is readable"
            : "updates during download if index becomes readable"
        let prefix = fastPath
            ? "Vanilla LAN timeline — estimated (fast path, skipped remote \(containerFormat.displayName) probe) "
            : "Vanilla LAN timeline — estimated "
        log(
            prefix + ExportTimelineLog.wallClock(seconds: estimated) + " " +
                String(format: "from file size (~%.0f Mbps guess; \(updatesNote))", assumedMbps)
        )
    }

    private func probeRemoteDurationSeconds(
        inputURL: URL,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        rangeCache: WebDAVRangeCache,
        containerFormat: MediaContainerFormat,
        log: @escaping (String) -> Void
    ) async -> Double? {
        let streamingAsset: AVURLAsset
        do {
            streamingAsset = try await openStreamingAsset(
                inputURL: inputURL,
                authorizationProvider: authorizationProvider,
                rangeCache: rangeCache,
                logHandler: log
            )
        } catch {
            return nil
        }
        defer {
            retainedWebDAVLoader?.cancelOutstandingWork()
            retainedAsset?.resourceLoader.setDelegate(nil, queue: nil)
            retainedWebDAVLoader = nil
            retainedAsset = nil
        }
        return await probeAssetDurationSeconds(
            asset: streamingAsset,
            containerFormat: containerFormat,
            sourceLabel: "pCloud index",
            log: log
        )
    }

    private func probeAssetDurationSeconds(
        asset: AVURLAsset,
        containerFormat: MediaContainerFormat,
        sourceLabel: String,
        log: @escaping (String) -> Void
    ) async -> Double? {
        let maxAttempts = containerFormat == .asf ? 90 : 60
        var lastLog = CFAbsoluteTimeGetCurrent()
        for attempt in 1 ... maxAttempts {
            if let videoTrack = try? await firstVideoTrack(in: asset) {
                _ = videoTrack
                if let duration = try? await asset.load(.duration) {
                    let seconds = CMTimeGetSeconds(duration)
                    if seconds.isFinite, seconds > 0 {
                        log(
                            "Vanilla LAN timeline — duration from \(sourceLabel) " +
                                "(\(containerFormat.displayName) \(ExportTimelineLog.wallClock(seconds: seconds)))"
                        )
                        return seconds
                    }
                }
            }
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastLog >= 10 {
                lastLog = now
                log(
                    "Waiting for \(containerFormat.displayName) duration via \(sourceLabel) (attempt \(attempt))…"
                )
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    private func resolveVanillaDurationSeconds(
        item: WebDAVItem,
        fileBytes: Int64,
        partialFileURL: URL,
        inputURL: URL,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        rangeCache: WebDAVRangeCache,
        log: @escaping (String) -> Void
    ) async -> VanillaDurationResolve {
        let containerFormat = MediaContainerFormat.from(filename: item.name)
        let resumeMs = await MainActor.run {
            ResumeStore.shared.snapshotEntries()
                .first { $0.fileKey == item.fileKey }?
                .sourceDurationMs
        }
        if let resumeMs, resumeMs > 500 {
            let seconds = Double(resumeMs) / 1000.0
            log(
                "Vanilla LAN timeline — resume store duration \(ExportTimelineLog.wallClock(seconds: seconds))"
            )
            persistVanillaSourceDuration(seconds: seconds, item: item)
            return VanillaDurationResolve(seconds: seconds, isEstimated: false)
        }
        let fm = FileManager.default
        let fastPath = containerFormat.usesVanillaOnlyOnDevice
        if fm.fileExists(atPath: partialFileURL.path) {
            let onDisk = (try? fm.attributesOfItem(atPath: partialFileURL.path)[.size] as? NSNumber)?
                .int64Value ?? 0
            if onDisk > 4 * 1024 * 1024,
               let probed = try? await probeLocalDurationSeconds(
                   fileURL: partialFileURL,
                   containerFormat: containerFormat,
                   maxAttempts: fastPath ? 4 : nil,
                   log: log
               ),
               probed > 0 {
                log(
                    "Vanilla LAN timeline — probed partial file \(ExportTimelineLog.wallClock(seconds: probed))"
                )
                persistVanillaSourceDuration(seconds: probed, item: item)
                return VanillaDurationResolve(seconds: probed, isEstimated: false)
            }
        }
        if !fastPath,
           let remote = await probeRemoteDurationSeconds(
               inputURL: inputURL,
               authorizationProvider: authorizationProvider,
               rangeCache: rangeCache,
               containerFormat: containerFormat,
               log: log
           ) {
            persistVanillaSourceDuration(seconds: remote, item: item)
            return VanillaDurationResolve(seconds: remote, isEstimated: false)
        }
        let (estimated, assumedMbps) = Self.estimatedVanillaDurationFromFileBytes(fileBytes)
        Self.logVanillaDurationSizeEstimate(
            estimated: estimated,
            assumedMbps: assumedMbps,
            containerFormat: containerFormat,
            fastPath: fastPath,
            log: log
        )
        return VanillaDurationResolve(seconds: estimated, isEstimated: estimated > 0)
    }

    private func probeLocalDurationSeconds(
        fileURL: URL,
        containerFormat: MediaContainerFormat? = nil,
        maxAttempts: Int? = nil,
        log: @escaping (String) -> Void
    ) async throws -> Double {
        let asset = AVURLAsset(
            url: fileURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let format = containerFormat ?? MediaContainerFormat.from(filename: fileURL.lastPathComponent)
        let attempts: Int
        if let maxAttempts {
            attempts = max(1, maxAttempts)
        } else {
            switch format {
            case .asf, .avi, .matroska, .webm:
                attempts = 24
            default:
                attempts = 8
            }
        }
        var lastLog = CFAbsoluteTimeGetCurrent()
        for attempt in 1 ... attempts {
            if let _ = try? await firstVideoTrack(in: asset) {
                let duration = try await asset.load(.duration)
                let seconds = CMTimeGetSeconds(duration)
                if seconds.isFinite, seconds > 0 {
                    return seconds
                }
            }
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastLog >= 8 {
                lastLog = now
                log("Waiting for video track/duration in vanilla file (attempt \(attempt))…")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        log("Duration not available from vanilla file index")
        return 0
    }

    /// Probe failed or vanilla/HLS recovery — sparse `_working.mp4` is not the LAN source anymore.
    private func abandonSparseWorkingForRecovery(logHandler: @escaping (String) -> Void) {
        tempDownload?.prepareForAbandon()
        tempDownload = nil
        WorkingSourceSparseCatalog.remove()
        if ExportPaths.removeWorkingSourceCopy(log: logHandler) {
            logHandler(
                "Removed sparse _working.mp4 — recovery uses vanilla download or pCloud transcode, not sparse WebDAV"
            )
        }
        ExportPlaybackState.shared.clearSparseWorkingPlaybackHints()
    }

    private static func canReuseSparseWorkingForResume(
        item: WebDAVItem,
        fileSize: Int64,
        continueLANExport: Bool
    ) -> Bool {
        guard continueLANExport, fileSize > 0 else { return false }
        return WorkingSourceSparseCatalog.tryAdopt(
            fileKey: item.fileKey,
            totalLength: fileSize,
            fileURL: ExportPaths.workingSourceURL
        ) != nil
    }

    private func attemptRecoveryExport(
        probeError: Error,
        item: WebDAVItem,
        inputURL: URL,
        credentials: WebDAVCredentials,
        containerFormat: MediaContainerFormat,
        fileBytes: Int64,
        seekMs: Int64,
        continueLANExport: Bool,
        resumeCursorMs: Int64?,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        rangeCache: WebDAVRangeCache,
        isCancelled: @escaping () -> Bool,
        logHandler: @escaping (String) -> Void,
        onMediaProgress: (@Sendable (Int64) -> Void)?
    ) async throws -> SegmentExportResult {
        abandonSparseWorkingForRecovery(logHandler: logHandler)
        var vanillaFailure: Error?
        if VanillaWebDAVDownload.isBackupEnabled {
            logHandler(
                "WebDAV probe failed for \(containerFormat.displayName) — vanilla WebDAV download first " +
                    "(full file, original extension; uses WebDAV only, no pCloud API / gethlslink)"
            )
            do {
                return try await runVanillaDownloadExport(
                    item: item,
                    inputURL: inputURL,
                    fileBytes: fileBytes,
                    seekMs: seekMs,
                    continueLANExport: continueLANExport,
                    resumeCursorMs: resumeCursorMs,
                    authorizationProvider: authorizationProvider,
                    rangeCache: rangeCache,
                    isCancelled: isCancelled,
                    logHandler: logHandler,
                    onMediaProgress: onMediaProgress
                )
            } catch {
                if isCancelled() || error is CancellationError {
                    throw SegmentExporterError.cancelled
                }
                vanillaFailure = error
                logHandler("Vanilla download failed — \(error.localizedDescription)")
                if let partial = await finishRecoveryWithPartialVanillaIfPossible(
                    item: item,
                    seekMs: seekMs,
                    probeError: probeError,
                    vanillaError: error,
                    logHandler: logHandler
                ) {
                    return partial
                }
            }
        }
        if isCancelled() { throw SegmentExporterError.cancelled }
        if Self.shouldAttemptPCloudHLSFallback(
            error: probeError,
            containerFormat: containerFormat,
            fileBytes: fileBytes
        ) {
            logHandler(
                "Trying pCloud HLS transcode fallback " +
                    "(>\(PCloudHLSLink.transcodeMinSourceMbps) Mbps est., max \(PCloudHLSLink.maxTranscodeResolution); needs API token) → " +
                    "\(ExportPaths.pathRelativeToExports(ExportPaths.workingTranscodedURL))"
            )
            return try await runPCloudHLSExport(
                item: item,
                credentials: credentials,
                fileBytes: fileBytes,
                seekMs: seekMs,
                continueLANExport: continueLANExport,
                resumeCursorMs: resumeCursorMs,
                isCancelled: isCancelled,
                logHandler: logHandler,
                onMediaProgress: onMediaProgress
            )
        }
        if let vanillaFailure {
            throw vanillaFailure
        }
        throw probeError
    }

    /// After vanilla WebDAV fails, keep a large partial `_vanilla_download.*` on LAN instead of rethrowing the sparse probe error (e.g. AV1).
    private func finishRecoveryWithPartialVanillaIfPossible(
        item: WebDAVItem,
        seekMs: Int64,
        probeError: Error,
        vanillaError: Error,
        logHandler: @escaping (String) -> Void
    ) async -> SegmentExportResult? {
        let downloadURL = ExportPaths.vanillaDownloadURL(preservingExtensionFrom: item.name)
        let fm = FileManager.default
        guard fm.fileExists(atPath: downloadURL.path) else { return nil }
        let onDisk = (try? fm.attributesOfItem(atPath: downloadURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard onDisk >= 4 * 1024 * 1024 else { return nil }

        let downloadRel = ExportPaths.pathRelativeToExports(downloadURL)
        let ext = (item.name as NSString).pathExtension.lowercased()
        let fastStartRelative = ["mp4", "mov", "m4v"].contains(ext)
            ? ExportPaths.pathRelativeToExports(ExportPaths.vanillaFastStartURL)
            : nil
        let (estimatedDuration, _) = Self.estimatedVanillaDurationFromFileBytes(onDisk)
        let seekSeconds = Double(seekMs) / 1000.0

        ExportPlaybackState.shared.beginVanillaExport(
            downloadRelativePath: downloadRel,
            fastStartRelativePath: fastStartRelative,
            seekSeconds: seekSeconds,
            durationSeconds: estimatedDuration,
            totalBytes: onDisk,
            initialDownloadedBytes: onDisk,
            durationIsEstimated: estimatedDuration > 0
        )

        let segmentNote: String
        if case SegmentExporterError.unsupportedCodec(let fourCC) = probeError {
            segmentNote =
                "\(fourCC) cannot be cut into 60s MP4 segments on iOS — play the vanilla file on LAN or re-encode to HEVC (hvc1/hev1) or H.264 with AAC."
        } else if case SegmentExporterError.containerProbeFailed(let format) = probeError {
            segmentNote =
                "\(format.displayName) has no 60s segment export on iOS — play \(downloadRel) on LAN :8765 or on PC."
        } else {
            segmentNote = "60s segment export unavailable — play the partial download on LAN :8765."
        }

        logHandler(
            "Partial vanilla kept — \(Self.formatExportBytes(onDisk)) at \(downloadRel) " +
                "(download stopped: \(vanillaError.localizedDescription)). \(segmentNote)"
        )
        return SegmentExportResult(
            lastMediaTimeMs: seekMs,
            reachedEnd: false,
            skippedSegmentCount: 0,
            lanPreloadOnly: false
        )
    }

    private static func formatExportBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
        }
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        }
        return "\(bytes) B"
    }

    /// Dense full-file download + segment export from local copy (not sparse `_working.mp4`).
    private func runVanillaDownloadExport(
        item: WebDAVItem,
        inputURL: URL,
        fileBytes: Int64,
        seekMs: Int64,
        continueLANExport: Bool,
        resumeCursorMs: Int64?,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        rangeCache: WebDAVRangeCache,
        isCancelled: @escaping () -> Bool,
        logHandler: @escaping (String) -> Void,
        onMediaProgress: (@Sendable (Int64) -> Void)?
    ) async throws -> SegmentExportResult {
        abandonSparseWorkingForRecovery(logHandler: logHandler)
        ExportPlaybackState.shared.setPCloudTranscodedWorkingActive(false)

        let downloadURL = ExportPaths.vanillaDownloadURL(preservingExtensionFrom: item.name)
        let effectiveBytes = fileBytes > 0 ? fileBytes : (item.contentLength ?? 0)
        guard effectiveBytes > 0 else { throw WebDAVResourceLoaderError.missingContentLength }

        let downloadRel = ExportPaths.pathRelativeToExports(downloadURL)
        let ext = (item.name as NSString).pathExtension.lowercased()
        let usesFastStartDuringDownload = ["mp4", "mov", "m4v"].contains(ext)
        let fastStartURL = usesFastStartDuringDownload ? ExportPaths.vanillaFastStartURL : nil
        let fastStartRelative = fastStartURL.map { ExportPaths.pathRelativeToExports($0) }
        let initialDownloadedBytes = VanillaDownloadResumeCatalog.initialDownloadedBytes(
            fileKey: item.fileKey,
            totalLength: effectiveBytes,
            destinationURL: downloadURL
        )

        let seekSeconds = Double(seekMs) / 1000.0
        let containerFormat = MediaContainerFormat.from(filename: item.name)
        let durationResolve = await resolveVanillaDurationSeconds(
            item: item,
            fileBytes: effectiveBytes,
            partialFileURL: downloadURL,
            inputURL: inputURL,
            authorizationProvider: authorizationProvider,
            rangeCache: rangeCache,
            log: logHandler
        )
        ExportPlaybackState.shared.beginVanillaExport(
            downloadRelativePath: downloadRel,
            fastStartRelativePath: fastStartRelative,
            seekSeconds: seekSeconds,
            durationSeconds: durationResolve.seconds,
            totalBytes: effectiveBytes,
            initialDownloadedBytes: initialDownloadedBytes,
            durationIsEstimated: durationResolve.isEstimated
        )
        if seekMs > 0 {
            logHandler(
                "Vanilla export seek — \(ExportTimelineLog.wallClock(seconds: seekSeconds)) for segments / LAN resume hint; " +
                    "WebDAV download fills the file from 0:00 (or resumes partial _vanilla_download.*)"
            )
        }

        final class VanillaDurationProbeState: @unchecked Sendable {
            var nextThresholdIndex = 0
        }
        let durationProbe = VanillaDurationProbeState()

        try await VanillaWebDAVDownload.downloadFullFile(
            remoteURL: inputURL,
            destinationURL: downloadURL,
            fileKey: item.fileKey,
            sourceHref: item.href,
            totalLength: effectiveBytes,
            fastStartDestinationURL: fastStartURL,
            authorizationProvider: authorizationProvider,
            isCancelled: isCancelled,
            log: logHandler,
            onDownloadedBytes: { [weak self] bytes in
                ExportPlaybackState.shared.updateVanillaDownloadProgress(downloadedBytes: bytes)
                guard let self else { return }
                guard ExportPlaybackState.shared.vanillaDurationNeedsProbe else { return }
                guard durationProbe.nextThresholdIndex < Self.vanillaDurationProbeByteThresholds.count else {
                    return
                }
                let threshold = Self.vanillaDurationProbeByteThresholds[durationProbe.nextThresholdIndex]
                guard bytes >= threshold else { return }
                durationProbe.nextThresholdIndex += 1
                Task {
                    if let probed = try? await self.probeLocalDurationSeconds(
                        fileURL: downloadURL,
                        containerFormat: containerFormat,
                        log: logHandler
                    ),
                        probed > 0 {
                        ExportPlaybackState.shared.setVanillaDurationSeconds(probed)
                        self.persistVanillaSourceDuration(seconds: probed, item: item)
                        logHandler(
                            "Vanilla LAN timeline — probed during download " +
                                "\(ExportTimelineLog.wallClock(seconds: probed))"
                        )
                    }
                }
            }
        )

        var exportAssetURL = downloadURL
        var vanillaSourceAlreadyFaststart = false
        if usesFastStartDuringDownload {
            if FileManager.default.fileExists(atPath: ExportPaths.vanillaFastStartURL.path) {
                exportAssetURL = ExportPaths.vanillaFastStartURL
            } else if MP4NetworkOptimize.sourceAlreadyNetworkOptimized(at: downloadURL) {
                vanillaSourceAlreadyFaststart = true
                logHandler(
                    "Using \(downloadURL.lastPathComponent) for export — moov already at head (pCloud pre-faststart)"
                )
            }
        }

        if !containerFormat.supportsIOSegmentExport {
            return try await finishVanillaWithout60sSegments(
                downloadURL: downloadURL,
                downloadRel: downloadRel,
                fastStartRelative: fastStartRelative,
                seekMs: seekMs,
                effectiveBytes: effectiveBytes,
                reason:
                    "60s segments not supported for \(containerFormat.displayName) on iOS — " +
                    "use \(downloadRel) on PC (PotPlayer/VLC) or LAN :8765",
                logHandler: logHandler
            )
        }

        let durationForPolicy = (try? await probeLocalDurationSeconds(fileURL: downloadURL, log: logHandler)) ?? 0
        let impliedMbpsForPolicy = Self.impliedAverageMbps(
            fileBytes: effectiveBytes,
            durationSeconds: durationForPolicy
        )
        if !ExportDeliveryPolicy.shouldRun60sSegments(
            impliedMbps: impliedMbpsForPolicy
        ) {
            return try await finishVanillaWithout60sSegments(
                downloadURL: downloadURL,
                downloadRel: downloadRel,
                fastStartRelative: fastStartRelative,
                seekMs: seekMs,
                effectiveBytes: effectiveBytes,
                reason: ExportDeliveryPolicy.skip60sSegmentsLogReason(
                    impliedMbps: impliedMbpsForPolicy
                ),
                logHandler: logHandler
            )
        }

        let durationSeconds: Double
        let videoFormat: CMFormatDescription
        let audioFormat: CMFormatDescription?
        do {
            (durationSeconds, videoFormat, audioFormat) = try await probeLocalMetadata(
                fileURL: exportAssetURL,
                log: logHandler
            )
        } catch {
            let downloadRel = ExportPaths.pathRelativeToExports(downloadURL)
            ExportPlaybackState.shared.beginVanillaExport(
                downloadRelativePath: downloadRel,
                fastStartRelativePath: fastStartRelative,
                seekSeconds: Double(seekMs) / 1000.0,
                durationSeconds: 0,
                totalBytes: effectiveBytes
            )
            logHandler(
                "Vanilla file saved at \(downloadRel) — segment export unavailable (\(error.localizedDescription)). " +
                    "Play the download on LAN :8765 or copy to PC."
            )
            return SegmentExportResult(
                lastMediaTimeMs: seekMs,
                reachedEnd: false,
                skippedSegmentCount: 0,
                lanPreloadOnly: false
            )
        }

        let durationMs = Int64(durationSeconds * 1000)
        if durationMs > 0, seekMs >= durationMs - 250 {
            throw SegmentExporterError.seekPastEnd
        }

        ExportPlaybackState.shared.beginVanillaExport(
            downloadRelativePath: downloadRel,
            fastStartRelativePath: fastStartRelative,
            seekSeconds: seekSeconds,
            durationSeconds: durationSeconds,
            totalBytes: effectiveBytes
        )
        ExportPlaybackState.shared.updateVanillaDownloadProgress(downloadedBytes: effectiveBytes)
        if let notice = ExportPlaybackState.shared.vanillaDownloadUserNotice() {
            logHandler(notice)
        }
        await MainActor.run {
            ResumeStore.shared.setSourceDurationMs(durationMs, for: item)
        }

        let reportProgress: @Sendable (Int64) -> Void = { mediaMs in
            onMediaProgress?(mediaMs)
            ExportPlaybackState.shared.updateCursor(seconds: Double(mediaMs) / 1000.0)
        }

        var mediaCursorSeconds = seekSeconds
        if continueLANExport, let resumeCursorMs, resumeCursorMs > 0 {
            mediaCursorSeconds = min(durationSeconds, Double(resumeCursorMs) / 1000.0)
        }
        reportProgress(Int64(mediaCursorSeconds * 1000))

        logHandler(
            "Video codec \(CodecSupport.fourCCString(videoFormat))" +
                (audioFormat.map { ", audio \(CodecSupport.fourCCString($0))" } ?? ", no audio") +
                " (vanilla local file)"
        )
        logHandler(
            "Publishing ~\(Int(Self.segmentDurationSeconds))s segments from \(exportAssetURL.lastPathComponent) — " +
                "op_00/op_01; LAN full file at \(downloadRel)"
        )

        let localAsset = AVURLAsset(
            url: exportAssetURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        retainedAsset = localAsset
        defer { retainedAsset = nil }

        let dlnaPublishOrigin = CFAbsoluteTimeGetCurrent()
        var minuteIndex = 0
        var lastMediaTimeMs = Int64(mediaCursorSeconds * 1000)
        var reachedEnd = false
        var skippedSegmentCount = 0
        var publishedSegmentCount = 0

        while true {
            if isCancelled() { throw SegmentExporterError.cancelled }

            let windowStartSeconds = mediaCursorSeconds
            if windowStartSeconds >= durationSeconds - 0.05 {
                reachedEnd = true
                break
            }
            let windowEndSeconds = min(windowStartSeconds + Self.segmentDurationSeconds, durationSeconds)
            if windowEndSeconds - windowStartSeconds < 0.5 {
                reachedEnd = true
                break
            }

            logHandler(
                ExportTimelineLog.processingMinute(
                    index: minuteIndex,
                    startSeconds: windowStartSeconds,
                    endSeconds: windowEndSeconds
                )
            )

            let rangeStart = CMTime(seconds: windowStartSeconds, preferredTimescale: 600)
            let rangeDuration = CMTime(
                seconds: windowEndSeconds - windowStartSeconds,
                preferredTimescale: 600
            )
            let slot = minuteIndex % Self.segmentFileCount
            let stagingURL = ExportPaths.segmentStagingURL(index: slot)

            do {
                let boundary = try await SegmentPassThroughExporter.exportWindow(
                    asset: localAsset,
                    videoFormat: videoFormat,
                    audioFormat: audioFormat,
                    rangeStart: rangeStart,
                    rangeDuration: rangeDuration,
                    outputURL: stagingURL,
                    sourceLabel: "vanilla download",
                    isCancelled: isCancelled,
                    log: logHandler
                )
                try await publishValidatedSegment(
                    minuteIndex: minuteIndex,
                    slot: slot,
                    stagingURL: stagingURL,
                    rangeDuration: CMTime(seconds: boundary.segmentDurationSeconds, preferredTimescale: 600),
                    wallOrigin: dlnaPublishOrigin,
                    log: logHandler
                )
                publishedSegmentCount += 1
                mediaCursorSeconds = boundary.nextSegmentStartSeconds
            } catch {
                if isCancelled() { throw SegmentExporterError.cancelled }
                if !Self.shouldSkipMinuteAndContinue(after: error) { throw error }
                skippedSegmentCount += 1
                try? FileManager.default.removeItem(at: stagingURL)
                logHandler("Minute skipped (vanilla failsafe): \(error.localizedDescription)")
                mediaCursorSeconds = windowEndSeconds
            }

            lastMediaTimeMs = Int64(mediaCursorSeconds * 1000)
            reportProgress(lastMediaTimeMs)
            minuteIndex += 1
        }

        logHandler(
            skippedSegmentCount > 0
                ? "Vanilla export finished — \(publishedSegmentCount) segment(s), \(skippedSegmentCount) skipped; " +
                    "full source remains at \(downloadRel)"
                : (reachedEnd
                    ? "Vanilla export reached end of file — \(downloadRel) on disk for LAN/PC"
                    : "Vanilla export stopped — \(downloadRel) on disk")
        )
        return SegmentExportResult(
            lastMediaTimeMs: lastMediaTimeMs,
            reachedEnd: reachedEnd,
            skippedSegmentCount: skippedSegmentCount,
            lanPreloadOnly: false
        )
    }

    /// Below LAN bitrate cutoff: sequential fill to EOF only (no `op_*.mp4` — full WAN for `_working.mp4`).
    private func runLANPreloadOnly(
        downloader: WebDAVTempFileDownload,
        seekSeconds: Double,
        durationSeconds: Double,
        durationMs: Int64,
        fileSize: Int64,
        impliedMbps: Double,
        reportProgress: @escaping @Sendable (Int64) -> Void,
        logHandler: @escaping (String) -> Void
    ) async throws -> SegmentExportResult {
        let cutoff = ExportLANServer.backgroundPrefetchCutoffMbps
        logHandler(
            String(
                format: "LAN preload only — file ~%.1f Mbps (below %.0f Mbps cutoff); op_00/op_01 export disabled",
                impliedMbps,
                cutoff
            )
        )
        logHandler(
            "Sequential fill to EOF on _working.mp4 (8 parallel chunks) — target wall time ~½× media duration at your link speed"
        )
        logHandler("Play on LAN :8765 → pcld_ios_media/_working.mp4; raise cutoff if you need PC op_*.mp4 segments")
        let cursorSeconds = ExportPlaybackState.shared.exportCursorSeconds
        downloader.updateLANSequentialPrefetchHorizon(
            playbackStartSeconds: seekSeconds,
            horizonTimelineSeconds: durationSeconds,
            durationSeconds: durationSeconds
        )
        reportProgress(Int64(cursorSeconds * 1000))
        logHandler(
            downloader.maxBrowserPlayableStatusLog(
                playbackStartSeconds: seekSeconds,
                durationSeconds: durationSeconds,
                exportCursorSeconds: cursorSeconds
            )
        )
        if seekSeconds > 0.5 {
            try await downloader.ensureLANPrefixBeforeSeekFilled(
                seekSeconds: seekSeconds,
                durationSeconds: durationSeconds
            )
        }
        try await downloader.waitUntilComplete(durationSeconds: durationSeconds) { timelineSec in
            reportProgress(Int64(timelineSec * 1000))
        }
        if seekSeconds > 0.5 {
            try await downloader.ensureLANPlaybackPrerollGapFilled(
                seekSeconds: seekSeconds,
                durationSeconds: durationSeconds
            )
        }
        let full = TimelineByteRange(start: 0, end: fileSize)
        let reachedEnd = downloader.isByteRangeFullyOnDisk(full)
        let lastMs = reachedEnd ? durationMs : Int64(
            downloader.backgroundTimelineSeconds(durationSeconds: durationSeconds) * 1000
        )
        logHandler(
            downloader.maxBrowserPlayableStatusLog(
                playbackStartSeconds: seekSeconds,
                durationSeconds: durationSeconds,
                exportCursorSeconds: Double(lastMs) / 1000.0
            )
        )
        if reachedEnd {
            logHandler("LAN preload complete — full \(Self.formatBytes(fileSize)) contiguous on disk for browser playback")
        } else {
            logHandler("LAN preload stopped before EOF — partial contiguous fill on _working.mp4")
        }
        return SegmentExportResult(
            lastMediaTimeMs: lastMs,
            reachedEnd: reachedEnd,
            skippedSegmentCount: 0,
            lanPreloadOnly: true
        )
    }

    /// Files above this or that do not fit on disk are exported by range reads (no full temp copy).
    private static let streamOnlyThresholdBytes: Int64 = 1_500_000_000
    private static let diskMarginBytes: Int64 = 384 * 1024 * 1024
    private static let streamingWorkingSetBytes: Int64 = 700 * 1024 * 1024

    private func publishValidatedSegment(
        minuteIndex: Int,
        slot: Int,
        stagingURL: URL,
        rangeDuration: CMTime,
        wallOrigin: CFAbsoluteTime,
        log: @escaping (String) -> Void
    ) async throws {
        try await SegmentLocalReadiness.validateOutputFile(
            at: stagingURL,
            rangeDuration: rangeDuration,
            log: log
        )
        let skipWallHold = ExportPaths.segmentFileCount == 1
            || (ExportDeliveryPolicy.prioritizeFirstPhotosPublish && minuteIndex == 0)
        if !skipWallHold {
            await waitForDLNAPublishSchedule(
                minuteIndex: minuteIndex,
                wallOrigin: wallOrigin,
                slot: slot,
                log: log
            )
        } else if ExportPaths.segmentFileCount == 1 {
            log("Publishing segment immediately (first slot; wall-clock hold skipped)")
        } else {
            log("Publishing slot 0 immediately (no wall-clock hold)")
        }
        try ExportPaths.publishSegmentToDLNA(slot: slot, log: log)
        let finalURL = ExportPaths.segmentURL(index: slot)
        let photosSaved = await PhotosSegmentPublisher.publish(segmentSlot: slot, videoURL: finalURL, log: log)
        if photosSaved {
            log("Ready for PC Photos sync — \(finalURL.lastPathComponent)")
        } else if PhotosSegmentPublisher.isEnabled {
            log("DLNA ready — Photos import failed; use Exports/\(finalURL.lastPathComponent) or Apple Devices")
        } else {
            log("Ready for PC sync — \(finalURL.lastPathComponent) (Photos off)")
        }
        if minuteIndex == 0, ExportDeliveryPolicy.prioritizeFirstPhotosPublish {
            let elapsed = CFAbsoluteTimeGetCurrent() - wallOrigin
            if photosSaved {
                log(
                    String(
                        format: "Photos-first: %@ in library %.0fs after export start (target ≤%.0fs)",
                        finalURL.lastPathComponent,
                        elapsed,
                        ExportDeliveryPolicy.firstPhotosTargetSeconds
                    )
                )
            } else if PhotosSegmentPublisher.isEnabled {
                log(
                    String(
                        format: "Photos-first: import failed %.0fs after export start (DLNA file OK in Exports)",
                        elapsed
                    )
                )
            }
        }
        if ExportPaths.segmentFileCount == 1 {
            log("Segment \(finalURL.lastPathComponent) published (~60s cadence)")
        } else {
            log("DLNA slot \(finalURL.lastPathComponent) published (~60s wall-clock cadence)")
        }
    }

    private static func hasDiskForFullCopy(fileBytes: Int64) -> Bool {
        guard let free = freeDiskBytes() else { return true }
        return free >= fileBytes + diskMarginBytes
    }

    private static func freeDiskBytes() -> Int64? {
        let path = ExportPaths.exportDiskSpaceCheckDirectory.path
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let freeNumber = attrs[.systemFreeSize] as? NSNumber else {
            return nil
        }
        return freeNumber.int64Value
    }

    private static func ensureExportDiskSpace(fileBytes: Int64, lanPrefetchToEOF: Bool = false) throws {
        guard let free = freeDiskBytes() else { return }
        let budget = lanPrefetchToEOF
            ? max(fileBytes, 0)
            : min(max(fileBytes, 0), streamingWorkingSetBytes)
        let needed = budget + diskMarginBytes
        guard free >= needed else {
            throw SegmentExporterError.insufficientDiskSpace(needed: needed, available: max(0, free))
        }
    }

    private func isDenseWindowReady(
        downloader: WebDAVTempFileDownload,
        byteRange: TimelineByteRange
    ) -> Bool {
        downloader.hasHeadOnDisk()
            && downloader.hasIndexTailOnDisk()
            && downloader.isByteRangeFullyOnDisk(byteRange)
    }

    private func exportSegmentFromTempOrStream(
        downloader: WebDAVTempFileDownload,
        tempURL: URL,
        remoteURL: URL,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        rangeCache: WebDAVRangeCache,
        trustedLength: Int64,
        byteRange: TimelineByteRange,
        videoFormat: CMFormatDescription,
        audioFormat: CMFormatDescription?,
        rangeStart: CMTime,
        rangeDuration: CMTime,
        outputURL: URL,
        preferDenseFillOnWorkingForLAN: Bool = false,
        isCancelled: @escaping () -> Bool,
        log: @escaping (String) -> Void
    ) async throws -> SegmentPassThroughResult {
        let fileLength = trustedLength > 0 ? trustedLength : downloader.totalLength
        let rangeEnd = CMTimeAdd(rangeStart, rangeDuration)
        log(
            "Export segment — source \(ExportTimelineLog.sourceRange(start: rangeStart, end: rangeEnd)) " +
                "file bytes \(Self.formatBytes(byteRange.start))–\(Self.formatBytes(byteRange.end))"
        )
        if shouldUseRemotePassthroughForMidFile(
            byteRange: byteRange,
            downloader: downloader,
            preferDenseFillOnWorkingForLAN: preferDenseFillOnWorkingForLAN
        ) {
            log(
                "Mid-file segment — reading this minute from pCloud (window not dense on _working.mp4 yet); Mbps in log is pCloud, not LAN playback"
            )
            return try await exportMidFileSegmentOverRemote(
                downloader: downloader,
                tempURL: tempURL,
                remoteURL: remoteURL,
                authorizationProvider: authorizationProvider,
                rangeCache: rangeCache,
                trustedLength: fileLength,
                byteRange: byteRange,
                videoFormat: videoFormat,
                audioFormat: audioFormat,
                rangeStart: rangeStart,
                rangeDuration: rangeDuration,
                outputURL: outputURL,
                isCancelled: isCancelled,
                log: log
            )
        }

        let midFileSegment = byteRange.start >= Self.midFilePrefetchThresholdBytes
        if midFileSegment {
            log(
                "Mid-file segment — dense \(Self.formatBytes(byteRange.length)) at \(Self.formatBytes(byteRange.start))"
            )
            try await prepareMidFileTempForReader(
                downloader: downloader,
                byteRange: byteRange,
                bridgeLANGapBeforeWindow: preferDenseFillOnWorkingForLAN,
                log: log
            )
        }

        if !isDenseWindowReady(downloader: downloader, byteRange: byteRange) {
            try await downloader.ensureFileHeadOnDisk()
            try await downloader.ensureIndexTailOnDisk()
            try await downloader.ensureContiguousRange(
                byteRange,
                bridgeLANGapBeforeWindow: preferDenseFillOnWorkingForLAN
            )
        }

        var windowDense = isDenseWindowReady(downloader: downloader, byteRange: byteRange)
        if windowDense {
            log(
                "Passthrough via dense local temp — \(Self.formatBytes(byteRange.length)) at \(Self.formatBytes(byteRange.start)) on disk"
            )
        } else {
            log("Passthrough via sparse temp + pCloud (holes fetched on demand)")
        }

        func runPassthrough(
            sourceLabel: String,
            useOnDiskFileURL: Bool,
            forceHTTPSRangeReads: Bool = false
        ) async throws -> SegmentPassThroughResult {
            if useOnDiskFileURL, isFullSourceOnDisk(downloader: downloader) {
                log(
                    "Passthrough via AVAssetExportSession (full \(Self.formatBytes(downloader.totalLength)) file on disk)"
                )
                let fileAsset = AVURLAsset(
                    url: tempURL,
                    options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
                )
                return try await SegmentPassThroughExporter.exportWindowViaExportSession(
                    asset: fileAsset,
                    rangeStart: rangeStart,
                    rangeDuration: rangeDuration,
                    outputURL: outputURL,
                    sourceLabel: "\(sourceLabel) (export session)",
                    log: log
                )
            }
            var (readAsset, hybridLoader) = try await resolvePassthroughReadAsset(
                downloader: downloader,
                tempURL: tempURL,
                remoteURL: remoteURL,
                authorizationProvider: authorizationProvider,
                rangeCache: rangeCache,
                trustedLength: trustedLength,
                byteRange: byteRange,
                useOnDiskFileURL: useOnDiskFileURL,
                forceHTTPSRangeReads: forceHTTPSRangeReads,
                log: log
            )
            if hybridLoader != nil {
                do {
                    _ = try AVAssetReader(asset: readAsset)
                } catch {
                    log(
                        "Hybrid reader could not open (\(error.localizedDescription)) — using HTTPS byte-range reads"
                    )
                    readAsset.resourceLoader.setDelegate(nil, queue: nil)
                    hybridLoader?.cancelOutstandingWork()
                    hybridLoader = nil
                    readAsset = makeHTTPSPassthroughAsset(
                        remoteURL: remoteURL,
                        authorizationProvider: authorizationProvider
                    )
                }
            }
            if let hybridLoader {
                defer {
                    readAsset.resourceLoader.setDelegate(nil, queue: nil)
                    hybridLoader.cancelOutstandingWork()
                }
            }
            return try await SegmentPassThroughExporter.exportWindow(
                asset: readAsset,
                videoFormat: videoFormat,
                audioFormat: audioFormat,
                rangeStart: rangeStart,
                rangeDuration: rangeDuration,
                outputURL: outputURL,
                sourceLabel: sourceLabel,
                isCancelled: isCancelled,
                log: log
            )
        }

        let tempSourceLabel = windowDense ? "dense local temp" : "sparse temp + pCloud"
        var useOnDiskFileURL = shouldUseOnDiskFileURLForPassthrough(
            downloader: downloader,
            byteRange: byteRange,
            windowDense: windowDense
        )
        if windowDense, !useOnDiskFileURL, byteRange.start > 0 {
            log(
                "Dense window at \(Self.formatBytes(byteRange.start)) but not fully on disk — capped hybrid reader"
            )
        } else if windowDense, useOnDiskFileURL, byteRange.start > 0 {
            log(
                "Mid-file dense window — passthrough via file:// on _working.mp4 (\(Self.formatBytes(byteRange.length)) local)"
            )
        }
        if windowDense,
           CMTimeGetSeconds(rangeStart) < 0.5,
           !isFullSourceOnDisk(downloader: downloader) {
            try await ensureSeekZeroRemainderOnDiskIfBeneficial(
                downloader: downloader,
                byteRange: byteRange,
                log: log
            )
        }
        downloader.closeWriteHandleForPassthroughRead(log: log)
        if useOnDiskFileURL,
           Self.shouldPreferExportSessionForDenseHEVCWindow(
               byteRange: byteRange,
               videoFormat: videoFormat
           ) {
            log(
                "Dense HEVC window ~\(Self.formatBytes(byteRange.length)) on disk — " +
                    "AVAssetExportSession passthrough (manual writer often stalls on high-bitrate minutes)"
            )
            return try await exportDenseOnDiskViaExportSession(
                tempURL: tempURL,
                rangeStart: rangeStart,
                rangeDuration: rangeDuration,
                outputURL: outputURL,
                sourceLabel: "\(tempSourceLabel) (export session, dense HEVC window)",
                log: log
            )
        }
        do {
            return try await runPassthrough(
                sourceLabel: tempSourceLabel,
                useOnDiskFileURL: useOnDiskFileURL
            )
        } catch {
            if isFullSourceOnDisk(downloader: downloader),
               case SegmentExporterError.noKeyframeInWindow = error {
                log("Manual passthrough found no keyframe — trying AVAssetExportSession")
                downloader.closeWriteHandleForPassthroughRead(log: log)
                let fileAsset = AVURLAsset(
                    url: tempURL,
                    options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
                )
                return try await SegmentPassThroughExporter.exportWindowViaExportSession(
                    asset: fileAsset,
                    rangeStart: rangeStart,
                    rangeDuration: rangeDuration,
                    outputURL: outputURL,
                    sourceLabel: "\(tempSourceLabel) (export session after keyframe scan)",
                    log: log
                )
            }
            if byteRange.start > 0,
               windowDense,
               Self.isUnsupportedAssetURLError(error) || Self.isHybridReaderOpenFailure(error) {
                let reason = Self.isUnsupportedAssetURLError(error)
                    ? "custom asset URL rejected"
                    : "hybrid reader could not open"
                log("\(reason.capitalized) — remote passthrough from pCloud")
                downloader.closeWriteHandleForPassthroughRead(log: log)
                return try await exportMidFileSegmentOverRemote(
                    downloader: downloader,
                    tempURL: tempURL,
                    remoteURL: remoteURL,
                    authorizationProvider: authorizationProvider,
                    rangeCache: rangeCache,
                    trustedLength: fileLength,
                    byteRange: byteRange,
                    videoFormat: videoFormat,
                    audioFormat: audioFormat,
                    rangeStart: rangeStart,
                    rangeDuration: rangeDuration,
                    outputURL: outputURL,
                    isCancelled: isCancelled,
                    log: log
                )
            }
            if byteRange.start == 0,
               windowDense,
               Self.isUnsupportedAssetURLError(error) {
                log(
                    "Hybrid asset URL rejected (\(error.localizedDescription)) — dense-filling file tail, then on-disk passthrough"
                )
                try await ensureSeekZeroRemainderOnDiskIfBeneficial(
                    downloader: downloader,
                    byteRange: byteRange,
                    log: log
                )
                downloader.closeWriteHandleForPassthroughRead(log: log)
                return try await runPassthrough(
                    sourceLabel: tempSourceLabel,
                    useOnDiskFileURL: true
                )
            }
            guard Self.shouldStreamFallback(after: error) else { throw error }
                try? FileManager.default.removeItem(at: outputURL)
            if useOnDiskFileURL,
               byteRange.start == 0,
               Self.isRetriablePassthroughWriterFailure(error) {
                if !isFullSourceOnDisk(downloader: downloader) {
                    log(
                        "On-disk passthrough failed (\(error.localizedDescription)) — dense-filling remainder after window"
                    )
                    try await ensureSeekZeroRemainderOnDiskIfBeneficial(
                        downloader: downloader,
                        byteRange: byteRange,
                        log: log
                    )
                }
                downloader.closeWriteHandleForPassthroughRead(log: log)
                if isFullSourceOnDisk(downloader: downloader) {
                    log(
                        "On-disk writer rejected samples (\(error.localizedDescription)) — trying AVAssetExportSession passthrough"
                    )
                    let fileAsset = AVURLAsset(
                        url: tempURL,
                        options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
                    )
                    return try await SegmentPassThroughExporter.exportWindowViaExportSession(
                        asset: fileAsset,
                        rangeStart: rangeStart,
                        rangeDuration: rangeDuration,
                        outputURL: outputURL,
                        sourceLabel: "\(tempSourceLabel) (export session)",
                        log: log
                    )
                }
                log(
                    "On-disk passthrough failed (\(error.localizedDescription)) — sparse gap after window; using capped hybrid reader"
                )
                try await Task.sleep(nanoseconds: 400_000_000)
                return try await runPassthrough(
                    sourceLabel: "\(tempSourceLabel) (hybrid after on-disk writer error)",
                    useOnDiskFileURL: false
                )
            }
            if useOnDiskFileURL,
               byteRange.start > 0,
               isSparseContainerOpenFailure(error) || Self.isRetriablePassthroughWriterFailure(error) {
                log(
                    "On-disk passthrough failed (\(error.localizedDescription)) — retrying with capped hybrid reader"
                )
                downloader.closeWriteHandleForPassthroughRead(log: log)
                return try await runPassthrough(
                    sourceLabel: "\(tempSourceLabel) (hybrid retry)",
                    useOnDiskFileURL: false
                )
            }
            let writerRejected = Self.isRetriablePassthroughWriterFailure(error)
            let writerBackpressure: Bool = {
                if case SegmentExporterError.writerBackpressure = error { return true }
                return false
            }()
            if writerRejected, windowDense {
                if useOnDiskFileURL {
                    log(
                        "Writer rejected on-disk reader (\(error.localizedDescription)) — retrying with capped hybrid reader"
                    )
                    downloader.closeWriteHandleForPassthroughRead(log: log)
                    return try await runPassthrough(
                        sourceLabel: "dense local temp (hybrid after writer error)",
                        useOnDiskFileURL: false
                    )
                }
                log(
                    "Writer rejected passthrough (\(error.localizedDescription)) — re-downloading window, then capped hybrid reader"
                )
                downloader.pauseBackgroundDownloadForForegroundFill()
                defer { downloader.resumeBackgroundDownloadAfterForegroundFill() }
                try await downloader.ensureFileHeadOnDisk()
                try await downloader.ensureIndexTailOnDisk()
                try await downloader.ensureContiguousRange(
                    byteRange,
                    force: true,
                    bridgeLANGapBeforeWindow: preferDenseFillOnWorkingForLAN
                )
                windowDense = isDenseWindowReady(downloader: downloader, byteRange: byteRange)
                downloader.closeWriteHandleForPassthroughRead(log: log)
                return try await runPassthrough(
                    sourceLabel: windowDense ? "dense local temp (writer retry)" : "sparse temp + pCloud (writer retry)",
                    useOnDiskFileURL: false
                )
            }
            if writerBackpressure {
                log(
                    "Video writer stalled with 0 samples (\(error.localizedDescription)) — dense-filling window, then retrying"
                )
            } else if writerRejected {
                log(
                    "Writer rejected passthrough samples (\(error.localizedDescription)) — dense-filling window, then retrying locally"
                )
            } else if midFileSegment, isSparseContainerOpenFailure(error) {
                log(
                    "Sparse temp not readable (\(error.localizedDescription)) — refreshing header, index, and window, then capped hybrid reader…"
                )
                downloader.pauseBackgroundDownloadForForegroundFill()
                defer { downloader.resumeBackgroundDownloadAfterForegroundFill() }
                try await prepareMidFileTempForReader(
                    downloader: downloader,
                    byteRange: byteRange,
                    bridgeLANGapBeforeWindow: preferDenseFillOnWorkingForLAN,
                    log: log
                )
                windowDense = isDenseWindowReady(downloader: downloader, byteRange: byteRange)
                useOnDiskFileURL = false
                downloader.closeWriteHandleForPassthroughRead(log: log)
                do {
                    return try await runPassthrough(
                        sourceLabel: windowDense ? "dense local temp (hybrid retry)" : "sparse temp + pCloud (retry)",
                        useOnDiskFileURL: false
                    )
                } catch {
                    guard Self.shouldStreamFallback(after: error) else { throw error }
                    try? FileManager.default.removeItem(at: outputURL)
                }
            }
            if writerBackpressure {
                log("Dense-filling this minute’s byte window before retrying passthrough…")
            } else if !writerRejected {
                log(
                    "Temp not readable (\(error.localizedDescription)) — downloading this minute to temp, then retrying reader"
                )
            }
            if writerBackpressure, windowDense, useOnDiskFileURL {
                log(
                    "Manual writer backpressure on dense on-disk window — trying AVAssetExportSession before re-download"
                )
                try? FileManager.default.removeItem(at: outputURL)
                downloader.closeWriteHandleForPassthroughRead(log: log)
                do {
                    return try await exportDenseOnDiskViaExportSession(
                        tempURL: tempURL,
                        rangeStart: rangeStart,
                        rangeDuration: rangeDuration,
                        outputURL: outputURL,
                        sourceLabel: "\(tempSourceLabel) (export session after writer stall)",
                        log: log
                    )
                } catch {
                    log(
                        "AVAssetExportSession after writer stall failed (\(error.localizedDescription)) — " +
                            "retrying manual passthrough"
                    )
                }
            }
            downloader.pauseBackgroundDownloadForForegroundFill()
            defer { downloader.resumeBackgroundDownloadAfterForegroundFill() }
            try await downloader.ensureFileHeadOnDisk()
            try await downloader.ensureIndexTailOnDisk()
            try await downloader.ensureContiguousRange(byteRange)
            windowDense = isDenseWindowReady(downloader: downloader, byteRange: byteRange)
            useOnDiskFileURL = shouldUseOnDiskFileURLForPassthrough(
                downloader: downloader,
                byteRange: byteRange,
                windowDense: windowDense
            )
            downloader.closeWriteHandleForPassthroughRead(log: log)
            return try await runPassthrough(
                sourceLabel: windowDense ? "dense local temp (window filled)" : "sparse temp + pCloud (window filled)",
                useOnDiskFileURL: useOnDiskFileURL
            )
        }
    }

    private func isFullSourceOnDisk(downloader: WebDAVTempFileDownload) -> Bool {
        let length = downloader.totalLength
        guard length > 0 else { return false }
        return downloader.isByteRangeFullyOnDisk(TimelineByteRange(start: 0, end: length))
    }

    /// Mid-file on a sparse temp: hybrid/`file://` often fails — use pCloud only when the minute window is not dense on `_working.mp4` yet.
    /// Below the LAN bitrate cutoff, prefer dense fill on `_working.mp4` so contiguous LAN playback grows with export.
    private func shouldUseRemotePassthroughForMidFile(
        byteRange: TimelineByteRange,
        downloader: WebDAVTempFileDownload,
        preferDenseFillOnWorkingForLAN: Bool = false
    ) -> Bool {
        if preferDenseFillOnWorkingForLAN { return false }
        guard byteRange.start > 0 else { return false }
        if isDenseWindowReady(downloader: downloader, byteRange: byteRange) {
            return false
        }
        return !isFullSourceOnDisk(downloader: downloader)
    }

    /// Mid-file export: capped pCloud reads, HTTPS, then dense window + local export session (minute 1 at seek 0 pattern).
    private func exportMidFileSegmentOverRemote(
        downloader: WebDAVTempFileDownload,
        tempURL: URL,
        remoteURL: URL,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        rangeCache: WebDAVRangeCache,
        trustedLength: Int64,
        byteRange: TimelineByteRange,
        videoFormat: CMFormatDescription,
        audioFormat: CMFormatDescription?,
        rangeStart: CMTime,
        rangeDuration: CMTime,
        outputURL: URL,
        isCancelled: @escaping () -> Bool,
        log: @escaping (String) -> Void
    ) async throws -> SegmentPassThroughResult {
        let fileLength = trustedLength > 0 ? trustedLength : 0
        if fileLength >= Self.streamOnlyThresholdBytes, Self.isHEVCFormat(videoFormat) {
            log(
                "Large HEVC mid-file — dense window + capped hybrid export " +
                    "(sparse file:// skipped on \(Self.formatBytes(fileLength)) sources)"
            )
            return try await exportMidFileSegmentViaDenseLocalTemp(
                downloader: downloader,
                tempURL: tempURL,
                    remoteURL: remoteURL,
                    authorizationProvider: authorizationProvider,
                    rangeCache: rangeCache,
                trustedLength: fileLength,
                    byteRange: byteRange,
                rangeStart: rangeStart,
                rangeDuration: rangeDuration,
                outputURL: outputURL,
                videoFormat: videoFormat,
                audioFormat: audioFormat,
                isCancelled: isCancelled,
                priorError: nil,
                log: log
            )
        }
        var lastError: Error?
        log(
            "Mid-file passthrough — capped pCloud reads (head, window \(Self.formatBytes(byteRange.start))–\(Self.formatBytes(byteRange.end)), index tail)"
        )
        let (cappedAsset, cappedLoader) = makeCappedPassthroughAsset(
            remoteURL: remoteURL,
            authorizationProvider: authorizationProvider,
            rangeCache: rangeCache,
            fileLength: fileLength,
            byteRange: byteRange,
            downloader: nil,
            log: log
        )
        defer {
            cappedAsset.resourceLoader.setDelegate(nil, queue: nil)
            cappedLoader.cancelOutstandingWork()
        }
        do {
            _ = try await cappedAsset.loadTracks(withMediaType: .video)
            return try await SegmentPassThroughExporter.exportWindow(
                asset: cappedAsset,
                    videoFormat: videoFormat,
                    audioFormat: audioFormat,
                    rangeStart: rangeStart,
                    rangeDuration: rangeDuration,
                    outputURL: outputURL,
                sourceLabel: "capped pCloud range",
                isCancelled: isCancelled,
                    log: log
                )
        } catch {
            lastError = error
            if Self.shouldTryExportSessionAfterHTTPSManualFailure(error) {
                log(
                    "Capped pCloud manual failed (\(error.localizedDescription)) — trying export session on same asset"
                )
                do {
                    return try await SegmentPassThroughExporter.exportWindowViaExportSession(
                        asset: cappedAsset,
                        rangeStart: rangeStart,
                        rangeDuration: rangeDuration,
                        outputURL: outputURL,
                        sourceLabel: "capped pCloud (export session)",
                        log: log
                    )
                } catch {
                    lastError = error
                }
            } else {
                throw error
            }
            log(
                "Capped pCloud failed (\(lastError?.localizedDescription ?? "unknown")) — trying HTTPS URL passthrough"
            )
        }
        let httpsAsset = makeHTTPSPassthroughAsset(
            remoteURL: remoteURL,
            authorizationProvider: authorizationProvider
        )
        do {
                return try await SegmentPassThroughExporter.exportWindow(
                asset: httpsAsset,
                    videoFormat: videoFormat,
                    audioFormat: audioFormat,
                    rangeStart: rangeStart,
                    rangeDuration: rangeDuration,
                    outputURL: outputURL,
                sourceLabel: "HTTPS range (pCloud)",
                isCancelled: isCancelled,
                    log: log
                )
        } catch {
            lastError = error
            if Self.shouldTryExportSessionAfterHTTPSManualFailure(error) {
                log(
                    "HTTPS manual passthrough failed (\(error.localizedDescription)) — trying AVAssetExportSession"
                )
                do {
                    return try await SegmentPassThroughExporter.exportWindowViaExportSession(
                        asset: httpsAsset,
                        rangeStart: rangeStart,
                        rangeDuration: rangeDuration,
                        outputURL: outputURL,
                        sourceLabel: "HTTPS export session",
                        log: log
                    )
                } catch {
                    lastError = error
                }
            } else {
                throw error
            }
            log(
                "Remote passthrough failed (\(lastError?.localizedDescription ?? "unknown")) — dense-filling \(Self.formatBytes(byteRange.length)) window, then local export session"
            )
        }
        return try await exportMidFileSegmentViaDenseLocalTemp(
            downloader: downloader,
            tempURL: tempURL,
            remoteURL: remoteURL,
            authorizationProvider: authorizationProvider,
            rangeCache: rangeCache,
            trustedLength: fileLength,
            byteRange: byteRange,
            rangeStart: rangeStart,
            rangeDuration: rangeDuration,
            outputURL: outputURL,
            videoFormat: videoFormat,
            audioFormat: audioFormat,
            isCancelled: isCancelled,
            priorError: lastError,
            log: log
        )
    }

    private func exportMidFileSegmentViaDenseLocalTemp(
        downloader: WebDAVTempFileDownload,
        tempURL: URL,
        remoteURL: URL,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        rangeCache: WebDAVRangeCache,
        trustedLength: Int64,
        byteRange: TimelineByteRange,
        rangeStart: CMTime,
        rangeDuration: CMTime,
        outputURL: URL,
        videoFormat: CMFormatDescription,
        audioFormat: CMFormatDescription?,
        isCancelled: @escaping () -> Bool,
        priorError: Error?,
        log: @escaping (String) -> Void
    ) async throws -> SegmentPassThroughResult {
        downloader.pauseBackgroundDownloadForForegroundFill()
        defer { downloader.resumeBackgroundDownloadAfterForegroundFill() }
        try await downloader.ensureFileHeadOnDisk()
        try await downloader.ensureIndexTailOnDisk()
        try await downloader.ensureContiguousRange(
            byteRange,
            bridgeLANGapBeforeWindow: ExportPlaybackState.shared.lanPrefetchHorizonToEOF
        )
        guard downloader.isRangeFilled(byteRange),
              downloader.hasHeadOnDisk(),
              downloader.hasIndexTailOnDisk() else {
            if let priorError { throw priorError }
            throw SegmentExporterError.readerSetupFailed
        }
        log(
            "Dense window on disk — \(Self.formatBytes(byteRange.length)) at \(Self.formatBytes(byteRange.start)) (head + index present)"
        )
        downloader.closeWriteHandleForPassthroughRead(log: log)
        let fileLength = trustedLength > 0 ? trustedLength : downloader.totalLength
        var lastError: Error? = priorError

        if Self.shouldPreferExportSessionForDenseHEVCWindow(
            byteRange: byteRange,
            videoFormat: videoFormat
        ) {
            log(
                "Dense HEVC mid-file window ~\(Self.formatBytes(byteRange.length)) — " +
                    "AVAssetExportSession passthrough (skip manual writer on high-bitrate minutes)"
            )
            return try await exportDenseOnDiskViaExportSession(
                tempURL: tempURL,
                rangeStart: rangeStart,
                rangeDuration: rangeDuration,
                outputURL: outputURL,
                sourceLabel: "dense local temp (export session, mid-file HEVC window)",
                log: log
            )
        }

        log("Trying on-disk passthrough — dense minute on _working.mp4 (file://, no capped hybrid)")
        do {
            let fileAsset = AVURLAsset(
                url: tempURL,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
            )
            return try await SegmentPassThroughExporter.exportWindow(
                asset: fileAsset,
                videoFormat: videoFormat,
                audioFormat: audioFormat,
                rangeStart: rangeStart,
                rangeDuration: rangeDuration,
                outputURL: outputURL,
                sourceLabel: "dense local temp (on-disk after fill)",
                isCancelled: isCancelled,
                log: log
            )
        } catch {
            lastError = error
            if Self.shouldTryExportSessionAfterHTTPSManualFailure(error) {
                log(
                    "On-disk passthrough failed (\(error.localizedDescription)) — AVAssetExportSession on dense temp"
                )
                do {
                    let fileAsset = AVURLAsset(
                        url: tempURL,
                        options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
                    )
                    return try await SegmentPassThroughExporter.exportWindowViaExportSession(
                        asset: fileAsset,
                        rangeStart: rangeStart,
                        rangeDuration: rangeDuration,
                        outputURL: outputURL,
                        sourceLabel: "dense local temp (export session after fill)",
                        log: log
                    )
                } catch {
                    lastError = error
                }
            }
            log(
                "On-disk passthrough failed (\(lastError?.localizedDescription ?? "unknown")) — trying capped hybrid + pCloud for head/index"
            )
        }

        log("Trying capped hybrid — dense window on disk + pCloud for head/index")
        if let boundary = try await tryExportViaCappedAsset(
            remoteURL: remoteURL,
            authorizationProvider: authorizationProvider,
            rangeCache: rangeCache,
            fileLength: fileLength,
            byteRange: byteRange,
            downloader: downloader,
            videoFormat: videoFormat,
            audioFormat: audioFormat,
            rangeStart: rangeStart,
            rangeDuration: rangeDuration,
            outputURL: outputURL,
            sourceLabel: "dense window hybrid (pCloud)",
            isCancelled: isCancelled,
            log: log
        ) {
            return boundary
        }

        log("Capped hybrid failed — trying remote-only capped pCloud reads")
        if let boundary = try await tryExportViaCappedAsset(
            remoteURL: remoteURL,
            authorizationProvider: authorizationProvider,
            rangeCache: rangeCache,
            fileLength: fileLength,
            byteRange: byteRange,
            downloader: nil,
            videoFormat: videoFormat,
            audioFormat: audioFormat,
            rangeStart: rangeStart,
            rangeDuration: rangeDuration,
            outputURL: outputURL,
            sourceLabel: "capped pCloud range",
            isCancelled: isCancelled,
            log: log
        ) {
            return boundary
        }

        if let lastError {
            throw lastError
        }
        throw SegmentExporterError.midFileTempUnreadable(
            mediaTime: formatMediaTimeForLog(rangeStart),
            underlying: "capped hybrid and remote passthrough failed after dense fill"
        )
    }

    @discardableResult
    private func tryExportViaCappedAsset(
        remoteURL: URL,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        rangeCache: WebDAVRangeCache,
        fileLength: Int64,
        byteRange: TimelineByteRange,
        downloader: WebDAVTempFileDownload?,
        videoFormat: CMFormatDescription,
        audioFormat: CMFormatDescription?,
        rangeStart: CMTime,
        rangeDuration: CMTime,
        outputURL: URL,
        sourceLabel: String,
        isCancelled: @escaping () -> Bool,
        log: @escaping (String) -> Void
    ) async throws -> SegmentPassThroughResult? {
        let (asset, loader) = makeCappedPassthroughAsset(
                remoteURL: remoteURL,
            authorizationProvider: authorizationProvider,
            rangeCache: rangeCache,
            fileLength: fileLength,
            byteRange: byteRange,
            downloader: downloader,
                log: log
            )
        defer {
            asset.resourceLoader.setDelegate(nil, queue: nil)
            loader.cancelOutstandingWork()
        }
        _ = try await asset.loadTracks(withMediaType: .video)
        do {
            return try await SegmentPassThroughExporter.exportWindow(
                asset: asset,
                videoFormat: videoFormat,
                audioFormat: audioFormat,
                rangeStart: rangeStart,
                rangeDuration: rangeDuration,
                outputURL: outputURL,
                sourceLabel: sourceLabel,
                isCancelled: isCancelled,
                log: log
            )
        } catch {
            guard Self.shouldTryExportSessionAfterHTTPSManualFailure(error) else { throw error }
            log(
                "\(sourceLabel) manual failed (\(error.localizedDescription)) — export session on same asset"
            )
            do {
                return try await SegmentPassThroughExporter.exportWindowViaExportSession(
                    asset: asset,
                    rangeStart: rangeStart,
                    rangeDuration: rangeDuration,
                    outputURL: outputURL,
                    sourceLabel: "\(sourceLabel) (export session)",
                    log: log
                )
            } catch {
                log("\(sourceLabel) export session failed (\(error.localizedDescription))")
                return nil
            }
        }
    }

    private func makeCappedPassthroughAsset(
        remoteURL: URL,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        rangeCache: WebDAVRangeCache,
        fileLength: Int64,
        byteRange: TimelineByteRange,
        downloader: WebDAVTempFileDownload?,
        log: @escaping (String) -> Void
    ) -> (AVURLAsset, WebDAVResourceLoader) {
        let readPolicy = StreamReadPolicy.forExportWindow(
            fileLength: fileLength,
            window: byteRange,
            indexTailBytes: WebDAVTempFileDownload.indexTailFetchBytes(totalLength: fileLength)
        )
        let loader = WebDAVResourceLoader(
            remoteURL: remoteURL,
            authorizationProvider: authorizationProvider,
            rangeCache: rangeCache,
            trustedContentLength: fileLength > 0 ? fileLength : nil,
            readPolicy: readPolicy,
            localTempURL: downloader?.fileURL,
            readLocalBytes: downloader.map { dl in
                { offset, length in dl.readLocalBytes(offset: offset, length: length) }
            },
            log: log
        )
        let asset = AVURLAsset(
            url: loader.customAssetURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return (asset, loader)
    }

    private static func shouldTryExportSessionAfterHTTPSManualFailure(_ error: Error) -> Bool {
        if case SegmentExporterError.cancelled = error { return false }
        if case SegmentExporterError.readerInterrupted = error { return false }
        return true
    }

    /// LAN: head+index + sequential prefetch; horizon EOF when below Mbps cutoff, else minimal lead on segment export.
    private struct LANWorkingPrefetchPolicy {
        let prepareHeadAndIndex: Bool
        let prefetchHorizonToEOF: Bool
        let waitForBackgroundAtEnd: Bool
        let lanPreloadOnly: Bool
    }

    private static func impliedAverageMbps(fileBytes: Int64, durationSeconds: Double) -> Double {
        guard fileBytes > 0, durationSeconds > 0 else { return 0 }
        let effective = WebDAVTempFileDownload.effectiveDurationSeconds(
            reported: durationSeconds,
            totalBytes: fileBytes
        )
        guard effective > 0 else { return 0 }
        return (Double(fileBytes) * 8.0) / (effective * 1_000_000.0)
    }

    private static func lanWorkingPrefetchPolicy(
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

    private static func lanPrefetchHorizonSeconds(
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
    private func preloadWorkingSourceForLANPlayback(
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

    private func ensureSeekZeroRemainderOnDiskIfBeneficial(
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
    private func shouldUseOnDiskFileURLForPassthrough(
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

    private func prepareMidFileTempForReader(
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

    private func makeHTTPSPassthroughAsset(
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
    private func resolvePassthroughReadAsset(
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

    static func isWriterSampleRejection(_ error: Error) -> Bool {
        isRetriablePassthroughWriterFailure(error)
    }

    static func isUnsupportedAssetURLError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorUnsupportedURL { return true }
        return error.localizedDescription.lowercased().contains("unsupported url")
    }

    static func isHybridReaderOpenFailure(_ error: Error) -> Bool {
        let underlying: Error = {
            if case SegmentExporterError.readerFailed(let err) = error { return err }
            return error
        }()
        let text = underlying.localizedDescription.lowercased()
        if text.contains("operation stopped") || text.contains("cannot open") {
            return true
        }
        let ns = underlying as NSError
        return ns.domain == AVFoundationErrorDomain
    }

    static func isRetriablePassthroughWriterFailure(_ error: Error) -> Bool {
        guard case SegmentExporterError.writerFailed(let underlying) = error else { return false }
        let ns = underlying as NSError
        if ns.domain == AVFoundationErrorDomain {
            switch ns.code {
            case -11800, -11847:
                return true
            default:
                break
            }
        }
        let text = underlying.localizedDescription.lowercased()
        return text.contains("could not be completed") || text.contains("operation interrupted")
    }

    static func isAudioWriterRejection(_ error: Error, track: SegmentTrackKind) -> Bool {
        track == .audio && isRetriablePassthroughWriterFailure(error)
    }

    private func formatSeekMs(_ ms: Int64) -> String {
        ExportTimelineLog.wallClock(seconds: Double(max(0, ms)) / 1000.0)
    }

    private func formatMediaTimeForLog(_ time: CMTime) -> String {
        let seconds = CMTimeGetSeconds(time)
        let min = Int(seconds) / 60
        let sec = Int(seconds) % 60
        return String(format: "%d:%02d", min, sec)
    }

    private static let midFilePrefetchThresholdBytes: Int64 = 32 * 1024 * 1024
    /// High-bitrate HEVC minute windows (e.g. ~700 MB/min) stall manual `AVAssetWriter`; use export session on disk.
    private static let denseHEVCExportSessionWindowBytes: Int64 = 256 * 1024 * 1024

    private static func shouldPreferExportSessionForDenseHEVCWindow(
        byteRange: TimelineByteRange,
        videoFormat: CMFormatDescription
    ) -> Bool {
        isHEVCFormat(videoFormat) && byteRange.length >= denseHEVCExportSessionWindowBytes
    }

    private func exportDenseOnDiskViaExportSession(
        tempURL: URL,
        rangeStart: CMTime,
        rangeDuration: CMTime,
        outputURL: URL,
        sourceLabel: String,
        log: @escaping (String) -> Void
    ) async throws -> SegmentPassThroughResult {
        let fileAsset = AVURLAsset(
            url: tempURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        return try await SegmentPassThroughExporter.exportWindowViaExportSession(
            asset: fileAsset,
            rangeStart: rangeStart,
            rangeDuration: rangeDuration,
            outputURL: outputURL,
            sourceLabel: sourceLabel,
            log: log
        )
    }

    private static func isHEVCFormat(_ format: CMFormatDescription) -> Bool {
        CodecSupport.isHEVCVideo(CMFormatDescriptionGetMediaSubType(format))
    }
    /// At seek 0, dense-fill bytes after the minute window so `file://` passthrough does not read zero-filled mdat.
    private static let seekZeroDenseEntireFileMaxBytes: Int64 = 1024 * 1024 * 1024
    private static let seekZeroDenseTailMaxBytes: Int64 = 256 * 1024 * 1024

    private static func sourceQualifiesForPCloudHLSTranscode(
        fileBytes: Int64,
        durationSeconds: Double
    ) -> Bool {
        guard fileBytes > 0, durationSeconds > 0 else { return false }
        return impliedAverageMbps(fileBytes: fileBytes, durationSeconds: durationSeconds)
            > PCloudHLSLink.transcodeMinSourceMbps
    }

    private static func shouldAttemptPCloudHLSFallback(
        error: Error,
        containerFormat: MediaContainerFormat,
        fileBytes: Int64
    ) -> Bool {
        guard fileBytes > 0 else { return false }
        guard let exportError = error as? SegmentExporterError else { return false }
        switch exportError {
        case .containerProbeFailed:
            break
        case .noVideoTrack:
            guard !containerFormat.probesSparseTempAsMP4 else { return false }
        default:
            return false
        }
        // Pre-check: file must be large enough that a 45 min movie could still exceed 2.5 Mbps.
        let heuristicSeconds = 45.0 * 60.0
        return impliedAverageMbps(fileBytes: fileBytes, durationSeconds: heuristicSeconds)
            > PCloudHLSLink.transcodeMinSourceMbps
    }

    /// Per-minute failsafe: keep dense-filling the sparse temp and serving it on LAN; do not abort the whole export.
    private static func shouldSkipMinuteAndContinue(after error: Error) -> Bool {
        if let exportError = error as? SegmentExporterError {
            switch exportError {
            case .cancelled, .paused, .readerInterrupted, .seekPastEnd, .noVideoTrack,
                 .containerProbeFailed, .unsupportedCodec, .missingFormatDescription, .insufficientDiskSpace:
                return false
            case .readerSetupFailed, .readerFailed, .writerSetupFailed, .writerFailed,
                 .writerBackpressure, .writerAudioStall, .noKeyframeInWindow,
                 .timelineByteWindowMismatch, .segmentOutputTooSmall, .midFileTempUnreadable:
                return true
            }
        }
        return true
    }

    private static func shouldStreamFallback(after error: Error) -> Bool {
        if let exportError = error as? SegmentExporterError {
            switch exportError {
            case .readerSetupFailed, .segmentOutputTooSmall:
                return true
            case .noKeyframeInWindow, .timelineByteWindowMismatch:
                return false
            case .readerFailed(let underlying):
                return isSparseContainerOpenFailure(underlying)
            case .writerFailed, .writerBackpressure:
                return true
            case .cancelled, .paused, .readerInterrupted, .seekPastEnd, .noVideoTrack, .containerProbeFailed,
                 .unsupportedCodec, .missingFormatDescription, .writerSetupFailed, .writerAudioStall,
                 .insufficientDiskSpace, .midFileTempUnreadable:
                return false
            }
        }
        return isSparseContainerOpenFailure(error)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", Double(bytes) / 1_073_741_824.0)
        }
        if bytes >= 1024 * 1024 {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
        }
        return "\(bytes) B"
    }

    /// DLNA clients cannot refresh a file during playback — publish each slot only on its wall-clock minute.
    private func waitForDLNAPublishSchedule(
        minuteIndex: Int,
        wallOrigin: CFAbsoluteTime,
        slot: Int,
        log: (String) -> Void
    ) async {
        let publishAt = wallOrigin + Double(minuteIndex) * Self.segmentDurationSeconds
        let delay = publishAt - CFAbsoluteTimeGetCurrent()
        guard delay > 0.05 else { return }

        let slotName = ExportPaths.segmentURL(index: slot).lastPathComponent
        log("Holding \(slotName) — \(Int(delay))s until wall-clock minute \(minuteIndex) (download may be ahead)")
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    private func openStreamingAsset(
        inputURL: URL,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        rangeCache: WebDAVRangeCache,
        logHandler: @escaping (String) -> Void
    ) async throws -> AVURLAsset {
        let loader = WebDAVResourceLoader(
            remoteURL: inputURL,
            authorizationProvider: authorizationProvider,
            rangeCache: rangeCache,
            trustedContentLength: rangeCache.contentLengthValue(),
            log: logHandler
        )
        retainedWebDAVLoader = loader
        let asset = AVURLAsset(
            url: loader.customAssetURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        retainedAsset = asset
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return asset
    }

    private func probeExportMetadata(
        containerFormat: MediaContainerFormat,
        fileURL: URL,
        inputURL: URL,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        rangeCache: WebDAVRangeCache,
        log: @escaping (String) -> Void
    ) async throws -> (Double, CMFormatDescription, CMFormatDescription?) {
        if containerFormat.probesSparseTempAsMP4 {
            return try await probeMetadataPreferLocal(
                fileURL: fileURL,
                inputURL: inputURL,
                authorizationProvider: authorizationProvider,
                rangeCache: rangeCache,
                log: log
            )
        }
        log(
            "Probing \(containerFormat.displayName) via pCloud — sparse _working.mp4 temp is not this container; " +
                "using source filename for AVFoundation…"
        )
        return try await probeStreamMetadataOnly(
            inputURL: inputURL,
            authorizationProvider: authorizationProvider,
            rangeCache: rangeCache,
            containerFormat: containerFormat,
            log: log
        )
    }

    private func probeMetadataPreferLocal(
        fileURL: URL,
        inputURL: URL,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        rangeCache: WebDAVRangeCache,
        log: @escaping (String) -> Void
    ) async throws -> (Double, CMFormatDescription, CMFormatDescription?) {
        log("Probing duration/codecs from temp file (prefetch head + MP4 index at EOF)…")
        do {
            return try await probeLocalMetadata(fileURL: fileURL, log: log)
        } catch SegmentExporterError.noVideoTrack {
            log("Local temp had no video track — probing via pCloud (prefetch cache, no full download)")
        }
        return try await probeStreamMetadataOnly(
            inputURL: inputURL,
            authorizationProvider: authorizationProvider,
            rangeCache: rangeCache,
            containerFormat: .mp4,
            log: log
        )
    }

    private func probeStreamMetadataOnly(
        inputURL: URL,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        rangeCache: WebDAVRangeCache,
        containerFormat: MediaContainerFormat,
        log: @escaping (String) -> Void
    ) async throws -> (Double, CMFormatDescription, CMFormatDescription?) {
        let streamingAsset = try await openStreamingAsset(
            inputURL: inputURL,
            authorizationProvider: authorizationProvider,
            rangeCache: rangeCache,
            logHandler: log
        )
        defer {
            retainedWebDAVLoader?.cancelOutstandingWork()
            retainedAsset?.resourceLoader.setDelegate(nil, queue: nil)
            retainedWebDAVLoader = nil
            retainedAsset = nil
        }
        do {
            return try await probeStreamMetadata(asset: streamingAsset, log: log)
        } catch SegmentExporterError.readerSetupFailed {
            throw SegmentExporterError.containerProbeFailed(containerFormat)
        }
    }

    private func probeLocalMetadata(
        fileURL: URL,
        log: @escaping (String) -> Void
    ) async throws -> (Double, CMFormatDescription, CMFormatDescription?) {
        let asset = AVURLAsset(
            url: fileURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        var lastLog = CFAbsoluteTimeGetCurrent()
        for attempt in 1 ... 60 {
            if let videoTrack = try? await firstVideoTrack(in: asset) {
                let probed = try await probeMediaMetadata(asset: asset, videoTrack: videoTrack, log: log)
                log("Opened for export (local temp index, attempt \(attempt))")
                return probed
            }
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastLog >= 10 {
                lastLog = now
                log("Waiting for video track in temp file (head + index)…")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw SegmentExporterError.noVideoTrack
    }

    private func firstVideoTrack(in asset: AVURLAsset) async throws -> AVAssetTrack? {
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            return track
        }
        let tracks = try await asset.load(.tracks)
        return tracks.first { $0.mediaType == .video }
    }

    /// Low-disk fallback: retry track load over pCloud (never requires full-file `isPlayable`).
    private func probeStreamMetadata(
        asset: AVURLAsset,
        log: @escaping (String) -> Void
    ) async throws -> (Double, CMFormatDescription, CMFormatDescription?) {
        var lastLog = CFAbsoluteTimeGetCurrent()
        for attempt in 1 ... 120 {
            if let videoTrack = try? await firstVideoTrack(in: asset) {
                let probed = try await probeMediaMetadata(asset: asset, videoTrack: videoTrack, log: log)
                log("Opened for export (pCloud index, attempt \(attempt))")
                return probed
            }
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastLog >= 15 {
                lastLog = now
                log("Waiting for video track via pCloud (prefetch index)…")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw SegmentExporterError.readerSetupFailed
    }

    private func probeMediaMetadata(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        log: @escaping (String) -> Void
    ) async throws -> (Double, CMFormatDescription, CMFormatDescription?) {
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let rawVideoFormat = try await videoFormatDescription(from: videoTrack)
        guard CodecSupport.canPassthroughToMP4(rawVideoFormat) else {
            throw SegmentExporterError.unsupportedCodec(CodecSupport.fourCCString(rawVideoFormat))
        }
        let videoFormat = CodecSupport.normalizedForMP4Writer(rawVideoFormat)
        if CMFormatDescriptionGetMediaSubType(rawVideoFormat) != CMFormatDescriptionGetMediaSubType(videoFormat) {
            log(
                "MP4 passthrough: writer uses \(CodecSupport.fourCCString(videoFormat)) (source track \(CodecSupport.fourCCString(rawVideoFormat)))"
            )
        }
        var audioFormat: CMFormatDescription?
        if let audioTrack {
            let fmt = try await audioFormatDescription(from: audioTrack)
            guard CodecSupport.canPassthroughAudio(fmt) else {
                throw SegmentExporterError.unsupportedCodec(CodecSupport.fourCCString(fmt))
            }
            audioFormat = fmt
        }
        let duration = try await asset.load(.duration)
        var durationSeconds = CMTimeGetSeconds(duration)
        if !durationSeconds.isFinite || durationSeconds <= 0 {
            log("Duration not available from index — export may mis-schedule segments")
            durationSeconds = 1
        }
        return (durationSeconds, videoFormat, audioFormat)
    }

    private func releaseStreamingProbe(log: (String) -> Void) {
        guard retainedAsset != nil || retainedWebDAVLoader != nil else { return }
        retainedWebDAVLoader?.cancelOutstandingWork()
        retainedAsset?.resourceLoader.setDelegate(nil, queue: nil)
        retainedWebDAVLoader = nil
        retainedAsset = nil
        log("Released codec probe — export uses sparse temp + dense fill")
    }

    private func videoFormatDescription(from track: AVAssetTrack) async throws -> CMFormatDescription {
        let formats = try await track.load(.formatDescriptions)
        guard let first = formats.first else {
            throw SegmentExporterError.missingFormatDescription
        }
        return first
    }

    private func audioFormatDescription(from track: AVAssetTrack) async throws -> CMFormatDescription {
        let formats = try await track.load(.formatDescriptions)
        guard let first = formats.first else {
            throw SegmentExporterError.missingFormatDescription
        }
        return first
    }
}

// MARK: - Writer context

enum SegmentTrackKind {
    case video
    case audio
}

final class SegmentWriterContext {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private var audioAbandoned = false

    init(
        outputURL: URL,
        videoFormat: CMFormatDescription,
        audioFormat: CMFormatDescription?,
        videoTransform: CGAffineTransform = .identity,
        realTime: Bool = true
    ) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: videoFormat
        )
        videoInput.expectsMediaDataInRealTime = realTime
        if videoTransform != .identity {
            videoInput.transform = videoTransform
        }

        if let audioFormat {
            audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: audioFormat
            )
            audioInput?.expectsMediaDataInRealTime = realTime
        } else {
            audioInput = nil
        }

        guard writer.canAdd(videoInput) else {
            throw SegmentExporterError.writerSetupFailed
        }
        writer.add(videoInput)

        if let audioInput {
            guard writer.canAdd(audioInput) else {
                throw SegmentExporterError.writerSetupFailed
            }
            writer.add(audioInput)
        }
    }

    func start(at sourceTime: CMTime) {
        writer.startWriting()
        writer.startSession(atSourceTime: sourceTime)
    }

    /// Release a failed writer so the output path can be deleted and retried (-11847 if left in `.writing`).
    func cancelIfNeeded() {
        guard writer.status == .writing else { return }
        videoInput.markAsFinished()
        writer.cancelWriting()
    }

    private static let writerReadyTimeoutSeconds: Double = 30
    private static let writerReadyLogIntervalSeconds: Double = 10

    /// Stop accepting audio samples; writer keeps video track open.
    func abandonAudio() {
        guard let audioInput, !audioAbandoned else { return }
        audioAbandoned = true
        audioInput.markAsFinished()
    }

    func append(
        _ sample: CMSampleBuffer,
        track: SegmentTrackKind,
        isCancelled: (() -> Bool)? = nil,
        log: ((String) -> Void)? = nil
    ) async throws {
        let input: AVAssetWriterInput
        switch track {
        case .video: input = videoInput
        case .audio:
            guard let audioInput, !audioAbandoned else { return }
            input = audioInput
        }

        let waitStart = CFAbsoluteTimeGetCurrent()
        var lastWaitLog = waitStart
        while !input.isReadyForMoreMediaData {
            if isCancelled?() == true {
                throw SegmentExporterError.cancelled
            }
            let now = CFAbsoluteTimeGetCurrent()
            if now - waitStart >= Self.writerReadyTimeoutSeconds {
                if track == .audio {
                    throw SegmentExporterError.writerAudioStall
                }
                throw SegmentExporterError.writerBackpressure
            }
            if now - lastWaitLog >= Self.writerReadyLogIntervalSeconds {
                lastWaitLog = now
                log?(
                    String(
                        format: "Writer waiting for ready — %.0fs (\(track))",
                        now - waitStart
                    )
                )
            }
            await Task.yield()
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        guard input.append(sample) else {
            let err = writer.error ?? NSError(domain: "SegmentWriter", code: -1)
            throw SegmentExporterError.writerFailed(err)
        }
    }

    func finish() async throws {
        videoInput.markAsFinished()
        if !audioAbandoned {
        audioInput?.markAsFinished()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        if writer.status == .failed {
            throw writer.error.map { SegmentExporterError.writerFailed($0) }
                ?? SegmentExporterError.writerSetupFailed
        }
    }
}

// MARK: - Codec support

enum CodecSupport {
    /// MP4 brands for HEVC; AVFoundation writer expects `hvc1`, sources often report `hev1`.
    private static let hev1Subtype: FourCharCode = fourCC("hev1")

    static func isHEVCVideo(_ codec: FourCharCode) -> Bool {
        codec == kCMVideoCodecType_HEVC || codec == hev1Subtype
    }

    /// Re-tag `hev1` → `hvc1` so `AVAssetWriter` accepts the same bitstream/hvcc extradata.
    static func normalizedForMP4Writer(_ format: CMFormatDescription) -> CMFormatDescription {
        let codec = CMFormatDescriptionGetMediaSubType(format)
        guard codec == hev1Subtype else { return format }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let extensions = CMFormatDescriptionGetExtensions(format) as CFDictionary?
        var out: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: dimensions.width,
            height: dimensions.height,
            extensions: extensions,
            formatDescriptionOut: &out
        )
        guard status == noErr, let out else { return format }
        return out
    }

    static func isAV1Video(_ codec: FourCharCode) -> Bool {
        if #available(iOS 16.0, *) {
            if codec == kCMVideoCodecType_AV1 {
                return true
            }
        }
        return codec == fourCC("av01") || codec == fourCC("dav1")
    }

    /// H.264 / HEVC only — AV1 probes as a track but passthrough export never yields samples on sparse WebDAV temp.
    static func canPassthroughToMP4(_ format: CMFormatDescription) -> Bool {
        let codec = CMFormatDescriptionGetMediaSubType(format)
        if isAV1Video(codec) {
            return false
        }
        return codec == kCMVideoCodecType_H264 || isHEVCVideo(codec)
    }

    static func canPassthroughAudio(_ format: CMFormatDescription) -> Bool {
        let codec = CMFormatDescriptionGetMediaSubType(format)
        return codec == kAudioFormatMPEG4AAC || codec == fourCC("mp4a")
    }

    static func fourCCString(_ format: CMFormatDescription) -> String {
        let codec = CMFormatDescriptionGetMediaSubType(format)
        let chars: [UInt8] = [
            UInt8((codec >> 24) & 0xff),
            UInt8((codec >> 16) & 0xff),
            UInt8((codec >> 8) & 0xff),
            UInt8(codec & 0xff),
        ]
        return String(bytes: chars, encoding: .ascii) ?? String(format: "0x%08x", codec)
    }

    private static func fourCC(_ string: String) -> FourCharCode {
        var value: FourCharCode = 0
        for byte in string.utf8.prefix(4) {
            value = (value << 8) + FourCharCode(byte)
        }
        return value
    }
}

enum SegmentExporterError: LocalizedError {
    case cancelled
    case paused
    case readerInterrupted
    case seekPastEnd
    case noVideoTrack
    case containerProbeFailed(MediaContainerFormat)
    case unsupportedCodec(String)
    case missingFormatDescription
    case readerSetupFailed
    case readerFailed(Error)
    case writerSetupFailed
    case writerFailed(Error)
    case writerBackpressure
    case writerAudioStall
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case noKeyframeInWindow
    case timelineByteWindowMismatch(mediaTime: String)
    case segmentOutputTooSmall(Int64)
    case midFileTempUnreadable(mediaTime: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Export cancelled."
        case .paused:
            return "Export paused — tap Start export to continue from the checkpoint."
        case .readerInterrupted:
            return "pCloud read was interrupted (app did not stop). Try seek 0 min, keep app open, or use Wi‑Fi."
        case .seekPastEnd:
            return "Start position is at or past the end of the file."
        case .noVideoTrack:
            return "No video track found in this file."
        case .containerProbeFailed(let container):
            switch container {
            case .asf:
                return "Could not open this WMV/ASF file from pCloud on this device. Re-encode to MP4 or MKV with H.264 or HEVC (hvc1/hev1) and AAC."
            case .mpegTransportStream:
                return "Could not open this MPEG-TS (.ts) file from pCloud. Remux to MP4 or MKV with H.264 or HEVC and AAC, then export again."
            default:
                return "Could not open this \(container.displayName) file from pCloud. Use MP4/MKV with H.264 or HEVC (hvc1/hev1) and AAC for 60s segment export."
            }
        case .unsupportedCodec(let fourCC):
            switch fourCC.lowercased() {
            case "av01", "dav1":
                return "AV1 (\(fourCC)) is not supported for 60s MP4 segments. Re-encode the source to HEVC (hvc1/hev1) or H.264 with AAC."
            case "wmv3", "wvc1", "wmv2", "wmv1":
                return "WMV video (\(fourCC)) cannot be stream-copied to MP4 segments on iOS. Re-encode to H.264 or HEVC (hvc1/hev1) with AAC in MP4 or MKV."
            default:
                return "Codec ‘\(fourCC)’ cannot be stream-copied to MP4 on this device. Use H.264 or HEVC (hvc1/hev1) with AAC."
            }
        case .missingFormatDescription:
            return "Could not read track format from the file."
        case .readerSetupFailed:
            return "Could not read or export this minute from the temp copy. Keep the app open on Wi‑Fi until “Window on disk” appears, or try seek 0 min."
        case .readerFailed(let error):
            if isSparseContainerOpenFailure(error) {
                return """
                Could not read this minute from the temp copy (incomplete sparse MP4). \
                The app retries that minute from pCloud automatically; if this persists, try seek 0 min on Wi‑Fi.
                """
            }
            return "Read failed: \(error.localizedDescription)"
        case .writerSetupFailed:
            return "Could not start writing segment MP4."
        case .writerFailed(let error):
            let ns = error as NSError
            if ns.domain == AVFoundationErrorDomain {
                return "Write failed (AVFoundation \(ns.code)): \(error.localizedDescription)"
            }
            return "Write failed: \(error.localizedDescription)"
        case .writerBackpressure:
            return """
            Video writer not ready in time — dense-fill this minute and retry. Try seek 0 min if it keeps failing.
            """
        case .writerAudioStall:
            return "Audio writer stalled (internal — should fall back to video-only)."
        case .midFileTempUnreadable(let mediaTime, let underlying):
            return """
            Could not export the \(mediaTime) minute (\(underlying)). \
            Try seek 0 min for the first segment, or stay on cellular/Wi‑Fi until the minute is dense on disk.
            """
        case .insufficientDiskSpace(let needed, let available):
            let needMB = needed / (1024 * 1024)
            let haveMB = available / (1024 * 1024)
            return "Need ~\(needMB) MB free on iPhone storage; only ~\(haveMB) MB available. Free space in Settings → General → iPhone Storage."
        case .noKeyframeInWindow:
            return "Could not start segment on a keyframe — wait for more download or use seek 0 min."
        case .timelineByteWindowMismatch(let mediaTime):
            return """
            Dense bytes for \(mediaTime) did not contain that minute’s video (linear file offset estimate). \
            Try seek 0 min for the first segment, then later minutes, or wait for a larger dense download on Wi‑Fi/cellular.
            """
        case .segmentOutputTooSmall(let bytes):
            if bytes == 0 {
                return "Segment window was incomplete — wait for more temp download (or seek 0 min on Wi‑Fi)."
            }
            return "Segment file too small (\(bytes) B) — source window was incomplete; try again after more temp download."
        }
    }
}

private func isSparseContainerOpenFailure(_ error: Error) -> Bool {
    let text = error.localizedDescription.lowercased()
    if text.contains("cannot open") { return true }
    if text.contains("operation could not be completed") { return true }
    if text.contains("file couldn't be opened") { return true }
    if text.contains("file could not be opened") { return true }
    let ns = error as NSError
    if ns.domain == AVFoundationErrorDomain, ns.code == -11828 { return true }
    if ns.domain == AVFoundationErrorDomain, ns.code == -11829 { return true }
    return false
}
