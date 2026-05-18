import Foundation
import FFmpegSupport

/// Segment remux via embedded FFmpeg CLI (`FFmpeg-iOS` SPM), stream copy, `-re`, segment wrap 2.
/// Loaded only when export starts — do not reference from app launch code.
final class FFmpegRunner {
    private let cancelLock = NSLock()
    private var isCancelled = false

    func cancel() {
        cancelLock.lock()
        isCancelled = true
        cancelLock.unlock()
        // ffmpeg-kit had FFmpegKit.cancel(); embedded fftools has no safe mid-run abort here.
    }

    func run(
        inputURL: URL,
        seekMs: Int64,
        authorizationHeader: String,
        logHandler: @escaping (String) -> Void
    ) async throws {
        cancelLock.lock()
        isCancelled = false
        cancelLock.unlock()

        let seekSec = Double(seekMs) / 1000.0
        let outputPath = ExportPaths.segmentOutputPath
        let args = SegmentCopyCommand.buildArguments(
            inputURL: inputURL,
            seekSeconds: seekSec,
            outputPath: outputPath,
            authorizationHeader: authorizationHeader
        )
        let argv = ["ffmpeg"] + args

        logHandler(
            SegmentCopyCommand.commandLine(
                inputURL: inputURL,
                seekSeconds: seekSec,
                outputPath: outputPath,
                authorizationHeader: authorizationHeader
            )
        )
        logHandler("(FFmpeg-iOS SPM — ffmpeg-kit is retired; live libav log goes to Xcode console)")

        let exitCode = await Task.detached(priority: .userInitiated) {
            ffmpeg(argv)
        }.value

        if checkCancelled() {
            throw FFmpegRunnerError.cancelled
        }
        guard exitCode == 0 else {
            throw FFmpegRunnerError.executionFailed(code: exitCode)
        }
    }

    private func checkCancelled() -> Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return isCancelled
    }
}

enum FFmpegRunnerError: LocalizedError {
    case executionFailed(code: Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .executionFailed(let code):
            return "FFmpeg failed (exit \(code))."
        case .cancelled:
            return "Export cancelled."
        }
    }
}
