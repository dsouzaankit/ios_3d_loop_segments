import Foundation

@MainActor
final class AppSession: ObservableObject {
    @Published var credentials: WebDAVCredentials?
    @Published var isExportRunning = false

    private let credentialStore = CredentialStore()
    private(set) var userRequestedExportCancel = false
    /// Created on first export (lazy init for export stack).
    private lazy var exportCoordinator = ExportCoordinator()

    init() {
        credentials = credentialStore.load()
        WebDAVMediaSession.setActiveCredentials(credentials)
    }

    func signIn(region: PCloudRegion, email: String, password: String) async throws {
        let creds = WebDAVCredentials(region: region, email: email, password: password)
        let client = WebDAVClient(credentials: creds)
        _ = try await client.list(path: "/")
        let apiRegion = try await PCloudAuth.verifyAPIAccess(credentials: creds)
        var signedIn = creds
        if apiRegion != creds.region {
            signedIn.region = apiRegion
            let recheck = WebDAVClient(credentials: signedIn)
            _ = try await recheck.list(path: "/")
        }
        credentialStore.save(signedIn)
        credentials = signedIn
        WebDAVMediaSession.setActiveCredentials(signedIn)
        UserDefaults.standard.set(signedIn.region.rawValue, forKey: "pcloud_region_last_sign_in")
    }

    func signOut() {
        credentialStore.clear()
        credentials = nil
        WebDAVMediaSession.setActiveCredentials(nil)
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
