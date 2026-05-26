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

    /// The one and only allowed Keep Alive loop source (bundle, then Application Support cache, then compile-time embed).
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
            let url = try materializeEmbeddedSilence()
            guard let candidate = candidateIfPlayable(url) else {
                let bytes = fileByteCount(url)
                return .failure("embedded copy not playable (\(bytes) bytes at \(url.lastPathComponent))")
            }
            return .success(candidate)
        } catch {
            let bundleNote = bundleDiagnostic()
            return .failure("not in app bundle; embed install failed — \(error.localizedDescription). \(bundleNote)")
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
        let direct = root.appendingPathComponent(label)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let nested = root.appendingPathComponent("Resources").appendingPathComponent(label)
        if FileManager.default.fileExists(atPath: nested.path) { return nested }
        return nil
    }

    private static func installedSilenceURL() -> URL? {
        let url = installDirectory().appendingPathComponent(label)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static func materializeEmbeddedSilence() throws -> URL {
        let dest = installDirectory().appendingPathComponent(label)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path), fileByteCount(dest) >= minBytes {
            return dest
        }
        if let bundle = bundleSilenceURL() {
            try fm.createDirectory(at: installDirectory(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: bundle, to: dest)
            ExportRuntimeLog.mirror("Keep Alive: using bundle KeepAlive_silence.mp3")
            return dest
        }
        let data = KeepAliveSilenceEmbed.mp3Data
        guard data.count >= minBytes else {
            throw NSError(
                domain: "KeepAliveMediaSource",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "embedded MP3 too small (\(data.count) bytes)"]
            )
        }
        try fm.createDirectory(at: installDirectory(), withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
        ExportRuntimeLog.mirror(
            "Keep Alive: installed embedded KeepAlive_silence.mp3 (\(data.count) bytes) — bundle resource was missing"
        )
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
        guard let names = try? fm.contentsOfDirectory(atPath: resourcePath) else {
            return "cannot list bundle resources"
        }
        let mp3s = names.filter { $0.lowercased().hasSuffix(".mp3") }.sorted()
        if mp3s.isEmpty {
            return "no .mp3 in bundle root (\(resourcePath))"
        }
        return "bundle .mp3: \(mp3s.joined(separator: ", "))"
    }
}
