import Foundation

/// Documents the segment contract (legacy PC ffmpeg used MKV; production iOS uses AVFoundation; `ios-ffmpeg/` uses kewlbear/FFmpeg-iOS).
enum SegmentCopyCommand {
    static let segmentTimeSeconds = 60
    static let segmentWrap = 2

    static func buildArguments(
        inputURL: URL,
        seekSeconds: Double,
        outputPath: String,
        authorizationHeader: String
    ) -> [String] {
        let seek = String(format: "%.6f", seekSeconds)
        let headers = "Authorization: \(authorizationHeader)\r\n"
        return [
            "-hide_banner", "-y",
            "-ss", seek,
            "-re",
            "-headers", headers,
            "-i", inputURL.absoluteString,
            "-map", "0:v",
            "-map", "0:a?",
            "-c", "copy",
            "-f", "segment",
            "-segment_time", "\(segmentTimeSeconds)",
            "-segment_wrap", "\(segmentWrap)",
            "-reset_timestamps", "1",
            outputPath
        ]
    }

    static func commandLine(
        inputURL: URL,
        seekSeconds: Double,
        outputPath: String,
        authorizationHeader: String
    ) -> String {
        let args = buildArguments(
            inputURL: inputURL,
            seekSeconds: seekSeconds,
            outputPath: outputPath,
            authorizationHeader: authorizationHeader
        )
        return (["ffmpeg"] + args).map(shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ arg: String) -> String {
        if arg.contains(" ") || arg.contains("\"") {
            return "\"" + arg.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return arg
    }
}
