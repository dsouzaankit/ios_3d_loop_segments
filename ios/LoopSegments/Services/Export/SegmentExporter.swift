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
        if text.contains("cancel") {
            return .readerInterrupted
        }
        return .readerFailed(error)
    }

    func run(
        inputURL: URL,
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

        if seekMs >= 10 * 60 * 1000 {
            logHandler("Deep seek (\(seekMs / 60_000) min) — pCloud may need extra reads; try 0 min first on cellular")
        }

        let rangeCache = WebDAVRangeCache()
        logHandler("Prefetching from pCloud (size + MP4 index)…")
        try await WebDAVPrefetch.warmUp(
            remoteURL: inputURL,
            authorization: authorizationProvider(),
            cache: rangeCache,
            log: logHandler
        )

        let cancelCheck: () -> Bool = { [weak self] in
            guard let self else { return true }
            self.cancelLock.lock()
            let cancelled = self.isCancelled
            self.cancelLock.unlock()
            return cancelled
        }

        let streamingAsset = try await openStreamingAsset(
            inputURL: inputURL,
            authorizationProvider: authorizationProvider,
            rangeCache: rangeCache,
            logHandler: logHandler
        )

        let duration = try await streamingAsset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        let durationMs = Int64(durationSeconds * 1000)

        let seekSeconds = Double(seekMs) / 1000.0
        if durationMs > 0, seekMs >= durationMs - 250 {
            throw SegmentExporterError.seekPastEnd
        }
        if seekMs > 0 {
            logHandler("Seek \(seekMs / 60_000) min — download is from file start; first segments need more data on disk")
        }

        guard let videoTrack = try await streamingAsset.loadTracks(withMediaType: .video).first else {
            throw SegmentExporterError.noVideoTrack
        }
        let audioTrack = try await streamingAsset.loadTracks(withMediaType: .audio).first

        let videoFormat = try await videoFormatDescription(from: videoTrack)
        guard CodecSupport.canPassthroughToMP4(videoFormat) else {
            let fourCC = CodecSupport.fourCCString(videoFormat)
            throw SegmentExporterError.unsupportedCodec(fourCC)
        }

        var audioFormat: CMFormatDescription?
        if let audioTrack {
            let fmt = try await audioFormatDescription(from: audioTrack)
            guard CodecSupport.canPassthroughAudio(fmt) else {
                let fourCC = CodecSupport.fourCCString(fmt)
                throw SegmentExporterError.unsupportedCodec(fourCC)
            }
            audioFormat = fmt
        }

        logHandler("Video codec \(CodecSupport.fourCCString(videoFormat))" +
            (audioFormat.map { ", audio \(CodecSupport.fourCCString($0))" } ?? ", no audio"))

        let downloader = try WebDAVTempFileDownload(
            remoteURL: inputURL,
            rangeCache: rangeCache,
            authorizationProvider: authorizationProvider,
            isCancelled: cancelCheck,
            log: logHandler
        )
        tempDownload = downloader
        downloader.logDownloadStarted()
        logHandler("Publishing 60s segments as temp download catches up (DLNA can loop latest)")

        let dlnaPublishOrigin = CFAbsoluteTimeGetCurrent()
        var minuteIndex = 0
        var lastMediaTimeMs = seekMs
        var reachedEnd = false

        logHandler("DLNA chunks publish on 1× wall clock when download is ahead; as soon as ready when download is behind")

        while true {
            try checkCancelled()

            let windowStartSeconds = seekSeconds + Double(minuteIndex) * Self.segmentDurationSeconds
            if windowStartSeconds >= durationSeconds - 0.05 {
                reachedEnd = true
                break
            }

            let windowEndSeconds = min(windowStartSeconds + Self.segmentDurationSeconds, durationSeconds)
            try await downloader.waitUntilTimelineEnd(
                timelineEndSeconds: windowEndSeconds,
                durationSeconds: durationSeconds
            )
            try await downloader.waitUntilLocalExportReady(
                timelineEndSeconds: windowEndSeconds,
                durationSeconds: durationSeconds
            )

            await waitForDLNAPublishSchedule(minuteIndex: minuteIndex, wallOrigin: dlnaPublishOrigin)

            let rangeStart = CMTime(seconds: windowStartSeconds, preferredTimescale: 600)
            let rangeDuration = CMTime(
                seconds: windowEndSeconds - windowStartSeconds,
                preferredTimescale: 600
            )
            let slot = minuteIndex % Self.segmentFileCount

            let readAsset = AVURLAsset(
                url: downloader.fileURL,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
            )

            try await SegmentPassThroughExporter.exportWindow(
                asset: readAsset,
                videoFormat: videoFormat,
                audioFormat: audioFormat,
                rangeStart: rangeStart,
                rangeDuration: rangeDuration,
                outputSlot: slot,
                sourceLabel: "temp file",
                log: logHandler
            )

            lastMediaTimeMs = Int64(windowEndSeconds * 1000)
            let url = ExportPaths.segmentURL(index: slot)
            await PhotosSegmentPublisher.publish(segmentSlot: slot, videoURL: url, log: logHandler)
            logHandler("DLNA slot \(url.lastPathComponent) ready — sync to PC; loops while download continues")

            minuteIndex += 1
        }

        try await downloader.waitUntilComplete()
        logHandler(reachedEnd ? "Reached end of file — all segments published." : "Export stopped.")
        return SegmentExportResult(lastMediaTimeMs: lastMediaTimeMs, reachedEnd: reachedEnd)
    }

    /// DLNA clients need stable files ~60s each; do not replace slots faster than realtime when download is ahead.
    private func waitForDLNAPublishSchedule(minuteIndex: Int, wallOrigin: CFAbsoluteTime) async {
        let publishAt = wallOrigin + Double(minuteIndex) * Self.segmentDurationSeconds
        let delay = publishAt - CFAbsoluteTimeGetCurrent()
        if delay > 0.05 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func openStreamingAsset(
        inputURL: URL,
        authorizationProvider: @escaping WebDAVAuthorizationProvider,
        rangeCache: WebDAVRangeCache,
        logHandler: @escaping (String) -> Void
    ) async throws -> AVURLAsset {
        logHandler("Probing duration/codecs via pCloud (prefetch cache)…")
        let loader = WebDAVResourceLoader(
            remoteURL: inputURL,
            authorizationProvider: authorizationProvider,
            rangeCache: rangeCache,
            log: logHandler
        )
        retainedWebDAVLoader = loader
        let asset = AVURLAsset(
            url: loader.customAssetURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        retainedAsset = asset
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        guard try await asset.load(.isPlayable) else {
            throw SegmentExporterError.readerSetupFailed
        }
        logHandler("Opened for export (pCloud + temp buffer)")
        return asset
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
            throw writer.error.map { SegmentExporterError.writerFailed($0) }
                ?? SegmentExporterError.writerSetupFailed
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

private enum CodecSupport {
    static func canPassthroughToMP4(_ format: CMFormatDescription) -> Bool {
        let codec = CMFormatDescriptionGetMediaSubType(format)
        if codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC {
            return true
        }
        if #available(iOS 16.0, *) {
            if codec == kCMVideoCodecType_AV1 {
                return true
            }
        }
        let av1 = fourCC("av01")
        let av1Alt = fourCC("dav1")
        return codec == av1 || codec == av1Alt
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
            return "Codec ‘\(fourCC)’ cannot be stream-copied to MP4 on this device. Try an H.264/AAC MP4 source."
        case .missingFormatDescription:
            return "Could not read track format from the file."
        case .readerSetupFailed:
            return "Could not start reading the media file."
        case .readerFailed(let error):
            return "Read failed: \(error.localizedDescription)"
        case .writerSetupFailed:
            return "Could not start writing segment MP4."
        case .writerFailed(let error):
            return "Write failed: \(error.localizedDescription)"
        case .writerBackpressure:
            return "Segment writer timed out waiting for data."
        case .insufficientDiskSpace(let needed, let available):
            let needMB = needed / (1024 * 1024)
            let haveMB = available / (1024 * 1024)
            return "Need ~\(needMB) MB free to copy this file; only ~\(haveMB) MB available. Free space or pick a smaller file."
        }
    }
}
