import Foundation

@MainActor
final class AppSession: ObservableObject {
    @Published var credentials: WebDAVCredentials?
    @Published var isExportRunning = false
    /// Published so Browse/export UI refresh when coordinator busy toggles without `isExportRunning`.
    @Published private(set) var isExportSessionActive = false
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
    /// Survives leaving Export screen — must not be tied to `ExportView` lifetime.
    private var exportUITask: Task<Void, Never>?
    private var exportAutoPauseTask: Task<Void, Never>?
    private var urlDownloadTask: Task<Void, Never>?
    private var urlDownloadCancelRequested = false
    @Published private(set) var isURLDownloadRunning = false

    /// File key for the export in flight (survives brief `activeExportItem` nil while coordinator winds down).
    var activeExportFileKey: String? {
        if let activeExportItem { return activeExportItem.fileKey }
        guard isExportSessionActive else { return nil }
        return ResumeStore.shared.interruptedEntries().first?.fileKey
    }

    /// Item for sticky export banner / navigation (falls back to paused-in-progress resume entry).
    var activeExportDisplayItem: WebDAVItem? {
        if let activeExportItem { return activeExportItem }
        guard isExportSessionActive else { return nil }
        return Self.webDAVItem(from: ResumeStore.shared.interruptedEntries().first)
    }

    /// True while this file is exporting (including after leaving Export UI).
    func isExportActive(for item: WebDAVItem) -> Bool {
        guard isExportSessionActive else { return false }
        if let active = activeExportItem, active.fileKey == item.fileKey { return true }
        return ResumeStore.shared.exportWasInterrupted(for: item)
    }

    private func syncExportSessionActive() {
        isExportSessionActive = isExportRunning || exportCoordinator.isBusy
    }

    /// Runs export work on the session so navigation away from Export does not cancel it.
    func runExportUITask(_ operation: @escaping @MainActor () async -> Void) {
        exportUITask?.cancel()
        exportUITask = Task { await operation() }
    }

    func cancelExportUITask() {
        exportUITask?.cancel()
        exportUITask = nil
    }

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

    /// Refreshes WebDAV files root before search; API token only when REST search is enabled.
    func prepareCredentialsForSearch() async throws -> WebDAVCredentials? {
        guard var stored = credentials else { return nil }
        let needsToken = stored.apiAuthToken?.isEmpty != false
        let needsRoot = !PCloudWebDAVRootResolver.isValidFilesRoot(stored.webDAVFilesRoot)
        if needsToken {
            if PCloudSearchSettings.restAPISearchEnabled {
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
            } else {
                SearchDebugLog.log(
                    "search prepare: REST search off — skipping API token (WebDAV search / resume)"
                )
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
        // Paused resume (incl. timed auto-pause): keep on-disk media/logs; ignore UI seek drift.
        // Vanilla WebDAV fill can resume from partial bytes even when checkpoint/Start at is still 0:00.
        let continueLANExport = priorResume.isPaused
            && (priorResume.effectiveMs > 250 || ExportPaths.hasResumableVanillaDownload(for: item))
        let seekMsForRun = continueLANExport ? priorResume.effectiveMs : seekMs
        let resumeCursorMs = continueLANExport ? priorResume.effectiveMs : nil
        ResumeStore.shared.beginExport(for: item, seekMs: seekMsForRun)
        isExportRunning = true
        syncExportSessionActive()
        ExportAutoLockCoordinator.exportDidStart()
        ExportBackgroundKeepAlive.shared.beginExportSession(exportTitle: item.name)
        exportAutoPauseTask?.cancel()
        exportAutoPauseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(ExportAutoPauseSettings.timeoutSeconds * 1_000_000_000))
            guard generation == self.exportGeneration else { return }
            guard self.isExportRunning else { return }
            guard !self.userRequestedExportPause, !self.userRequestedExportCancel else { return }
            ExportRuntimeLog.mirror(ExportAutoPauseSettings.autoPauseLogLine)
            self.pauseExport()
        }
        defer {
            if generation == exportGeneration {
                exportAutoPauseTask?.cancel()
                exportAutoPauseTask = nil
                ExportBackgroundKeepAlive.shared.endExportSession()
                ExportAutoLockCoordinator.exportDidEnd()
                isExportRunning = false
                syncExportSessionActive()
                clearActiveExportItemWhenIdle(generation: generation)
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
                seekMs: seekMsForRun,
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
            if exportCoordinator.isBusy {
                // Task/view cancelled while coordinator still exporting — keep LAN on "running".
                LANExportSourceDisplay.setRunning(item.name)
            } else if userRequestedExportPause {
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

    private func clearActiveExportItemWhenIdle(generation: Int) {
        guard exportCoordinator.isBusy else {
            if generation == exportGeneration {
                activeExportItem = nil
                syncExportSessionActive()
            }
            return
        }
        Task { @MainActor in
            for _ in 0 ..< 300 where exportCoordinator.isBusy {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if generation == exportGeneration {
                activeExportItem = nil
                syncExportSessionActive()
            }
        }
    }

    private static func webDAVItem(from entry: ResumeEntry?) -> WebDAVItem? {
        guard let entry,
              let href = entry.href?.trimmingCharacters(in: .whitespacesAndNewlines),
              !href.isEmpty else { return nil }
        let name = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return WebDAVItem(href: href, name: name, isDirectory: false, contentLength: nil)
    }

    /// Stop export and clear paused state (removes loop/ segments; archives root working/vanilla copies).
    func cancelExport() {
        exportAutoPauseTask?.cancel()
        exportAutoPauseTask = nil
        cancelExportUITask()
        let cleanupAfterCoordinator = isExportRunning || exportCoordinator.isBusy
        exportGeneration += 1
        userRequestedExportCancel = true
        userRequestedExportPause = false
        exportCoordinator.userRequestedCancel = true
        exportCoordinator.userRequestedPause = false
        exportCoordinator.cancel()
        isExportRunning = false
        syncExportSessionActive()
        ExportBackgroundKeepAlive.shared.endExportSession()
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

    /// LAN / in-app HTTP(S) download into `pcld_ios_media/downloads/<saveName>`.
    func startURLDownload(remoteURL: URL, saveName: String) async throws {
        guard !isURLDownloadRunning else { throw ExportError.urlDownloadAlreadyActive }
        guard let safeName = URLMediaDownload.sanitizeSaveFileName(saveName, sourceURL: remoteURL) else {
            throw URLMediaDownload.DownloadError.invalidSaveName
        }

        urlDownloadCancelRequested = false
        isURLDownloadRunning = true
        defer { isURLDownloadRunning = false }

        ExportRuntimeLog.mirror("URL download start — \(remoteURL.absoluteString) → downloads/\(safeName)")
        _ = try await URLMediaDownload.download(
            remoteURL: remoteURL,
            saveName: safeName,
            isCancelled: { [weak self] in
                self?.urlDownloadCancelRequested == true
            },
            log: { ExportRuntimeLog.mirror($0) }
        )
    }

    func cancelURLDownload() {
        urlDownloadCancelRequested = true
        urlDownloadTask?.cancel()
        urlDownloadTask = nil
    }

    /// Pause export: saves checkpoint, keeps export marked paused, keeps media on disk.
    func pauseExport() {
        guard isExportRunning else { return }
        exportAutoPauseTask?.cancel()
        exportAutoPauseTask = nil
        userRequestedExportPause = true
        userRequestedExportCancel = false
        exportCoordinator.userRequestedPause = true
        exportCoordinator.userRequestedCancel = false
        exportCoordinator.cancel()
        isExportRunning = false
        syncExportSessionActive()
        ExportBackgroundKeepAlive.shared.endExportSession()
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
            syncExportSessionActive()
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
    case urlDownloadAlreadyActive

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to pCloud first."
        case .jobAlreadyActive: return "An export is already running."
        case .stillStopping: return "Previous export is still stopping — wait a moment and tap Start again."
        case .urlDownloadAlreadyActive: return "A URL download is already running."
        }
    }
}
