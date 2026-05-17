import Foundation

@MainActor
final class AppSession: ObservableObject {
    @Published var credentials: WebDAVCredentials?
    @Published var isExportRunning = false

    private let credentialStore = CredentialStore()
    /// Created on first export (lazy init for export stack).
    private lazy var exportCoordinator = ExportCoordinator()

    init() {
        credentials = credentialStore.load()
    }

    func signIn(region: PCloudRegion, email: String, password: String) async throws {
        let creds = WebDAVCredentials(region: region, email: email, password: password)
        let client = WebDAVClient(credentials: creds)
        _ = try await client.list(path: "/")
        credentialStore.save(creds)
        credentials = creds
    }

    func signOut() {
        credentialStore.clear()
        credentials = nil
    }

    func startExport(item: WebDAVItem, seekMs: Int64) async throws {
        guard let credentials else { throw ExportError.notSignedIn }
        guard !isExportRunning else { throw ExportError.jobAlreadyActive }

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
