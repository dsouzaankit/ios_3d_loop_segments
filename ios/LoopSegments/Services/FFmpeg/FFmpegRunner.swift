import Foundation
import ffmpegkit

/// Segment remux via ffmpeg-kit (stream copy, -re, segment wrap 2).
final class FFmpegRunner {
    private let cancelLock = NSLock()
    private var isCancelled = false

    func cancel() {
        cancelLock.lock()
        isCancelled = true
        cancelLock.unlock()
        FFmpegKit.cancel()
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

        logHandler(SegmentCopyCommand.commandLine(
            inputURL: inputURL,
            seekSeconds: seekSec,
            outputPath: outputPath,
            authorizationHeader: authorizationHeader
        ))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            FFmpegKit.execute(
                withArgumentsAsync: args,
                withCompleteCallback: { session in
                    if self.checkCancelled() {
                        continuation.resume(throwing: FFmpegRunnerError.cancelled)
                        return
                    }
                    guard let session else {
                        continuation.resume(throwing: FFmpegRunnerError.executionFailed(code: -1))
                        return
                    }
                    let returnCode = session.getReturnCode()
                    if ReturnCode.isSuccess(returnCode) {
                        continuation.resume()
                    } else if ReturnCode.isCancel(returnCode) {
                        continuation.resume(throwing: FFmpegRunnerError.cancelled)
                    } else {
                        let code = Int(returnCode?.getValue() ?? -1)
                        continuation.resume(throwing: FFmpegRunnerError.executionFailed(code: code))
                    }
                },
                withLogCallback: { log in
                    guard let message = log?.getMessage() else { return }
                    let line = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty { logHandler(line) }
                },
                withStatisticsCallback: { _ in }
            )
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
