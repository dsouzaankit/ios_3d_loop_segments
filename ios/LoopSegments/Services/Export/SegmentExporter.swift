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

    func run(
        inputURL: URL,
        seekMs: Int64,
        authorizationHeader: String,
        logHandler: @escaping (String) -> Void
    ) async throws -> SegmentExportResult {
        cancelLock.lock()
        isCancelled = false
        cancelLock.unlock()

        if seekMs >= 10 * 60 * 1000 {
            logHandler("Deep seek (\(seekMs / 60_000) min) — pCloud may need extra reads; try 0 min first on cellular")
        }

        let rangeCache = WebDAVRangeCache()
        logHandler("Prefetching from pCloud (size + MP4 index)…")
        try await WebDAVPrefetch.warmUp(
            remoteURL: inputURL,
            authorization: authorizationHeader,
            cache: rangeCache,
            log: logHandler
        )

        let asset = try await openPlayableAsset(
            inputURL: inputURL,
            authorizationHeader: authorizationHeader,
            rangeCache: rangeCache,
            logHandler: logHandler
        )
        let duration = try await asset.load(.duration)
        let durationMs = Int64(CMTimeGetSeconds(duration) * 1000)

        let seekSeconds = Double(seekMs) / 1000.0
        if durationMs > 0, seekMs >= durationMs - 250 {
            throw SegmentExporterError.seekPastEnd
        }

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw SegmentExporterError.noVideoTrack
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

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

        let reader = try AVAssetReader(asset: asset)
        let startTime = CMTime(seconds: seekSeconds, preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: startTime, end: duration)

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw SegmentExporterError.readerSetupFailed
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw SegmentExporterError.readerSetupFailed
            }
            reader.add(output)
            audioOutput = output
        }

        guard reader.startReading() else {
            throw reader.error.map { SegmentExporterError.readerFailed($0) } ?? SegmentExporterError.readerSetupFailed
        }

        var segmentIndex = 0
        var writerContext: SegmentWriterContext?
        var segmentAnchor: CMTime?
        var heldAudio: CMSampleBuffer?
        var lastMediaTimeMs = seekMs
        let wallClockOrigin = CFAbsoluteTimeGetCurrent()
        var reachedEnd = false

        func beginSegment(at pts: CMTime) throws -> SegmentWriterContext {
            let url = ExportPaths.segmentURL(index: segmentIndex)
            try? FileManager.default.removeItem(at: url)
            logHandler("Writing \(url.lastPathComponent)")
            let ctx = try SegmentWriterContext(
                outputURL: url,
                videoFormat: videoFormat,
                audioFormat: audioFormat
            )
            ctx.start(at: pts)
            return ctx
        }

        func finishSegment(_ ctx: SegmentWriterContext) async throws {
            try await ctx.finish()
        }

        while true {
            try checkCancelled()
            if reader.status == .failed {
                throw reader.error.map { SegmentExporterError.readerFailed($0) } ?? SegmentExporterError.readerSetupFailed
            }

            let videoSample = videoOutput.copyNextSampleBuffer()
            if heldAudio == nil {
                heldAudio = audioOutput?.copyNextSampleBuffer()
            }

            var candidates: [(track: TrackKind, sample: CMSampleBuffer)] = []
            if let videoSample { candidates.append((.video, videoSample)) }
            if let heldAudio { candidates.append((.audio, heldAudio)) }

            if candidates.isEmpty {
                reachedEnd = reader.status == .completed
                break
            }

            let next = candidates.min {
                CMSampleBufferGetPresentationTimeStamp($0.sample) <
                    CMSampleBufferGetPresentationTimeStamp($1.sample)
            }!

            try await processSample(
                next.sample,
                track: next.track,
                startTime: startTime,
                wallClockOrigin: wallClockOrigin,
                segmentIndex: &segmentIndex,
                writerContext: &writerContext,
                segmentAnchor: &segmentAnchor,
                lastMediaTimeMs: &lastMediaTimeMs,
                beginSegment: beginSegment,
                finishSegment: finishSegment
            )

            if next.track == .audio {
                heldAudio = nil
            }
        }

        if let ctx = writerContext {
            try await finishSegment(ctx)
        }

        logHandler(reachedEnd ? "Reached end of file." : "Export stopped.")
        return SegmentExportResult(lastMediaTimeMs: lastMediaTimeMs, reachedEnd: reachedEnd)
    }

    private func processSample(
        _ sample: CMSampleBuffer,
        track: TrackKind,
        startTime: CMTime,
        wallClockOrigin: CFAbsoluteTime,
        segmentIndex: inout Int,
        writerContext: inout SegmentWriterContext?,
        segmentAnchor: inout CMTime?,
        lastMediaTimeMs: inout Int64,
        beginSegment: (CMTime) throws -> SegmentWriterContext,
        finishSegment: (SegmentWriterContext) async throws -> Void
    ) async throws {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        lastMediaTimeMs = Int64(CMTimeGetSeconds(pts) * 1000)

        try await applyRealTimePacing(
            mediaSeconds: CMTimeGetSeconds(CMTimeSubtract(pts, startTime)),
            wallOrigin: wallClockOrigin
        )

        if writerContext == nil {
            writerContext = try beginSegment(pts)
            segmentAnchor = pts
        }

        if let anchor = segmentAnchor {
            let segmentElapsed = CMTimeGetSeconds(CMTimeSubtract(pts, anchor))
            if segmentElapsed >= Self.segmentDurationSeconds {
                if let ctx = writerContext {
                    try await finishSegment(ctx)
                }
                segmentIndex = (segmentIndex + 1) % Self.segmentFileCount
                writerContext = try beginSegment(pts)
                segmentAnchor = pts
            }
        }

        guard let ctx = writerContext else { return }
        try ctx.append(sample, track: track)
    }

    private func openPlayableAsset(
        inputURL: URL,
        authorizationHeader: String,
        rangeCache: WebDAVRangeCache,
        logHandler: @escaping (String) -> Void
    ) async throws -> AVURLAsset {
        let headerOptions: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": authorizationHeader],
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
        ]
        let directAsset = AVURLAsset(url: inputURL, options: headerOptions)
        logHandler("Opening via system HTTP…")
        do {
            _ = try await directAsset.load(.isPlayable)
            logHandler("Opened via system HTTP")
            return directAsset
        } catch {
            logHandler("System HTTP: \(error.localizedDescription)")
        }

        logHandler("Opening via WebDAV loader…")
        let loader = WebDAVResourceLoader(
            remoteURL: inputURL,
            authorization: authorizationHeader,
            rangeCache: rangeCache,
            log: logHandler
        )
        let asset = AVURLAsset(
            url: loader.customAssetURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        _ = try await asset.load(.isPlayable)
        logHandler("Opened via WebDAV loader")
        return asset
    }

    private func applyRealTimePacing(mediaSeconds: Double, wallOrigin: CFAbsoluteTime) async throws {
        let wallElapsed = CFAbsoluteTimeGetCurrent() - wallOrigin
        let delay = mediaSeconds - wallElapsed
        if delay > 0.05 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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

private enum TrackKind {
    case video
    case audio
}

private final class SegmentWriterContext {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?

    init(
        outputURL: URL,
        videoFormat: CMFormatDescription,
        audioFormat: CMFormatDescription?
    ) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: videoFormat
        )
        videoInput.expectsMediaDataInRealTime = true

        if let audioFormat {
            audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: audioFormat
            )
            audioInput?.expectsMediaDataInRealTime = true
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

    func append(_ sample: CMSampleBuffer, track: TrackKind) throws {
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
            if attempts > 5000 {
                throw SegmentExporterError.writerBackpressure
            }
            Thread.sleep(forTimeInterval: 0.002)
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
    case seekPastEnd
    case noVideoTrack
    case unsupportedCodec(String)
    case missingFormatDescription
    case readerSetupFailed
    case readerFailed(Error)
    case writerSetupFailed
    case writerFailed(Error)
    case writerBackpressure

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Export cancelled."
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
        }
    }
}
