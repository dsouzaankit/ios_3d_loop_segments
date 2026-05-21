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
    @Published private(set) var activeExportItem: WebDAVItem?

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
        let session = try await PCloudAuth.fetchAuthSession(
            email: credentials.email,
            password: credentials.password,
            preferredRegion: credentials.region,
            session: .shared
        )
        updated.region = session.region
        updated.apiAuthToken = session.token
        updated.apiAuthHost = session.apiHost
        SearchDebugLog.log(
            "sign-in: API token saved len=\(session.token.count) host=\(session.apiHost) region=\(session.region.rawValue)"
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

        userRequestedExportCancel = false
        userRequestedExportPause = false
        exportCoordinator.userRequestedCancel = false
        exportCoordinator.userRequestedPause = false
        activeExportItem = item
        let priorResume = ResumeStore.shared.resumeStatus(for: item)
        let continueLANExport = priorResume.isPaused
            && priorResume.effectiveMs > 250
            && abs(priorResume.effectiveMs - seekMs) < 5_000
        let resumeCursorMs = continueLANExport ? priorResume.effectiveMs : nil
        ResumeStore.shared.beginExport(for: item, seekMs: seekMs)
        isExportRunning = true
        ExportAutoLockCoordinator.exportDidStart()
        defer {
            ExportAutoLockCoordinator.exportDidEnd()
            isExportRunning = false
            activeExportItem = nil
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
            WorkingSourceSparseCatalog.clearLANPlaybackStartHintAfterExportFinished(fileURL: ExportPaths.workingSourceURL)
            ResumeStore.shared.pinCompletedExportIfMediaOnDisk(for: item)
        } catch let error {
            if userRequestedExportCancel {
                ResumeStore.shared.finishExport(for: item)
            }
            // Pause / interrupt: checkpoint + exportInProgress stay until next Start export.
            throw error
        }
    }

    /// Stop export and clear paused state (removes published segment files).
    func cancelExport() {
        userRequestedExportCancel = true
        userRequestedExportPause = false
        exportCoordinator.userRequestedCancel = true
        exportCoordinator.userRequestedPause = false
        exportCoordinator.cancel()
        isExportRunning = false
        if let item = activeExportItem {
            ResumeStore.shared.finishExport(for: item)
        }
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
