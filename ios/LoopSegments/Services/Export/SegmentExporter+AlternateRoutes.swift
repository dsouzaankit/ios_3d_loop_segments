import AVFoundation
import CoreMedia
import Foundation

/// pCloud HLS fallback, vanilla duration probes and recovery exports.
extension SegmentExporter {
    /// pCloud `gethlslink` → segments + progressive `_working_pcloud_transcode.mp4` (not sparse WebDAV).
    func runPCloudHLSExport(
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

    func finishVanillaWithout60sSegments(
        downloadURL: URL,
        downloadRel: String,
        seekMs: Int64,
        effectiveBytes: Int64,
        reason: String,
        logHandler: @escaping (String) -> Void
    ) async throws -> SegmentExportResult {
        let durationSeconds = (try? await probeLocalDurationSeconds(fileURL: downloadURL, log: logHandler)) ?? 0
        let seekSeconds = Double(seekMs) / 1000.0
        ExportPlaybackState.shared.beginVanillaExport(
            downloadRelativePath: downloadRel,
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

    static let vanillaDurationProbeByteThresholds: [Int64] = [
        4 * 1024 * 1024,
        16 * 1024 * 1024,
        64 * 1024 * 1024,
        256 * 1024 * 1024,
    ]

    struct VanillaDurationResolve {
        let seconds: Double
        let isEstimated: Bool
    }

    /// Size-only guess before index is readable — scales assumed Mbps with file size (avoids 10 Mbps on ~300 MB WMV).
    static func vanillaDurationFallbackAssumedMbps(fileBytes: Int64) -> Double {
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

    func persistVanillaSourceDuration(seconds: Double, item: WebDAVItem) {
        guard seconds.isFinite, seconds > 0 else { return }
        let ms = Int64(seconds * 1000)
        Task { @MainActor in
            ResumeStore.shared.setSourceDurationMs(ms, for: item)
        }
    }

    static func estimatedVanillaDurationFromFileBytes(_ fileBytes: Int64) -> (seconds: Double, assumedMbps: Double) {
        guard fileBytes > 0 else { return (0, 10) }
        let assumedMbps = vanillaDurationFallbackAssumedMbps(fileBytes: fileBytes)
        let seconds = Double(fileBytes) * 8.0 / (assumedMbps * 1_000_000.0)
        return (seconds, assumedMbps)
    }

    static func logVanillaDurationSizeEstimate(
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

    func probeRemoteDurationSeconds(
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

    func probeAssetDurationSeconds(
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

    func resolveVanillaDurationSeconds(
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

    func probeLocalDurationSeconds(
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
    func abandonSparseWorkingForRecovery(logHandler: @escaping (String) -> Void) {
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

    static func canReuseSparseWorkingForResume(
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

    func attemptRecoveryExport(
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
        onMediaProgress: (@Sendable (Int64) -> Void)?,
        allowPCloudHLSFallback: Bool = true
    ) async throws -> SegmentExportResult {
        abandonSparseWorkingForRecovery(logHandler: logHandler)
        var vanillaFailure: Error?
        if VanillaWebDAVDownload.isBackupEnabled {
            logHandler(
                item.isExternalHTTPMedia(credentials: credentials)
                    ? "External HTTP(S) — vanilla download (full file → segments; same as browse Export)"
                    : "WebDAV probe failed for \(containerFormat.displayName) — vanilla WebDAV download first " +
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
        if allowPCloudHLSFallback,
           Self.shouldAttemptPCloudHLSFallback(
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
    func finishRecoveryWithPartialVanillaIfPossible(
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
        let (estimatedDuration, _) = Self.estimatedVanillaDurationFromFileBytes(onDisk)
        let seekSeconds = Double(seekMs) / 1000.0

        ExportPlaybackState.shared.beginVanillaExport(
            downloadRelativePath: downloadRel,
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

    static func formatExportBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
        }
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        }
        return "\(bytes) B"
    }
}
