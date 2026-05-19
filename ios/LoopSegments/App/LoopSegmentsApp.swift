import SwiftUI

@main
struct LoopSegmentsApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = AppSession()

    init() {
        ExportPaths.ensureExportDirectories()
        ExportLANServer.ensureRunning(log: { SearchDebugLog.log("LAN export: \($0)") })
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            Task {
                guard !session.isExportRunning else { return }
                await SegmentCleanup.removeAllSegments()
            }
        }
    }
}
