import AVFoundation
import CoreMedia
import Foundation

struct SegmentExportResult {
    let lastMediaTimeMs: Int64
    let reachedEnd: Bool
}

/// Stream-copy export to one rotating 60s MP4 on the phone (AVFoundation, WebDAV input).
final class SegmentExporter {
    static let segmentDurationSeconds = 60.0
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
        inputURL: URL,
        catalogContentLength: Int64? = nil,
        seekMs: Int64,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        logHandler: @escaping (String) -> Void
    ) async throws -> SegmentExportResult {
        cancelLock.lock()
        isCancelled = false
        cancelLock.unlock()
        defer {
            tempDownload?.cancel()
            tempDownload = nil
            retainedWebDAVLoader = nil
            retainedAsset = nil
            ExportPaths.removeWorkingSourceCopy(log: logHandler)
        }


        let rangeCache = WebDAVRangeCache()
        logHandler("Prefetching from pCloud (size + MP4 index)…")
        try await WebDAVPrefetch.warmUp(
            remoteURL: inputURL,
            authorization: authorizationProvider(),
            cache: rangeCache,
            catalogContentLength: catalogContentLength,
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
        logHandler(
            "Dense fill — each minute downloads to temp before passthrough (mid-file uses capped hybrid reader; seek 0 uses on-disk file when dense)."
        )
        try Self.ensureExportDiskSpace(fileBytes: fileSize)

        if fileSize > Self.streamOnlyThresholdBytes {
            logHandler(
                "Large file (\(Self.formatBytes(fileSize))) — sparse temp copy (only bytes needed per minute, not full \(Self.formatBytes(fileSize)))"
            )
        }
        let downloader = try WebDAVTempFileDownload(
            remoteURL: inputURL,
            rangeCache: rangeCache,
            authorizationProvider: authorizationProvider,
            isCancelled: cancelCheck,
            log: logHandler
        )
        tempDownload = downloader
        downloader.logDownloadStarted()
        try await downloader.ensureIndexTailOnDisk()
        let (durationSeconds, videoFormat, audioFormat) = try await probeMetadataPreferLocal(
            fileURL: downloader.fileURL,
            inputURL: inputURL,
            authorizationProvider: authorizationProvider,
            rangeCache: rangeCache,
            log: logHandler
        )

        let durationMs = Int64(durationSeconds * 1000)
        let seekSeconds = Double(seekMs) / 1000.0
        if durationMs > 0, seekMs >= durationMs - 250 {
            logHandler(
                "Seek \(formatSeekMs(seekMs)) is at or past file duration (~\(formatSeekMs(durationMs))) — choose 0 min or a shorter start preset"
            )
            throw SegmentExporterError.seekPastEnd
        }
        tempDownload?.beginExport(
            seekSeconds: seekSeconds,
            durationSeconds: durationSeconds,
            useBackgroundDownload: false
        )

        logHandler("Video codec \(CodecSupport.fourCCString(videoFormat))" +
            (audioFormat.map { ", audio \(CodecSupport.fourCCString($0))" } ?? ", no audio"))

        let dlnaPublishOrigin = CFAbsoluteTimeGetCurrent()
        var minuteIndex = 0
        var lastMediaTimeMs = seekMs
        var reachedEnd = false

        logHandler(
            "Phone export: one file \(ExportPaths.segmentURL(index: 0).lastPathComponent) per ~60s; " +
                "PC keeps 3d_op_00/01 via LAN watch or USB (overwrite older slot)"
        )

        guard let downloader = tempDownload else {
            throw SegmentExporterError.readerSetupFailed
        }
        logHandler("Publishing 60s segments — dense fill each minute, then passthrough")

        while true {
                try checkCancelled()

                let windowStartSeconds = seekSeconds + Double(minuteIndex) * Self.segmentDurationSeconds
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
                let byteRange = downloader.byteRangeForTimeline(
                    timelineStartSeconds: windowStartSeconds,
                    timelineEndSeconds: windowEndSeconds,
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
                    "Need ~\(Self.formatBytes(byteRange.length)) at file \(Self.formatBytes(byteRange.start))–\(Self.formatBytes(byteRange.end)) for \(Int(windowStartSeconds / 60)):\(String(format: "%02d", Int(windowStartSeconds) % 60))–\(Int(windowEndSeconds / 60)):\(String(format: "%02d", Int(windowEndSeconds) % 60))"
                )
                let rangeStart = CMTime(seconds: windowStartSeconds, preferredTimescale: 600)
                let rangeDuration = CMTime(
                    seconds: windowEndSeconds - windowStartSeconds,
                    preferredTimescale: 600
                )
                logHandler("Verifying reader for \(Int(windowStartSeconds / 60)):\(String(format: "%02d", Int(windowStartSeconds) % 60))–\(Int(windowEndSeconds / 60)):\(String(format: "%02d", Int(windowEndSeconds) % 60)) (large sparse files can take a few minutes)…")
                try await downloader.ensureFileHeadOnDisk()
                try await downloader.ensureIndexTailOnDisk()
                try await downloader.ensureContiguousRange(byteRange)
                if downloader.isRangeFilled(byteRange),
                   downloader.hasHeadOnDisk(),
                   downloader.hasIndexTailOnDisk() {
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
                            try await downloader.ensureIndexTailOnDisk(force: true)
                            try await downloader.ensureContiguousRange(byteRange)
                        },
                        isCancelled: cancelCheck,
                        log: logHandler
                    )
                }

                let slot = minuteIndex % Self.segmentFileCount
                let stagingURL = ExportPaths.segmentStagingURL(index: slot)

                try await exportSegmentFromTempOrStream(
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
                    isCancelled: cancelCheck,
                    log: logHandler
                )
                try await publishValidatedSegment(
                    minuteIndex: minuteIndex,
                    slot: slot,
                    stagingURL: stagingURL,
                    rangeDuration: rangeDuration,
                    wallOrigin: dlnaPublishOrigin,
                    log: logHandler
                )

                lastMediaTimeMs = Int64(windowEndSeconds * 1000)
                minuteIndex += 1
        }

        if seekSeconds <= 0.5 {
            try await downloader.waitUntilComplete()
        }

        logHandler(reachedEnd ? "Reached end of file — all segments published." : "Export stopped.")
        return SegmentExportResult(lastMediaTimeMs: lastMediaTimeMs, reachedEnd: reachedEnd)
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
            log("Publishing segment immediately (single phone file; PC DLNA ring via USB sync)")
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
        let path = ExportPaths.exportsDirectory.path
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let freeNumber = attrs[.systemFreeSize] as? NSNumber else {
            return nil
        }
        return freeNumber.int64Value
    }

    private static func ensureExportDiskSpace(fileBytes: Int64) throws {
        guard let free = freeDiskBytes() else { return }
        let needed = min(max(fileBytes, 0), streamingWorkingSetBytes) + diskMarginBytes
        guard free >= needed else {
            throw SegmentExporterError.insufficientDiskSpace(needed: needed, available: max(0, free))
        }
    }

    private func isDenseWindowReady(
        downloader: WebDAVTempFileDownload,
        byteRange: TimelineByteRange
    ) -> Bool {
        downloader.isRangeFilled(byteRange)
            && downloader.isByteRangeFullyOnDisk(byteRange)
            && downloader.hasHeadOnDisk()
            && downloader.hasIndexTailOnDisk()
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
        isCancelled: @escaping () -> Bool,
        log: @escaping (String) -> Void
    ) async throws {
        let midFileSegment = byteRange.start >= Self.midFilePrefetchThresholdBytes
        if midFileSegment {
            log(
                "Mid-file segment — dense \(Self.formatBytes(byteRange.length)) at \(Self.formatBytes(byteRange.start))"
            )
            downloader.pauseBackgroundDownload()
            try await prepareMidFileTempForReader(downloader: downloader, byteRange: byteRange, log: log)
        }

        downloader.pauseBackgroundDownload()
        if !isDenseWindowReady(downloader: downloader, byteRange: byteRange) {
            try await downloader.ensureFileHeadOnDisk()
            try await downloader.ensureIndexTailOnDisk()
            try await downloader.ensureContiguousRange(byteRange)
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
        ) async throws {
            let (readAsset, hybridLoader) = try await resolvePassthroughReadAsset(
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
            if let hybridLoader {
                defer {
                    readAsset.resourceLoader.setDelegate(nil, queue: nil)
                    hybridLoader.cancelOutstandingWork()
                }
            }
            try await SegmentPassThroughExporter.exportWindow(
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
                "Dense window at \(Self.formatBytes(byteRange.start)) — capped hybrid reader (file:// reads zero-filled gaps)"
            )
        }
        if windowDense, useOnDiskFileURL, byteRange.start == 0 {
            try await ensureSeekZeroRemainderOnDiskIfBeneficial(
                downloader: downloader,
                byteRange: byteRange,
                log: log
            )
        }
        downloader.closeWriteHandleForPassthroughRead(log: log)
        do {
            try await runPassthrough(
                sourceLabel: tempSourceLabel,
                useOnDiskFileURL: useOnDiskFileURL
            )
        } catch {
            if byteRange.start > 0,
               windowDense,
               Self.isUnsupportedAssetURLError(error) {
                log(
                    "Hybrid asset URL rejected (\(error.localizedDescription)) — using HTTPS byte-range reads from pCloud"
                )
                downloader.closeWriteHandleForPassthroughRead(log: log)
                try await runPassthrough(
                    sourceLabel: "\(tempSourceLabel) (HTTPS range)",
                    useOnDiskFileURL: false,
                    forceHTTPSRangeReads: true
                )
                return
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
                try await runPassthrough(
                    sourceLabel: tempSourceLabel,
                    useOnDiskFileURL: true
                )
                return
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
                    try await SegmentPassThroughExporter.exportWindowViaExportSession(
                        asset: fileAsset,
                        rangeStart: rangeStart,
                        rangeDuration: rangeDuration,
                        outputURL: outputURL,
                        sourceLabel: "\(tempSourceLabel) (export session)",
                        log: log
                    )
                    return
                }
                log(
                    "On-disk passthrough failed (\(error.localizedDescription)) — sparse gap after window; using capped hybrid reader"
                )
                try await Task.sleep(nanoseconds: 400_000_000)
                try await runPassthrough(
                    sourceLabel: "\(tempSourceLabel) (hybrid after on-disk writer error)",
                    useOnDiskFileURL: false
                )
                return
            }
            if useOnDiskFileURL,
               byteRange.start > 0,
               isSparseContainerOpenFailure(error) || Self.isRetriablePassthroughWriterFailure(error) {
                log(
                    "On-disk passthrough failed (\(error.localizedDescription)) — retrying with capped hybrid reader"
                )
                downloader.closeWriteHandleForPassthroughRead(log: log)
                try await runPassthrough(
                    sourceLabel: "\(tempSourceLabel) (hybrid retry)",
                    useOnDiskFileURL: false
                )
                return
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
                    try await runPassthrough(
                        sourceLabel: "dense local temp (hybrid after writer error)",
                        useOnDiskFileURL: false
                    )
                    return
                }
                log(
                    "Writer rejected passthrough (\(error.localizedDescription)) — re-downloading window, then capped hybrid reader"
                )
                downloader.pauseBackgroundDownload()
                try await downloader.ensureFileHeadOnDisk()
                try await downloader.ensureIndexTailOnDisk()
                try await downloader.ensureContiguousRange(byteRange, force: true)
                windowDense = isDenseWindowReady(downloader: downloader, byteRange: byteRange)
                downloader.closeWriteHandleForPassthroughRead(log: log)
                try await runPassthrough(
                    sourceLabel: windowDense ? "dense local temp (writer retry)" : "sparse temp + pCloud (writer retry)",
                    useOnDiskFileURL: false
                )
                return
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
                downloader.pauseBackgroundDownload()
                try await prepareMidFileTempForReader(downloader: downloader, byteRange: byteRange, log: log)
                windowDense = isDenseWindowReady(downloader: downloader, byteRange: byteRange)
                useOnDiskFileURL = false
                downloader.closeWriteHandleForPassthroughRead(log: log)
                do {
                    try await runPassthrough(
                        sourceLabel: windowDense ? "dense local temp (hybrid retry)" : "sparse temp + pCloud (retry)",
                        useOnDiskFileURL: false
                    )
                    return
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
            downloader.pauseBackgroundDownload()
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
            try await runPassthrough(
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
        let shouldFill = fileLength <= Self.seekZeroDenseEntireFileMaxBytes
            || tailBytes <= Self.seekZeroDenseTailMaxBytes
        guard shouldFill else {
            log(
                "Seek 0 — leaving \(Self.formatBytes(tailBytes)) sparse after window (file too large for full tail fill; hybrid if needed)"
            )
            return
        }
        log(
            "Seek 0 — dense-filling \(Self.formatBytes(tailBytes)) after window (\(Self.formatBytes(fileLength)) file on disk for passthrough)"
        )
        try await downloader.ensureContiguousRange(tail)
    }

    /// `file://` when the first-minute window is dense at seek 0 (head + index tail on disk; sparse middle is OK for minute 0).
    private func shouldUseOnDiskFileURLForPassthrough(
        downloader: WebDAVTempFileDownload,
        byteRange: TimelineByteRange,
        windowDense: Bool
    ) -> Bool {
        guard windowDense, byteRange.start == 0, byteRange.length > 0 else { return false }
        return downloader.isByteRangeFullyOnDisk(byteRange)
    }

    private func prepareMidFileTempForReader(
        downloader: WebDAVTempFileDownload,
        byteRange: TimelineByteRange,
        log: @escaping (String) -> Void
    ) async throws {
        log("Mid-file temp: ensuring file header + MP4 index + dense window before reader…")
        try await downloader.ensureFileHeadOnDisk()
        try await downloader.ensureIndexTailOnDisk(force: true)
        try await downloader.ensureContiguousRange(byteRange)
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
            log("Passthrough reader: on-disk temp file (dense window at start of file)")
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
        let totalSec = max(0, ms / 1000)
        let min = totalSec / 60
        let sec = totalSec % 60
        return String(format: "%d:%02d", min, sec)
    }

    private func formatMediaTimeForLog(_ time: CMTime) -> String {
        let seconds = CMTimeGetSeconds(time)
        let min = Int(seconds) / 60
        let sec = Int(seconds) % 60
        return String(format: "%d:%02d", min, sec)
    }

    private static let midFilePrefetchThresholdBytes: Int64 = 32 * 1024 * 1024
    /// At seek 0, dense-fill bytes after the minute window so `file://` passthrough does not read zero-filled mdat.
    private static let seekZeroDenseEntireFileMaxBytes: Int64 = 1024 * 1024 * 1024
    private static let seekZeroDenseTailMaxBytes: Int64 = 256 * 1024 * 1024

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
            case .cancelled, .readerInterrupted, .seekPastEnd, .noVideoTrack, .unsupportedCodec,
                 .missingFormatDescription, .writerSetupFailed, .writerAudioStall,
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
        return try await probeStreamMetadata(asset: streamingAsset, log: log)
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
        writer.shouldOptimizeForNetworkUse = false
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
    case readerInterrupted
    case seekPastEnd
    case noVideoTrack
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
        case .readerInterrupted:
            return "pCloud read was interrupted (app did not stop). Try seek 0 min, keep app open, or use Wi‑Fi."
        case .seekPastEnd:
            return "Start position is at or past the end of the file."
        case .noVideoTrack:
            return "No video track found in this file."
        case .unsupportedCodec(let fourCC):
            switch fourCC.lowercased() {
            case "av01", "dav1":
                return "AV1 (\(fourCC)) is not supported for 60s MP4 segments. Re-encode the source to HEVC (hvc1/hev1) or H.264 with AAC."
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
