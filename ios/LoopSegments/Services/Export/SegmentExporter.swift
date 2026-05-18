import AVFoundation
import CoreMedia
import Foundation

struct SegmentExportResult {
    let lastMediaTimeMs: Int64
    let reachedEnd: Bool
}

/// Stream-copy export to two rotating 60s MP4 segments (AVFoundation, WebDAV input).
final class SegmentExporter {
    static let segmentDurationSeconds = 60.0
    static let segmentFileCount = 2

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
        let streamFromPCloud = Self.shouldStreamSegments(fileBytes: fileSize)
        try Self.ensureExportDiskSpace(fileBytes: fileSize, streaming: streamFromPCloud)

        let durationSeconds: Double
        let videoFormat: CMFormatDescription
        let audioFormat: CMFormatDescription?

        if streamFromPCloud {
            logHandler("Low free space — probing codecs via pCloud stream (prefetch cache)")
            let streamingAsset = try await openStreamingAsset(
                inputURL: inputURL,
                authorizationProvider: authorizationProvider,
                rangeCache: rangeCache,
                logHandler: logHandler
            )
            (durationSeconds, videoFormat, audioFormat) = try await probeStreamMetadata(
                asset: streamingAsset,
                log: logHandler
            )
            releaseStreamingProbe(streamFromPCloud: true, log: logHandler)
        } else {
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
            (durationSeconds, videoFormat, audioFormat) = try await probeMetadataPreferLocal(
                fileURL: downloader.fileURL,
                inputURL: inputURL,
                authorizationProvider: authorizationProvider,
                rangeCache: rangeCache,
                log: logHandler
            )
        }

        let durationMs = Int64(durationSeconds * 1000)
        let seekSeconds = Double(seekMs) / 1000.0
        if durationMs > 0, seekMs >= durationMs - 250 {
            throw SegmentExporterError.seekPastEnd
        }
        if !streamFromPCloud, let downloader = tempDownload {
            downloader.beginExport(seekSeconds: seekSeconds, durationSeconds: durationSeconds)
        }

        logHandler("Video codec \(CodecSupport.fourCCString(videoFormat))" +
            (audioFormat.map { ", audio \(CodecSupport.fourCCString($0))" } ?? ", no audio"))

        let dlnaPublishOrigin = CFAbsoluteTimeGetCurrent()
        var minuteIndex = 0
        var lastMediaTimeMs = seekMs
        var reachedEnd = false

        logHandler("DLNA: 3d_op_00/01 update at most once per ~60s wall time (staging → slot; safe for players that cannot refresh mid-playback)")

        if streamFromPCloud {
            logHandler(
                "Large file (\(Self.formatBytes(fileSize))) — each 60s segment reads only that minute from pCloud (no \(Self.formatBytes(fileSize)) temp copy)"
            )
            logHandler("Publishing 60s segments as each minute is read from pCloud")
            while true {
                try checkCancelled()
                let windowStartSeconds = seekSeconds + Double(minuteIndex) * Self.segmentDurationSeconds
                if windowStartSeconds >= durationSeconds - 0.05 {
                    reachedEnd = true
                    break
                }
                let windowEndSeconds = min(windowStartSeconds + Self.segmentDurationSeconds, durationSeconds)
                let rangeStart = CMTime(seconds: windowStartSeconds, preferredTimescale: 600)
                let rangeDuration = CMTime(
                    seconds: windowEndSeconds - windowStartSeconds,
                    preferredTimescale: 600
                )
                let slot = minuteIndex % Self.segmentFileCount
                let stagingURL = ExportPaths.segmentStagingURL(index: slot)
                let byteRange = WebDAVTempFileDownload.byteRangeForTimeline(
                    totalLength: fileSize,
                    timelineStartSeconds: windowStartSeconds,
                    timelineEndSeconds: windowEndSeconds,
                    durationSeconds: durationSeconds
                )

                try await exportSegmentFromPCloudStream(
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
                    log: logHandler
                )
                try SegmentLocalReadiness.validateOutputFile(at: stagingURL, log: logHandler)

                await PhotosSegmentPublisher.publish(segmentSlot: slot, videoURL: stagingURL, log: logHandler)
                logHandler("Ready for PC Photos sync — \(ExportPaths.segmentURL(index: slot).lastPathComponent) (staging)")

                await waitForDLNAPublishSchedule(
                    minuteIndex: minuteIndex,
                    wallOrigin: dlnaPublishOrigin,
                    slot: slot,
                    log: logHandler
                )
                try ExportPaths.publishSegmentToDLNA(slot: slot, log: logHandler)

                lastMediaTimeMs = Int64(windowEndSeconds * 1000)
                logHandler("DLNA slot updated — \(ExportPaths.segmentURL(index: slot).lastPathComponent) (streamed from pCloud)")
                minuteIndex += 1
            }
        } else {
            guard let downloader = tempDownload else {
                throw SegmentExporterError.readerSetupFailed
            }
            logHandler("Publishing 60s segments as temp download catches up (DLNA can loop latest)")

            while true {
                try checkCancelled()

                let windowStartSeconds = seekSeconds + Double(minuteIndex) * Self.segmentDurationSeconds
                if windowStartSeconds >= durationSeconds - 0.05 {
                    reachedEnd = true
                    break
                }

                let windowEndSeconds = min(windowStartSeconds + Self.segmentDurationSeconds, durationSeconds)
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
                downloader.setDownloadHighWaterMark(byteRange.end + WebDAVTempFileDownload.exportTimelineSlackBytes)
                try await downloader.waitUntilWindowReady(
                    timelineStartSeconds: windowStartSeconds,
                    timelineEndSeconds: windowEndSeconds,
                    durationSeconds: durationSeconds
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
                    log: logHandler
                )
                try SegmentLocalReadiness.validateOutputFile(at: stagingURL, log: logHandler)

                await PhotosSegmentPublisher.publish(segmentSlot: slot, videoURL: stagingURL, log: logHandler)
                logHandler("Ready for PC Photos sync — \(ExportPaths.segmentURL(index: slot).lastPathComponent) (staging)")

                await waitForDLNAPublishSchedule(
                    minuteIndex: minuteIndex,
                    wallOrigin: dlnaPublishOrigin,
                    slot: slot,
                    log: logHandler
                )
                try ExportPaths.publishSegmentToDLNA(slot: slot, log: logHandler)

                lastMediaTimeMs = Int64(windowEndSeconds * 1000)
                logHandler("DLNA slot updated — \(ExportPaths.segmentURL(index: slot).lastPathComponent)")

                minuteIndex += 1
            }

            if seekSeconds <= 0.5 {
                try await downloader.waitUntilComplete()
            }
        }

        logHandler(reachedEnd ? "Reached end of file — all segments published." : "Export stopped.")
        return SegmentExportResult(lastMediaTimeMs: lastMediaTimeMs, reachedEnd: reachedEnd)
    }

    /// Files above this or that do not fit on disk are exported by range reads (no full temp copy).
    private static let streamOnlyThresholdBytes: Int64 = 1_500_000_000
    private static let diskMarginBytes: Int64 = 384 * 1024 * 1024
    private static let streamingWorkingSetBytes: Int64 = 700 * 1024 * 1024

    /// Direct AVFoundation-on-WebDAV only when there is not enough room even for a sparse partial temp file.
    private static func shouldStreamSegments(fileBytes: Int64) -> Bool {
        guard fileBytes > 0 else { return false }
        guard let free = freeDiskBytes() else { return false }
        return free < streamingWorkingSetBytes + diskMarginBytes
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

    private static func ensureExportDiskSpace(fileBytes: Int64, streaming: Bool) throws {
        guard let free = freeDiskBytes() else { return }
        let needed = streaming ? streamingWorkingSetBytes : fileBytes + diskMarginBytes
        guard free >= needed else {
            throw SegmentExporterError.insufficientDiskSpace(needed: needed, available: max(0, free))
        }
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
        log: @escaping (String) -> Void
    ) async throws {
        let readAsset = AVURLAsset(
            url: tempURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let midFileDenseOnly = byteRange.start >= Self.midFilePrefetchThresholdBytes
        if midFileDenseOnly {
            log(
                "Mid-file segment — dense-download \(Self.formatBytes(byteRange.length)) at \(Self.formatBytes(byteRange.start)) (no pCloud stream for 10+ min)"
            )
            downloader.pauseBackgroundDownload()
            try await downloader.ensureContiguousRange(byteRange)
        }
        do {
            try await SegmentPassThroughExporter.exportWindow(
                asset: readAsset,
                videoFormat: videoFormat,
                audioFormat: audioFormat,
                rangeStart: rangeStart,
                rangeDuration: rangeDuration,
                outputURL: outputURL,
                sourceLabel: "temp file",
                log: log
            )
        } catch {
            guard Self.shouldStreamFallback(after: error, midFileDenseOnly: midFileDenseOnly) else { throw error }
            try? FileManager.default.removeItem(at: outputURL)
            log(
                "Temp not readable (\(error.localizedDescription)) — downloading this minute to temp, then retrying reader"
            )
            downloader.pauseBackgroundDownload()
            try await downloader.ensureContiguousRange(byteRange)
            do {
                try await SegmentPassThroughExporter.exportWindow(
                    asset: readAsset,
                    videoFormat: videoFormat,
                    audioFormat: audioFormat,
                    rangeStart: rangeStart,
                    rangeDuration: rangeDuration,
                    outputURL: outputURL,
                    sourceLabel: "temp file (window filled)",
                    log: log
                )
                return
            } catch {
                guard Self.shouldStreamFallback(after: error, midFileDenseOnly: midFileDenseOnly) else { throw error }
                try? FileManager.default.removeItem(at: outputURL)
                if midFileDenseOnly {
                    log(
                        "Temp still not readable at mid-file — streaming this 60s window from pCloud (capped reads)"
                    )
                } else {
                    log(
                        "Temp still not readable — streaming this 60s window from pCloud (capped reads, not full \(Self.formatBytes(trustedLength)))"
                    )
                }
            }
            downloader.pauseBackgroundDownload()
            do {
                try await exportSegmentFromPCloudStream(
                    remoteURL: remoteURL,
                    authorizationProvider: authorizationProvider,
                    rangeCache: rangeCache,
                    trustedLength: trustedLength,
                    byteRange: byteRange,
                    videoFormat: videoFormat,
                    audioFormat: audioFormat,
                    rangeStart: rangeStart,
                    rangeDuration: rangeDuration,
                    outputURL: outputURL,
                    log: log
                )
            } catch SegmentExporterError.noKeyframeInWindow, SegmentExporterError.readerInterrupted,
                SegmentExporterError.writerFailed {
                try? FileManager.default.removeItem(at: outputURL)
                log(
                    "pCloud stream failed — downloading \(Self.formatBytes(byteRange.length)) to temp and retrying locally"
                )
                try await downloader.ensureContiguousRange(byteRange)
                try await SegmentPassThroughExporter.exportWindow(
                    asset: readAsset,
                    videoFormat: videoFormat,
                    audioFormat: audioFormat,
                    rangeStart: rangeStart,
                    rangeDuration: rangeDuration,
                    outputURL: outputURL,
                    sourceLabel: "temp file (after stream failure)",
                    log: log
                )
            }
        }
    }

    private static let midFilePrefetchThresholdBytes: Int64 = 32 * 1024 * 1024

    private static func shouldStreamFallback(after error: Error, midFileDenseOnly: Bool = false) -> Bool {
        if midFileDenseOnly { return true }
        if let exportError = error as? SegmentExporterError {
            switch exportError {
            case .readerSetupFailed, .noKeyframeInWindow, .segmentOutputTooSmall:
                return true
            case .readerFailed(let underlying):
                return isSparseContainerOpenFailure(underlying)
            case .cancelled, .readerInterrupted, .seekPastEnd, .noVideoTrack, .unsupportedCodec,
                 .missingFormatDescription, .writerSetupFailed, .writerFailed, .writerBackpressure,
                 .insufficientDiskSpace:
                return false
            }
        }
        return isSparseContainerOpenFailure(error)
    }

    private func exportSegmentFromPCloudStream(
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
        log: @escaping (String) -> Void
    ) async throws {
        let auth = authorizationProvider()
        if trustedLength > 0 {
            try await WebDAVPrefetch.prefetchStreamExportIndex(
                remoteURL: remoteURL,
                authorization: auth,
                cache: rangeCache,
                fileLength: trustedLength,
                log: log
            )
        }
        let indexTailBytes = WebDAVTempFileDownload.indexTailFetchBytes(totalLength: max(trustedLength, 1))
        let readPolicy = StreamReadPolicy.forExportWindow(
            fileLength: trustedLength,
            window: byteRange,
            indexTailBytes: indexTailBytes
        )
        let loader = WebDAVResourceLoader(
            remoteURL: remoteURL,
            authorizationProvider: authorizationProvider,
            rangeCache: rangeCache,
            trustedContentLength: trustedLength > 0 ? trustedLength : nil,
            readPolicy: readPolicy,
            log: log
        )
        let asset = AVURLAsset(
            url: loader.customAssetURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        defer {
            asset.resourceLoader.setDelegate(nil, queue: nil)
            loader.cancelOutstandingWork()
        }

        try await SegmentPassThroughExporter.exportWindow(
            asset: asset,
            videoFormat: videoFormat,
            audioFormat: audioFormat,
            rangeStart: rangeStart,
            rangeDuration: rangeDuration,
            outputURL: outputURL,
            sourceLabel: "pCloud stream",
            log: log
        )
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

    private func releaseStreamingProbe(streamFromPCloud: Bool, log: (String) -> Void) {
        guard retainedAsset != nil || retainedWebDAVLoader != nil else { return }
        retainedWebDAVLoader?.cancelOutstandingWork()
        retainedAsset?.resourceLoader.setDelegate(nil, queue: nil)
        retainedWebDAVLoader = nil
        retainedAsset = nil
        if streamFromPCloud {
            log("Released codec probe — segments will stream from pCloud (no full temp copy)")
        } else {
            log("Released codec probe — export uses local temp file")
        }
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

    init(
        outputURL: URL,
        videoFormat: CMFormatDescription,
        audioFormat: CMFormatDescription?,
        realTime: Bool = true
    ) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: videoFormat
        )
        videoInput.expectsMediaDataInRealTime = realTime

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

    func append(_ sample: CMSampleBuffer, track: SegmentTrackKind) throws {
        let input: AVAssetWriterInput
        switch track {
        case .video: input = videoInput
        case .audio:
            guard let audioInput else { return }
            input = audioInput
        }

        var attempts = 0
        while !input.isReadyForMoreMediaData {
            attempts += 1
            if attempts > 600_000 {
                throw SegmentExporterError.writerBackpressure
            }
            Thread.sleep(forTimeInterval: 0.001)
        }

        guard input.append(sample) else {
            let err = writer.error ?? NSError(domain: "SegmentWriter", code: -1)
            throw SegmentExporterError.writerFailed(err)
        }
    }

    func finish() async throws {
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
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
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case noKeyframeInWindow
    case segmentOutputTooSmall(Int64)

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
            return "Segment writer timed out waiting for data."
        case .insufficientDiskSpace(let needed, let available):
            let needMB = needed / (1024 * 1024)
            let haveMB = available / (1024 * 1024)
            return "Need ~\(needMB) MB free on iPhone storage; only ~\(haveMB) MB available. Free space in Settings → General → iPhone Storage."
        case .noKeyframeInWindow:
            return "Could not start segment on a keyframe — wait for more download or use seek 0 min."
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
