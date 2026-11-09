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

    let cancelLock = NSLock()
    var isCancelled = false
    var retainedWebDAVLoader: WebDAVResourceLoader?
    var retainedAsset: AVURLAsset?
    var tempDownload: WebDAVTempFileDownload?

    func cancel() {
        cancelLock.lock()
        isCancelled = true
        cancelLock.unlock()
    }

    func checkCancelled() throws {
        cancelLock.lock()
        let cancelled = isCancelled
        cancelLock.unlock()
        if cancelled { throw SegmentExporterError.cancelled }
    }

    func mapReaderFailure(_ error: Error?) -> SegmentExporterError? {
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
        let isExternalHTTP = item.isExternalHTTPMedia(credentials: credentials)
        logHandler(
            isExternalHTTP
                ? "Prefetching external HTTP(S) (file size)…"
                : vanillaOnlyContainer
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
            headOnly: vanillaOnlyContainer || isExternalHTTP,
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

        if isExternalHTTP {
            logHandler(
                "External HTTP(S) — same export pipeline as browse Export " +
                    "(vanilla download → segments; no sparse probe / pCloud HLS)"
            )
            return try await attemptRecoveryExport(
                probeError: SegmentExporterError.containerProbeFailed(containerFormat),
                item: item,
                inputURL: inputURL,
                credentials: credentials,
                containerFormat: containerFormat,
                fileBytes: fileSize > 0 ? fileSize : (item.contentLength ?? 0),
                seekMs: seekMs,
                continueLANExport: continueLANExport,
                resumeCursorMs: resumeCursorMs,
                authorizationProvider: authorizationProvider,
                rangeCache: rangeCache,
                isCancelled: cancelCheck,
                logHandler: logHandler,
                onMediaProgress: onMediaProgress,
                allowPCloudHLSFallback: false
            )
        }

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
}
