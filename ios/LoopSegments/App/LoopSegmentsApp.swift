import SwiftUI

@main
struct LoopSegmentsApp: App {
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
    }
}
