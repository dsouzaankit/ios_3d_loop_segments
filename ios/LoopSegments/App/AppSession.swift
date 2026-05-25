import Foundation

@MainActor
final class AppSession: ObservableObject {
    @Published var credentials: WebDAVCredentials?
    @Published var isExportRunning = false
    /// WebDAV folder path stack for the browser (survives Export push/pop on the NavigationStack).
    @Published var browserPathStack: [String] = ["/"]

    private let credentialStore = CredentialStore()
    private(set) var userRequestedExportCancel = false
    private(set) var userRequestedExportPause = false
    /// Created on first export (lazy init for export stack).
    private lazy var exportCoordinator = ExportCoordinator()
    var isExportCoordinatorBusy: Bool { exportCoordinator.isBusy }
    @Published private(set) var activeExportItem: WebDAVItem?
    /// Bumped on each new export start / cancel so stale async unwinds cannot clobber state.
    private var exportGeneration = 0

    init() {
        credentials = credentialStore.load()
        WebDAVMediaSession.setActiveCredentials(credentials)
        Task { await refreshStoredAPIAccessIfNeeded() }
    }

    func signIn(region: PCloudRegion, email: String, password: String) async throws {
        let attempt = WebDAVCredentials(
            region: region,
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !attempt.email.isEmpty, !attempt.password.isEmpty else {
            throw WebDAVError.httpStatus(401)
        }

        let previous = credentials
        WebDAVMediaSession.setActiveCredentials(attempt)
        do {
            let verified = try await WebDAVSignIn.verify(credentials: attempt)
            PCloudWebDAVRootResolver.clearCache()
            credentialStore.save(verified)
            credentials = verified
            WebDAVMediaSession.setActiveCredentials(verified)
            UserDefaults.standard.set(verified.region.rawValue, forKey: "pcloud_region_last_sign_in")
            SearchDebugLog.log("sign-in: WebDAV OK — opening browser (API token loads in background for search)")
            let snapshot = verified
            Task { @MainActor in
                await self.finishSignInAPIEnrichment(snapshot)
            }
        } catch {
            WebDAVMediaSession.setActiveCredentials(previous)
            throw error
        }
    }

    func signOut() {
        credentialStore.clear()
        credentials = nil
        browserPathStack = ["/"]
        WebDAVMediaSession.setActiveCredentials(nil)
        PCloudWebDAVRootResolver.clearCache()
    }

    /// Refreshes API token / WebDAV files root before search (updates keychain + published credentials).
    func prepareCredentialsForSearch() async throws -> WebDAVCredentials? {
        guard var stored = credentials else { return nil }
        let needsToken = stored.apiAuthToken?.isEmpty != false
        let needsRoot = !PCloudWebDAVRootResolver.isValidFilesRoot(stored.webDAVFilesRoot)
        if needsToken {
            SearchDebugLog.log("search prepare: fetching pCloud API token (max 45s)…")
            do {
                stored = try await ExportAsyncTimeout.run(seconds: 45, operation: "pCloud API login") {
                    try await self.enrichWithAPIAccess(stored)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                SearchDebugLog.log("search prepare: API token failed — \(error.localizedDescription)")
            }
        } else if needsRoot {
            PCloudWebDAVRootResolver.clearCache()
            stored.webDAVFilesRoot = nil
            if let root = try? await PCloudWebDAVRootResolver.filesRoot(credentials: stored),
               PCloudWebDAVRootResolver.isValidFilesRoot(root) {
                stored.webDAVFilesRoot = root
                SearchDebugLog.log("search prepare: WebDAV files root=\(root)")
            }
        }
        persistCredentials(stored)
        return credentials
    }

    /// Keychain entries from before build 58 may lack API token / WebDAV root needed for search.
    private func refreshStoredAPIAccessIfNeeded() async {
        guard credentials != nil else { return }
        _ = try? await prepareCredentialsForSearch()
    }

    private func persistCredentials(_ stored: WebDAVCredentials) {
        credentialStore.save(stored)
        credentials = stored
        WebDAVMediaSession.setActiveCredentials(stored)
    }

    private func finishSignInAPIEnrichment(_ credentials: WebDAVCredentials) async {
        do {
            let enriched = try await enrichWithAPIAccess(credentials, discoverFilesRoot: false)
            persistCredentials(enriched)
        } catch {
            SearchDebugLog.log("sign-in: API token background failed — \(error.localizedDescription)")
        }
    }

    private func enrichWithAPIAccess(
        _ credentials: WebDAVCredentials,
        discoverFilesRoot: Bool = true
    ) async throws -> WebDAVCredentials {
        var updated = credentials
        let auth = try await PCloudAuth.fetchAuthSession(
            email: credentials.email,
            password: credentials.password,
            preferredRegion: credentials.region
        )
        updated.region = auth.region
        updated.apiAuthToken = auth.token
        updated.apiAuthHost = auth.apiHost
        SearchDebugLog.log(
            "sign-in: API token saved len=\(auth.token.count) host=\(auth.apiHost) region=\(auth.region.rawValue)"
        )
        if discoverFilesRoot {
            if let root = try? await PCloudWebDAVRootResolver.filesRoot(credentials: updated),
               PCloudWebDAVRootResolver.isValidFilesRoot(root) {
                updated.webDAVFilesRoot = root
            } else {
                updated.webDAVFilesRoot = nil
            }
        }
        return updated
    }

    func startExport(item: WebDAVItem, seekMs: Int64) async throws {
        guard let credentials else { throw ExportError.notSignedIn }
        guard !isExportRunning else { throw ExportError.jobAlreadyActive }
        for _ in 0 ..< 300 where exportCoordinator.isBusy {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !exportCoordinator.isBusy else { throw ExportError.stillStopping }

        exportGeneration += 1
        let generation = exportGeneration

        userRequestedExportCancel = false
        userRequestedExportPause = false
        exportCoordinator.userRequestedCancel = false
        exportCoordinator.userRequestedPause = false
        activeExportItem = item
        LANExportSourceDisplay.setRunning(item.name)
        let priorResume = ResumeStore.shared.resumeStatus(for: item)
        let continueLANExport = priorResume.isPaused
            && priorResume.effectiveMs > 250
            && abs(priorResume.effectiveMs - seekMs) < 5_000
        let resumeCursorMs = continueLANExport ? priorResume.effectiveMs : nil
        ResumeStore.shared.beginExport(for: item, seekMs: seekMs)
        isExportRunning = true
        ExportAutoLockCoordinator.exportDidStart()
        defer {
            if generation == exportGeneration {
                ExportAutoLockCoordinator.exportDidEnd()
                isExportRunning = false
                activeExportItem = nil
            }
        }

        let onProgress: @Sendable (Int64) -> Void = { mediaMs in
            Task { @MainActor in
                ResumeStore.shared.saveCheckpoint(mediaMs: mediaMs, for: item)
            }
        }

        do {
            let result = try await exportCoordinator.run(
                item: item,
                credentials: credentials,
                seekMs: seekMs,
                continueLANExport: continueLANExport,
                resumeCursorMs: resumeCursorMs,
                onMediaProgress: onProgress
            )
            let resumeMs: Int64 = result.reachedEnd ? 0 : result.lastMediaTimeMs
            ResumeStore.shared.saveSeekMs(resumeMs, for: item)
            ResumeStore.shared.finishExport(for: item)
            ResumeStore.shared.pinCompletedExportIfMediaOnDisk(for: item)
            if generation == exportGeneration {
                LANExportSourceDisplay.setFinished(item.name)
            }
        } catch let error {
            guard generation == exportGeneration else { throw error }
            if userRequestedExportPause {
                LANExportSourceDisplay.setPaused(item.name)
            } else if userRequestedExportCancel {
                LANExportSourceDisplay.clearActive()
            } else if ResumeStore.shared.exportWasInterrupted(for: item) {
                LANExportSourceDisplay.setPaused(item.name)
            } else {
                LANExportSourceDisplay.clearActive()
            }
            if userRequestedExportCancel {
                ResumeStore.shared.finishExport(for: item)
            }
            // Pause / interrupt: checkpoint + exportInProgress stay until next Start export.
            throw error
        }
    }

    /// Stop export and clear paused state (removes loop/ segments; archives root working/vanilla copies).
    func cancelExport() {
        let cleanupAfterCoordinator = isExportRunning || exportCoordinator.isBusy
        exportGeneration += 1
        userRequestedExportCancel = true
        userRequestedExportPause = false
        exportCoordinator.userRequestedCancel = true
        exportCoordinator.userRequestedPause = false
        exportCoordinator.cancel()
        isExportRunning = false
        if let item = activeExportItem {
            ResumeStore.shared.finishExport(for: item)
        } else if let entry = ResumeStore.mostRecentPausedExport(),
                  let href = entry.href?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !href.isEmpty {
            let name = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let item = WebDAVItem(href: href, name: name, isDirectory: false, contentLength: nil)
                ResumeStore.shared.finishExport(for: item)
            }
        }
        LANExportSourceDisplay.clearActive()
        if !cleanupAfterCoordinator {
            Task {
                await SegmentCleanup.performStopCleanup(log: { SearchDebugLog.log("Stop: \($0)") })
            }
        }
    }

    /// Mirrors Export UI **Clear media** (permanent; not export logs).
    @discardableResult
    func clearExportMedia(referenceItem: WebDAVItem) -> Int {
        guard !isExportRunning, !exportCoordinator.isBusy else { return 0 }
        ResumeStore.shared.clearPinnedCompletedExports()
        ResumeStore.shared.clearPausedExports()
        ResumeStore.shared.finishExport(for: referenceItem)
        return SegmentCleanup.removeExportMedia(log: { SearchDebugLog.log("Clear media: \($0)") })
    }

    /// Mirrors Export UI **Trim media (keep last 2)**.
    @discardableResult
    func trimExportMediaArchives() -> Int {
        guard !isExportRunning, !exportCoordinator.isBusy else { return 0 }
        return SegmentCleanup.trimExportMediaArchives(log: { SearchDebugLog.log("Trim media: \($0)") })
    }

    /// Pause export: saves checkpoint, keeps export marked paused, keeps media on disk.
    func pauseExport() {
        guard isExportRunning else { return }
        userRequestedExportPause = true
        userRequestedExportCancel = false
        exportCoordinator.userRequestedPause = true
        exportCoordinator.userRequestedCancel = false
        exportCoordinator.cancel()
        isExportRunning = false
        if let item = activeExportItem {
            LANExportSourceDisplay.setPaused(item.name)
        }
    }

    /// Stop any in-flight export so a LAN-page fresh start can proceed.
    func prepareForLANFreshExport() async {
        if isExportRunning {
            cancelExport()
        } else if exportCoordinator.isBusy {
            exportGeneration += 1
            userRequestedExportCancel = true
            userRequestedExportPause = false
            exportCoordinator.userRequestedCancel = true
            exportCoordinator.userRequestedPause = false
            exportCoordinator.cancel()
            isExportRunning = false
        }
        for _ in 0 ..< 300 where exportCoordinator.isBusy {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

enum ExportError: LocalizedError {
    case notSignedIn
    case jobAlreadyActive
    case stillStopping

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to pCloud first."
        case .jobAlreadyActive: return "An export is already running."
        case .stillStopping: return "Previous export is still stopping — wait a moment and tap Start again."
        }
    }
}
