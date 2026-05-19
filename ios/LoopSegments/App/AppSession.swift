import Foundation

@MainActor
final class AppSession: ObservableObject {
    @Published var credentials: WebDAVCredentials?
    @Published var isExportRunning = false

    private let credentialStore = CredentialStore()
    private(set) var userRequestedExportCancel = false
    /// Created on first export (lazy init for export stack).
    private lazy var exportCoordinator = ExportCoordinator()
    private var activeExportItem: WebDAVItem?

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
            var verified = try await WebDAVSignIn.verify(credentials: attempt)
            PCloudWebDAVRootResolver.clearCache()
            do {
                verified = try await enrichWithAPIAccess(verified)
            } catch {
                SearchDebugLog.log("sign-in: WebDAV OK but API token failed — \(error.localizedDescription)")
            }
            credentialStore.save(verified)
            credentials = verified
            WebDAVMediaSession.setActiveCredentials(verified)
            UserDefaults.standard.set(verified.region.rawValue, forKey: "pcloud_region_last_sign_in")
        } catch {
            WebDAVMediaSession.setActiveCredentials(previous)
            throw error
        }
    }

    func signOut() {
        credentialStore.clear()
        credentials = nil
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

    private func enrichWithAPIAccess(_ credentials: WebDAVCredentials) async throws -> WebDAVCredentials {
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
        if let root = try? await PCloudWebDAVRootResolver.filesRoot(credentials: updated),
           PCloudWebDAVRootResolver.isValidFilesRoot(root) {
            updated.webDAVFilesRoot = root
        } else {
            updated.webDAVFilesRoot = nil
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
        exportCoordinator.userRequestedCancel = false
        activeExportItem = item
        ResumeStore.shared.beginExport(for: item, seekMs: seekMs)
        isExportRunning = true
        defer {
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
                onMediaProgress: onProgress
            )
            let resumeMs: Int64 = result.reachedEnd ? 0 : result.lastMediaTimeMs
            ResumeStore.shared.saveSeekMs(resumeMs, for: item)
            ResumeStore.shared.finishExport(for: item)
        } catch {
            if userRequestedExportCancel {
                ResumeStore.shared.finishExport(for: item)
            }
            throw
        }
    }

    func cancelExport() {
        userRequestedExportCancel = true
        exportCoordinator.userRequestedCancel = true
        exportCoordinator.cancel()
        isExportRunning = false
        if let item = activeExportItem {
            ResumeStore.shared.finishExport(for: item)
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
