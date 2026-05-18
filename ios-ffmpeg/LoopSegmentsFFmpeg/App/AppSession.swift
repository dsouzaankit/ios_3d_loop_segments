import Foundation

@MainActor
final class AppSession: ObservableObject {
    @Published var credentials: WebDAVCredentials?
    @Published var isExportRunning = false

    private let credentialStore = CredentialStore()
    private(set) var userRequestedExportCancel = false
    private lazy var exportCoordinator = ExportCoordinator()

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
            verified = try await enrichWithAPIAccess(verified)
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

    private func refreshStoredAPIAccessIfNeeded() async {
        guard var stored = credentials else { return }
        let needsToken = stored.apiAuthToken?.isEmpty != false
        let needsRoot = stored.webDAVFilesRoot?.isEmpty != false
        guard needsToken || needsRoot else { return }
        stored = (try? await enrichWithAPIAccess(stored)) ?? stored
        if stored.apiAuthToken != credentials?.apiAuthToken
            || stored.webDAVFilesRoot != credentials?.webDAVFilesRoot
            || stored.region != credentials?.region {
            credentialStore.save(stored)
            credentials = stored
            WebDAVMediaSession.setActiveCredentials(stored)
        }
    }

    private func enrichWithAPIAccess(_ credentials: WebDAVCredentials) async throws -> WebDAVCredentials {
        var updated = credentials
        if let session = try? await PCloudAuth.fetchAuthSession(
            email: credentials.email,
            password: credentials.password,
            preferredRegion: credentials.region,
            session: .shared
        ) {
            updated.region = session.region
            updated.apiAuthToken = session.token
            updated.apiAuthHost = session.apiHost
        }
        if let root = try? await PCloudWebDAVRootResolver.filesRoot(credentials: updated) {
            updated.webDAVFilesRoot = root
        }
        return updated
    }

    func startExport(item: WebDAVItem, seekMs: Int64) async throws {
        guard let credentials else { throw ExportError.notSignedIn }
        guard !isExportRunning else { throw ExportError.jobAlreadyActive }

        userRequestedExportCancel = false
        exportCoordinator.userRequestedCancel = false
        isExportRunning = true
        defer { isExportRunning = false }

        let result = try await exportCoordinator.run(
            item: item,
            credentials: credentials,
            seekMs: seekMs
        )
        let resumeMs: Int64 = result.reachedEnd ? 0 : result.lastMediaTimeMs
        ResumeStore.shared.saveSeekMs(resumeMs, for: item)
    }

    func cancelExport() {
        userRequestedExportCancel = true
        exportCoordinator.userRequestedCancel = true
        exportCoordinator.cancel()
    }
}

enum ExportError: LocalizedError {
    case notSignedIn
    case jobAlreadyActive

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to pCloud first."
        case .jobAlreadyActive: return "An export is already running."
        }
    }
}
