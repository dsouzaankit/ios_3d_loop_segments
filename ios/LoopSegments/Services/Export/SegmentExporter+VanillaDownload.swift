import AVFoundation
import CoreMedia
import Foundation

/// Full-file (vanilla) download export and the LAN preload-only mode.
extension SegmentExporter {
    /// Dense full-file download + segment export from local copy (not sparse `_working.mp4`).
    func runVanillaDownloadExport(
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
        var effectiveBytes = fileBytes > 0 ? fileBytes : (item.contentLength ?? 0)
        var vanillaAlreadyFilled = false
        if effectiveBytes <= 0 {
            logHandler("Unknown Content-Length — full GET into _vanilla_download.* before segments")
            try await VanillaWebDAVDownload.downloadFullFile(
                remoteURL: inputURL,
                destinationURL: downloadURL,
                fileKey: item.fileKey,
                sourceHref: item.href,
                totalLength: 0,
                authorizationProvider: authorizationProvider,
                isCancelled: isCancelled,
                log: logHandler,
                onDownloadedBytes: nil
            )
            effectiveBytes = (try? FileManager.default.attributesOfItem(atPath: downloadURL.path)[.size] as? NSNumber)?
                .int64Value ?? 0
            guard effectiveBytes > 0 else { throw WebDAVResourceLoaderError.missingContentLength }
            rangeCache.storeContentLength(effectiveBytes)
            vanillaAlreadyFilled = true
        }

        guard effectiveBytes > 0 else { throw WebDAVResourceLoaderError.missingContentLength }

        let downloadRel = ExportPaths.pathRelativeToExports(downloadURL)
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

        if !vanillaAlreadyFilled {
            try await VanillaWebDAVDownload.downloadFullFile(
                remoteURL: inputURL,
                destinationURL: downloadURL,
                fileKey: item.fileKey,
                sourceHref: item.href,
                totalLength: effectiveBytes,
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
        } else {
            ExportPlaybackState.shared.updateVanillaDownloadProgress(downloadedBytes: effectiveBytes)
        }

        if !containerFormat.supportsIOSegmentExport {
            return try await finishVanillaWithout60sSegments(
                downloadURL: downloadURL,
                downloadRel: downloadRel,
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
                fileURL: downloadURL,
                log: logHandler
            )
        } catch {
            let downloadRel = ExportPaths.pathRelativeToExports(downloadURL)
            ExportPlaybackState.shared.beginVanillaExport(
                downloadRelativePath: downloadRel,
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
            "Publishing ~\(Int(Self.segmentDurationSeconds))s segments from \(downloadURL.lastPathComponent) — " +
                "op_00/op_01; LAN full file at \(downloadRel)"
        )

        let localAsset = AVURLAsset(
            url: downloadURL,
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
    func runLANPreloadOnly(
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
}
