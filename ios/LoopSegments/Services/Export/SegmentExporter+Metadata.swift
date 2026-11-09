import AVFoundation
import CoreMedia
import Foundation

/// DLNA publish pacing, streaming asset and metadata probes.
extension SegmentExporter {
    /// DLNA clients cannot refresh a file during playback — publish each slot only on its wall-clock minute.
    func waitForDLNAPublishSchedule(
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

    func openStreamingAsset(
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

    func probeExportMetadata(
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

    func probeMetadataPreferLocal(
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

    func probeStreamMetadataOnly(
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

    func probeLocalMetadata(
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

    func firstVideoTrack(in asset: AVURLAsset) async throws -> AVAssetTrack? {
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            return track
        }
        let tracks = try await asset.load(.tracks)
        return tracks.first { $0.mediaType == .video }
    }

    /// Low-disk fallback: retry track load over pCloud (never requires full-file `isPlayable`).
    func probeStreamMetadata(
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

    func probeMediaMetadata(
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

    func releaseStreamingProbe(log: (String) -> Void) {
        guard retainedAsset != nil || retainedWebDAVLoader != nil else { return }
        retainedWebDAVLoader?.cancelOutstandingWork()
        retainedAsset?.resourceLoader.setDelegate(nil, queue: nil)
        retainedWebDAVLoader = nil
        retainedAsset = nil
        log("Released codec probe — export uses sparse temp + dense fill")
    }

    func videoFormatDescription(from track: AVAssetTrack) async throws -> CMFormatDescription {
        let formats = try await track.load(.formatDescriptions)
        guard let first = formats.first else {
            throw SegmentExporterError.missingFormatDescription
        }
        return first
    }

    func audioFormatDescription(from track: AVAssetTrack) async throws -> CMFormatDescription {
        let formats = try await track.load(.formatDescriptions)
        guard let first = formats.first else {
            throw SegmentExporterError.missingFormatDescription
        }
        return first
    }
}
