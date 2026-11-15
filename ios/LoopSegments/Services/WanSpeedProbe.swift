import Foundation

/// Timed pCloud WAN download (random video, ~30 s of Range GETs) → Mbps for the LAN page.
/// Uses the same WebDAV path as export (cellular allowed). Temp bytes are discarded.
enum WanSpeedProbe {
    static let durationSeconds: TimeInterval = 30
    /// Ceiling bandwidth used when sizing candidates: 100 Mbps × 30 s ≈ 375 MB.
    static let designMaxMbps: Double = 100
    private static let chunkBytes: Int64 = 2 * 1024 * 1024
    /// Must sustain a full `durationSeconds` at `designMaxMbps` (375 MiB ≈ 100 Mbps × 30 s + slack).
    static let minCandidateBytes: Int64 = 375 * 1024 * 1024
    private static let measureMethod = "http-wan-page"

    private static let lock = NSLock()
    private static var lastResult: ResultSnapshot = .idle
    private static var inFlight = false

    struct ResultSnapshot: Sendable {
        var ok: Bool?
        var running: Bool
        var checkedAt: Date?
        var measuredMbps: Double?
        var transferredBytes: Int64?
        var elapsedSeconds: Double?
        var displayName: String?
        var sourcePath: String?
        var folderPath: String?
        var error: String?
        var measureMethod: String

        static let idle = ResultSnapshot(
            ok: nil,
            running: false,
            checkedAt: nil,
            measuredMbps: nil,
            transferredBytes: nil,
            elapsedSeconds: nil,
            displayName: nil,
            sourcePath: nil,
            folderPath: nil,
            error: nil,
            measureMethod: WanSpeedProbe.measureMethod
        )

        func statusJSON() -> [String: Any] {
            var payload: [String: Any] = [
                "running": running,
                "measureMethod": measureMethod,
                "durationSeconds": WanSpeedProbe.durationSeconds,
                "minCandidateBytes": WanSpeedProbe.minCandidateBytes,
                "designMaxMbps": WanSpeedProbe.designMaxMbps,
            ]
            if let ok {
                payload["ok"] = ok
            } else {
                payload["ok"] = NSNull()
            }
            if let checkedAt {
                payload["checkedAt"] = ISO8601DateFormatter().string(from: checkedAt)
            }
            if let measuredMbps {
                payload["measuredMbps"] = (measuredMbps * 100).rounded() / 100
            }
            if let transferredBytes {
                payload["transferredBytes"] = transferredBytes
            }
            if let elapsedSeconds {
                payload["elapsedSeconds"] = (elapsedSeconds * 1000).rounded() / 1000
            }
            if let displayName {
                payload["displayName"] = displayName
            }
            if let sourcePath {
                payload["sourcePath"] = sourcePath
            }
            if let folderPath {
                payload["folderPath"] = folderPath
            }
            if let error {
                payload["error"] = error
            }
            return payload
        }
    }

    static func currentSnapshot() -> ResultSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return lastResult
    }

    /// Blocks the calling thread (LAN POST handler). Safe to call from a background queue.
    @discardableResult
    static func runBlocking(folderPath: String? = nil) -> ResultSnapshot {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome = ResultSnapshot.idle
        Task {
            outcome = await run(folderPath: folderPath)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + durationSeconds + 45)
        return outcome
    }

    static func run(folderPath: String? = nil) async -> ResultSnapshot {
        lock.lock()
        if inFlight {
            let busy = lastResult
            lock.unlock()
            var copy = busy
            copy.running = true
            copy.error = copy.error ?? "WAN speed test already running"
            return copy
        }
        inFlight = true
        var runningSnap = ResultSnapshot.idle
        runningSnap.running = true
        runningSnap.ok = nil
        runningSnap.checkedAt = Date()
        lastResult = runningSnap
        lock.unlock()

        let finished: ResultSnapshot
        do {
            finished = try await measureOnce(folderPath: folderPath)
        } catch {
            finished = ResultSnapshot(
                ok: false,
                running: false,
                checkedAt: Date(),
                measuredMbps: nil,
                transferredBytes: nil,
                elapsedSeconds: nil,
                displayName: nil,
                sourcePath: nil,
                folderPath: folderPath,
                error: error.localizedDescription,
                measureMethod: measureMethod
            )
        }

        lock.lock()
        inFlight = false
        lastResult = finished
        lock.unlock()
        return finished
    }

    private enum ProbeError: LocalizedError {
        case notSignedIn
        case noVideos
        case tooSmall
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Not signed in to pCloud on the phone."
            case .noVideos:
                let mb = WanSpeedProbe.minCandidateBytes / (1024 * 1024)
                return "No videos ≥ \(mb) MB (need \(Int(WanSpeedProbe.durationSeconds))s at \(Int(WanSpeedProbe.designMaxMbps)) Mbps) in bookmarks or the chosen folder."
            case .tooSmall:
                return "Downloaded too little in \(Int(WanSpeedProbe.durationSeconds))s to measure."
            case .cancelled:
                return "WAN speed test cancelled."
            }
        }
    }

    private static func measureOnce(folderPath: String?) async throws -> ResultSnapshot {
        guard let credentials = CredentialStore().load() else {
            throw ProbeError.notSignedIn
        }
        WebDAVMediaSession.setActiveCredentials(credentials)

        let pick = try await pickRandomVideo(folderPath: folderPath, credentials: credentials)
        let auth = WebDAVAuth.provider(fallback: credentials)
        let (remoteURL, item) = try await WebDAVAccessProbe.resolveMediaURL(
            for: pick.item,
            credentials: credentials,
            authorization: auth,
            log: nil
        )

        let totalLength = item.contentLength ?? 0
        let deadline = Date().addingTimeInterval(durationSeconds)
        let started = Date()
        var offset: Int64 = 0
        var transferred: Int64 = 0

        while Date() < deadline {
            if Task.isCancelled { throw ProbeError.cancelled }
            let remainingWindow = deadline.timeIntervalSinceNow
            if remainingWindow <= 0 { break }

            let end: Int64
            if totalLength > 0 {
                if offset >= totalLength { break }
                end = min(offset + chunkBytes - 1, totalLength - 1)
            } else {
                end = offset + chunkBytes - 1
            }
            if end < offset { break }

            let data = try await WebDAVTempFileDownload.fetchRemoteRange(
                remoteURL: remoteURL,
                authorization: auth(),
                offset: offset,
                endInclusive: end,
                log: nil
            )
            let n = Int64(data.count)
            if n <= 0 { break }
            transferred += n
            offset += n
            if totalLength > 0, offset >= totalLength { break }
            // Full-file GET without length: stop after one large chunk burst window.
            if totalLength <= 0, transferred >= chunkBytes * 8 { break }
        }

        let elapsed = max(Date().timeIntervalSince(started), 0.001)
        guard transferred >= 256 * 1024 else { throw ProbeError.tooSmall }
        let mbps = (Double(transferred) * 8.0) / (elapsed * 1_000_000.0)

        return ResultSnapshot(
            ok: true,
            running: false,
            checkedAt: Date(),
            measuredMbps: mbps,
            transferredBytes: transferred,
            elapsedSeconds: elapsed,
            displayName: item.name,
            sourcePath: item.href,
            folderPath: pick.folderPath,
            error: nil,
            measureMethod: measureMethod
        )
    }

    private static func pickRandomVideo(
        folderPath: String?,
        credentials: WebDAVCredentials
    ) async throws -> (item: WebDAVItem, folderPath: String) {
        var candidates: [WebDAVItem] = []
        var usedFolder = "/"

        if let raw = folderPath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let folder = WebDAVURLBuilder.directoryListingPath(raw)
            usedFolder = folder
            candidates = try await AlternateExportFilePicker.listVideos(in: folder, credentials: credentials)
        } else {
            let bookmarks = await MainActor.run { FolderBookmarkStore.shared.bookmarks() }
            if !bookmarks.isEmpty {
                var seen = Set<String>()
                for bookmark in bookmarks {
                    let videos = try await AlternateExportFilePicker.listVideos(
                        in: bookmark.listingPath,
                        credentials: credentials
                    )
                    for video in videos where seen.insert(video.fileKey).inserted {
                        candidates.append(video)
                    }
                }
                usedFolder = "bookmarks"
            } else {
                usedFolder = "/"
                candidates = try await AlternateExportFilePicker.listVideos(in: "/", credentials: credentials)
            }
        }

        // Do not fall back to smaller files — a short file ends the probe early and under-reads Mbps.
        let eligible = candidates.filter { ($0.contentLength ?? 0) >= minCandidateBytes }
        guard let picked = eligible.randomElement() else { throw ProbeError.noVideos }
        return (picked, usedFolder)
    }
}
