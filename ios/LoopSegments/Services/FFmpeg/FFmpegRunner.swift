import Foundation

/// Segment remux via ffmpeg (stream copy, -re, segment wrap 2).
/// FFmpeg binaries are not linked at launch on iOS 26+ until a compatible build is integrated.
final class FFmpegRunner {
    private let cancelLock = NSLock()
    private var isCancelled = false

    func cancel() {
        cancelLock.lock()
        isCancelled = true
        cancelLock.unlock()
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

        _ = inputURL
        _ = seekMs
        _ = authorizationHeader
        _ = logHandler

        throw FFmpegRunnerError.exportUnavailable
    }
}

enum FFmpegRunnerError: LocalizedError {
    case executionFailed(code: Int)
    case cancelled
    case exportUnavailable

    var errorDescription: String? {
        switch self {
        case .executionFailed(let code):
            return "FFmpeg failed (exit \(code))."
        case .cancelled:
            return "Export cancelled."
        case .exportUnavailable:
            return """
            Segment export is temporarily unavailable on this iOS version. \
            The app can sign in and browse pCloud; a compatible FFmpeg build for iOS 26 is in progress. \
            Use a Mac/PC workflow from WORKFLOW.md until the next app update.
            """
        }
    }
}
