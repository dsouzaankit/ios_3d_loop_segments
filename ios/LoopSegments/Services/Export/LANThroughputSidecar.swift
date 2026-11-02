import Foundation

/// Same recommendation sidecars as `Measure-LoopSegmentsLanThroughput.ps1` (HTTP-only / LAN page path).
enum LANThroughputSidecar {
    static let schema = "loopsegments-lan-throughput/v1"
    static let headroomFactor = 0.8
    static let recommendMinMbps = 5
    static let recommendMaxMbps = 100
    static let defaultMinLanThroughputMbps = 40.0
    /// Match Measure defaults for candidate / transfer sizing (browser Range GET).
    static let minCandidateBytes: Int64 = 8 * 1024 * 1024
    static let maxTransferBytes: Int64 = 64 * 1024 * 1024

    struct Measurement {
        var measuredMbps: Double
        var transferredBytes: Int64
        var elapsedSeconds: Double
        var sourceUrl: String?
        var sourcePath: String?
        var phoneLanHost: String?
        var phoneLanBaseUrl: String?
        var minLanThroughputMbps: Double
        var note: String
    }

    private static var scriptsSidecarURL: URL {
        ExportPaths.lanExportScriptsDirectory.appendingPathComponent("lan_throughput.json")
    }

    private static var archiveSidecarURL: URL {
        let dir = ExportPaths.mediaExportDirectory.appendingPathComponent("archive", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lan_recommended_segment_bitrate.json")
    }

    private static var rootSidecarURL: URL {
        ExportPaths.mediaExportDirectory.appendingPathComponent("lan_recommended_segment_bitrate.json")
    }

    static var primarySidecarURL: URL { scriptsSidecarURL }

    static func recommendedMaxMediaBitrateMbps(measuredMbps: Double) -> Int {
        var recommended = Int(floor(measuredMbps * headroomFactor))
        if recommended < recommendMinMbps { recommended = recommendMinMbps }
        if recommended > recommendMaxMbps { recommended = recommendMaxMbps }
        return recommended
    }

    static func payload(from measurement: Measurement) -> [String: Any] {
        let recommended = recommendedMaxMediaBitrateMbps(measuredMbps: measurement.measuredMbps)
        var payload: [String: Any] = [
            "schema": schema,
            "measureMethod": "http-lan-page",
            "measuredMbps": (measurement.measuredMbps * 100).rounded() / 100,
            "measuredHttpMbps": (measurement.measuredMbps * 100).rounded() / 100,
            "measuredMountMbps": NSNull(),
            "recommendedMaxMediaBitrateMbps": recommended,
            "minLanThroughputMbps": measurement.minLanThroughputMbps,
            "headroomFactor": headroomFactor,
            "measuredAtUtc": ISO8601DateFormatter().string(from: Date()),
            "transferredBytes": measurement.transferredBytes,
            "elapsedSeconds": (measurement.elapsedSeconds * 1000).rounded() / 1000,
            "note": measurement.note,
        ]
        if let host = measurement.phoneLanHost, !host.isEmpty {
            payload["phoneLanHost"] = host
        } else {
            payload["phoneLanHost"] = NSNull()
        }
        if let base = measurement.phoneLanBaseUrl, !base.isEmpty {
            payload["phoneLanBaseUrl"] = base
        } else {
            payload["phoneLanBaseUrl"] = NSNull()
        }
        if let path = measurement.sourcePath, !path.isEmpty {
            payload["sourcePath"] = path
        } else {
            payload["sourcePath"] = NSNull()
        }
        payload["mountSourcePath"] = NSNull()
        if let url = measurement.sourceUrl, !url.isEmpty {
            payload["sourceUrl"] = url
        } else {
            payload["sourceUrl"] = NSNull()
        }
        return payload
    }

    @discardableResult
    static func write(_ measurement: Measurement) throws -> [String: Any] {
        let payload = payload(from: measurement)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let urls = [scriptsSidecarURL, archiveSidecarURL, rootSidecarURL]
        for url in urls {
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return payload
    }

    static func readPrimary() -> [String: Any]? {
        let url = primarySidecarURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return nil
        }
        return dict
    }
}
