import Foundation

/// Bundled silence MP3 for Keep Alive (`KeepAlive_silence.mp3` in `LoopSegments/Resources/`).
enum KeepAliveMediaSource {
    struct Candidate: Equatable {
        let url: URL
        let label: String
    }

    private static let fileName = "KeepAlive_silence"
    private static let fileExtension = "mp3"
    private static let label = "KeepAlive_silence.mp3"
    private static let minBytes: Int64 = 4_096

    /// The one and only allowed Keep Alive loop source (app bundle, then Application Support cache).
    static func firstPlayable() -> Candidate? {
        switch resolve() {
        case .success(let candidate):
            return candidate
        case .failure:
            return nil
        }
    }

    /// Human-readable reason when `firstPlayable()` is nil (logged to export_latest.txt).
    static func failureReason() -> String {
        switch resolve() {
        case .success:
            return "ok"
        case .failure(let reason):
            return reason
        }
    }

    private enum ResolveResult {
        case success(Candidate)
        case failure(String)
    }

    private static func resolve() -> ResolveResult {
        if let url = bundleSilenceURL(), let candidate = candidateIfPlayable(url) {
            return .success(candidate)
        }
        if let url = installedSilenceURL(), let candidate = candidateIfPlayable(url) {
            return .success(candidate)
        }
        do {
            let url = try installFromBundle()
            guard let candidate = candidateIfPlayable(url) else {
                let bytes = fileByteCount(url)
                return .failure("cached copy not playable (\(bytes) bytes)")
            }
            return .success(candidate)
        } catch {
            return .failure(
                "not in app bundle (\(error.localizedDescription)). \(bundleDiagnostic())"
            )
        }
    }

    private static func bundleSilenceURL() -> URL? {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: fileName, withExtension: fileExtension) {
            return url
        }
        if let url = bundle.url(
            forResource: fileName,
            withExtension: fileExtension,
            subdirectory: "Resources"
        ) {
            return url
        }
        guard let resourcePath = bundle.resourcePath else { return nil }
        let root = URL(fileURLWithPath: resourcePath, isDirectory: true)
        for candidate in candidatePaths(in: root) {
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let file as URL in enumerator {
                if file.lastPathComponent == label { return file }
            }
        }
        return nil
    }

    private static func candidatePaths(in root: URL) -> [URL] {
        [
            root.appendingPathComponent(label),
            root.appendingPathComponent("Resources").appendingPathComponent(label),
        ]
    }

    private static func installedSilenceURL() -> URL? {
        let url = installDirectory().appendingPathComponent(label)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static func installFromBundle() throws -> URL {
        let dest = installDirectory().appendingPathComponent(label)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path), fileByteCount(dest) >= minBytes {
            return dest
        }
        guard let bundle = bundleSilenceURL() else {
            throw NSError(
                domain: "KeepAliveMediaSource",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "KeepAlive_silence.mp3 not found in app"]
            )
        }
        try fm.createDirectory(at: installDirectory(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: bundle, to: dest)
        ExportRuntimeLog.mirror("Keep Alive: cached \(label) from app bundle")
        return dest
    }

    private static func installDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("KeepAlive", isDirectory: true)
    }

    private static func candidateIfPlayable(_ url: URL) -> Candidate? {
        guard isPlayableLocalMedia(url) else { return nil }
        return Candidate(url: url, label: label)
    }

    static func isPlayableLocalMedia(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        guard fileByteCount(url) >= minBytes else { return false }
        let ext = url.pathExtension.lowercased()
        guard ["mp4", "m4v", "mov", "m4a", "aac", "caf", "wav", "mp3"].contains(ext) else {
            return false
        }
        return true
    }

    private static func fileByteCount(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber else { return 0 }
        return n.int64Value
    }

    private static func bundleDiagnostic() -> String {
        guard let resourcePath = Bundle.main.resourcePath else {
            return "Bundle.main.resourcePath nil"
        }
        let fm = FileManager.default
        var mp3s: [String] = []
        if let names = try? fm.contentsOfDirectory(atPath: resourcePath) {
            mp3s.append(contentsOf: names.filter { $0.lowercased().hasSuffix(".mp3") })
        }
        if let enumerator = fm.enumerator(atPath: resourcePath) {
            for case let name as String in enumerator where name.lowercased().hasSuffix(".mp3") {
                mp3s.append(name)
            }
        }
        let unique = Array(Set(mp3s)).sorted()
        if unique.isEmpty {
            return "no .mp3 under \(resourcePath)"
        }
        return "bundle .mp3: \(unique.joined(separator: ", "))"
    }
}
