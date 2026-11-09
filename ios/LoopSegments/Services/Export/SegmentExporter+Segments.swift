import AVFoundation
import CoreMedia
import Foundation

/// Disk checks and per-minute segment export (temp file, stream, mid-file, capped asset).
extension SegmentExporter {
    /// Files above this or that do not fit on disk are exported by range reads (no full temp copy).
    static let streamOnlyThresholdBytes: Int64 = 1_500_000_000
    static let diskMarginBytes: Int64 = 384 * 1024 * 1024
    static let streamingWorkingSetBytes: Int64 = 700 * 1024 * 1024

    func publishValidatedSegment(
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

    static func hasDiskForFullCopy(fileBytes: Int64) -> Bool {
        guard let free = freeDiskBytes() else { return true }
        return free >= fileBytes + diskMarginBytes
    }

    static func freeDiskBytes() -> Int64? {
        let path = ExportPaths.exportDiskSpaceCheckDirectory.path
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let freeNumber = attrs[.systemFreeSize] as? NSNumber else {
            return nil
        }
        return freeNumber.int64Value
    }

    static func ensureExportDiskSpace(fileBytes: Int64, lanPrefetchToEOF: Bool = false) throws {
        guard let free = freeDiskBytes() else { return }
        let budget = lanPrefetchToEOF
            ? max(fileBytes, 0)
            : min(max(fileBytes, 0), streamingWorkingSetBytes)
        let needed = budget + diskMarginBytes
        guard free >= needed else {
            throw SegmentExporterError.insufficientDiskSpace(needed: needed, available: max(0, free))
        }
    }

    func isDenseWindowReady(
        downloader: WebDAVTempFileDownload,
        byteRange: TimelineByteRange
    ) -> Bool {
        downloader.hasHeadOnDisk()
            && downloader.hasIndexTailOnDisk()
            && downloader.isByteRangeFullyOnDisk(byteRange)
    }

    func exportSegmentFromTempOrStream(
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

    func isFullSourceOnDisk(downloader: WebDAVTempFileDownload) -> Bool {
        let length = downloader.totalLength
        guard length > 0 else { return false }
        return downloader.isByteRangeFullyOnDisk(TimelineByteRange(start: 0, end: length))
    }

    /// Mid-file on a sparse temp: hybrid/`file://` often fails — use pCloud only when the minute window is not dense on `_working.mp4` yet.
    /// Below the LAN bitrate cutoff, prefer dense fill on `_working.mp4` so contiguous LAN playback grows with export.
    func shouldUseRemotePassthroughForMidFile(
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
    func exportMidFileSegmentOverRemote(
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

    func exportMidFileSegmentViaDenseLocalTemp(
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
    func tryExportViaCappedAsset(
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

    func makeCappedPassthroughAsset(
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

    static func shouldTryExportSessionAfterHTTPSManualFailure(_ error: Error) -> Bool {
        if case SegmentExporterError.cancelled = error { return false }
        if case SegmentExporterError.readerInterrupted = error { return false }
        return true
    }
}
