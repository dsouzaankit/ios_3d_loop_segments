import AVFoundation
import CoreMedia
import XCTest
@testable import LoopSegments

/// Decision rules inside the export pipeline: which errors skip a minute, which fall back to
/// streaming, which writer failures are retried, and size-based duration estimates. A wrong
/// answer here means a stuck or failed export, so these pin the current behaviour.
final class SegmentExporterRulesTests: XCTestCase {
    /// Errors with an explicit message, so tests do not depend on the OS's default wording.
    private func err(_ message: String, domain: String = "test", code: Int = 1) -> NSError {
        NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func av(_ code: Int, _ message: String = "boom") -> NSError {
        err(message, domain: AVFoundationErrorDomain, code: code)
    }

    // MARK: Skip this minute and continue?

    func testFatalErrorsStopTheExport() {
        let fatal: [SegmentExporterError] = [
            .cancelled, .paused, .readerInterrupted, .seekPastEnd, .noVideoTrack,
            .containerProbeFailed(.asf), .unsupportedCodec("av01"), .missingFormatDescription,
            .insufficientDiskSpace(needed: 2, available: 1),
        ]
        for e in fatal {
            XCTAssertFalse(SegmentExporter.shouldSkipMinuteAndContinue(after: e), "\(e)")
        }
    }

    func testPerMinuteErrorsSkipAndContinue() {
        let perMinute: [SegmentExporterError] = [
            .readerSetupFailed, .readerFailed(err("x")), .writerSetupFailed, .writerFailed(err("x")),
            .writerBackpressure, .writerAudioStall, .noKeyframeInWindow,
            .timelineByteWindowMismatch(mediaTime: "0:01"), .segmentOutputTooSmall(0),
            .midFileTempUnreadable(mediaTime: "0:01", underlying: "x"),
        ]
        for e in perMinute {
            XCTAssertTrue(SegmentExporter.shouldSkipMinuteAndContinue(after: e), "\(e)")
        }
        XCTAssertTrue(SegmentExporter.shouldSkipMinuteAndContinue(after: err("other")), "unknown errors skip the minute")
    }

    // MARK: Fall back to streaming?

    func testStreamFallbackCases() {
        let fallback: [SegmentExporterError] = [
            .readerSetupFailed, .segmentOutputTooSmall(0), .writerFailed(err("x")), .writerBackpressure,
            .readerFailed(err("Cannot Open")),
        ]
        for e in fallback {
            XCTAssertTrue(SegmentExporter.shouldStreamFallback(after: e), "\(e)")
        }
        let noFallback: [SegmentExporterError] = [
            .noKeyframeInWindow, .timelineByteWindowMismatch(mediaTime: "0:01"), .readerFailed(err("boom")),
            .cancelled, .paused, .readerInterrupted, .seekPastEnd, .noVideoTrack, .containerProbeFailed(.asf),
            .unsupportedCodec("av01"), .missingFormatDescription, .writerSetupFailed, .writerAudioStall,
            .insufficientDiskSpace(needed: 2, available: 1), .midFileTempUnreadable(mediaTime: "0:01", underlying: "x"),
        ]
        for e in noFallback {
            XCTAssertFalse(SegmentExporter.shouldStreamFallback(after: e), "\(e)")
        }
    }

    /// A sparse MP4 that cannot be opened yet is recognised by message or by AVFoundation code.
    func testSparseOpenFailureSignsTriggerFallback() {
        for e in [err("Cannot Open"), err("The operation could not be completed"), err("The file couldn't be opened."),
                  err("The file could not be opened."), av(-11828), av(-11829)] {
            XCTAssertTrue(SegmentExporter.shouldStreamFallback(after: e), e.localizedDescription)
        }
        XCTAssertFalse(SegmentExporter.shouldStreamFallback(after: av(-11800)))
        XCTAssertFalse(SegmentExporter.shouldStreamFallback(after: err("boom")))
    }

    // MARK: Retry with AVAssetExportSession after a manual HTTPS failure?

    func testExportSessionRetryAfterHTTPSFailure() {
        XCTAssertFalse(SegmentExporter.shouldTryExportSessionAfterHTTPSManualFailure(SegmentExporterError.cancelled))
        XCTAssertFalse(SegmentExporter.shouldTryExportSessionAfterHTTPSManualFailure(SegmentExporterError.readerInterrupted))
        XCTAssertTrue(SegmentExporter.shouldTryExportSessionAfterHTTPSManualFailure(SegmentExporterError.paused))
        XCTAssertTrue(SegmentExporter.shouldTryExportSessionAfterHTTPSManualFailure(err("network")))
    }

    // MARK: Writer and reader failure classification

    func testRetriablePassthroughWriterFailures() {
        XCTAssertTrue(SegmentExporter.isRetriablePassthroughWriterFailure(SegmentExporterError.writerFailed(av(-11800))))
        XCTAssertTrue(SegmentExporter.isRetriablePassthroughWriterFailure(SegmentExporterError.writerFailed(av(-11847))))
        XCTAssertTrue(SegmentExporter.isRetriablePassthroughWriterFailure(SegmentExporterError.writerFailed(err("Operation Interrupted"))))
        XCTAssertFalse(SegmentExporter.isRetriablePassthroughWriterFailure(SegmentExporterError.writerFailed(av(-11819))))
        XCTAssertFalse(SegmentExporter.isRetriablePassthroughWriterFailure(SegmentExporterError.readerFailed(av(-11800))),
                       "only writer failures are retried here")
        XCTAssertEqual(SegmentExporter.isWriterSampleRejection(SegmentExporterError.writerFailed(av(-11800))), true)
    }

    func testAudioWriterRejectionNeedsTheAudioTrack() {
        let e = SegmentExporterError.writerFailed(av(-11800))
        XCTAssertTrue(SegmentExporter.isAudioWriterRejection(e, track: .audio))
        XCTAssertFalse(SegmentExporter.isAudioWriterRejection(e, track: .video))
    }

    func testUnsupportedAssetURL() {
        XCTAssertTrue(SegmentExporter.isUnsupportedAssetURLError(err("x", domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL)))
        XCTAssertTrue(SegmentExporter.isUnsupportedAssetURLError(err("Unsupported URL")))
        XCTAssertFalse(SegmentExporter.isUnsupportedAssetURLError(err("boom")))
    }

    func testHybridReaderOpenFailure() {
        XCTAssertTrue(SegmentExporter.isHybridReaderOpenFailure(SegmentExporterError.readerFailed(av(-1))), "any AVFoundation error")
        XCTAssertTrue(SegmentExporter.isHybridReaderOpenFailure(SegmentExporterError.readerFailed(err("Cannot Open"))))
        XCTAssertTrue(SegmentExporter.isHybridReaderOpenFailure(err("Operation Stopped")))
        XCTAssertFalse(SegmentExporter.isHybridReaderOpenFailure(err("boom")))
    }

    // MARK: Duration estimate from file size (used when the real duration is unknown)

    func testDurationEstimateUsesSizeBands() {
        let mb: Int64 = 1024 * 1024
        let cases: [(bytes: Int64, mbps: Double)] = [(50 * mb, 10), (100 * mb, 20), (500 * mb, 25), (2 * 1024 * mb, 15)]
        for c in cases {
            let r = SegmentExporter.estimatedVanillaDurationFromFileBytes(c.bytes)
            XCTAssertEqual(r.assumedMbps, c.mbps, "\(c.bytes) bytes")
            XCTAssertEqual(r.seconds, Double(c.bytes) * 8 / (c.mbps * 1_000_000), accuracy: 0.001, "\(c.bytes) bytes")
        }
    }

    /// From 3 GB the band is at least 25 Mbps (30 from 10 GB), or higher when the LAN prefetch cutoff setting is.
    func testDurationEstimateForLargeFilesHasAFloor() {
        let gb: Int64 = 1024 * 1024 * 1024
        XCTAssertGreaterThanOrEqual(SegmentExporter.estimatedVanillaDurationFromFileBytes(4 * gb).assumedMbps, 25)
        XCTAssertGreaterThanOrEqual(SegmentExporter.estimatedVanillaDurationFromFileBytes(12 * gb).assumedMbps, 30)
    }

    func testDurationEstimateForEmptyFile() {
        for bytes: Int64 in [0, -1] {
            let r = SegmentExporter.estimatedVanillaDurationFromFileBytes(bytes)
            XCTAssertEqual(r.seconds, 0)
            XCTAssertEqual(r.assumedMbps, 10)
        }
    }

    // MARK: Codec tags

    func testFourCCAndHEVCDetection() {
        XCTAssertEqual(CodecSupport.fourCC("avc1"), kCMVideoCodecType_H264)
        XCTAssertEqual(CodecSupport.fourCC("hvc1"), kCMVideoCodecType_HEVC)
        XCTAssertTrue(CodecSupport.isHEVCVideo(kCMVideoCodecType_HEVC))
        XCTAssertTrue(CodecSupport.isHEVCVideo(CodecSupport.fourCC("hev1")), "hev1 is HEVC too")
        XCTAssertFalse(CodecSupport.isHEVCVideo(kCMVideoCodecType_H264))
    }
}
