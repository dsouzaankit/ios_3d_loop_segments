import SwiftUI

@main
struct LoopSegmentsApp: App {
    @StateObject private var session = AppSession()

    init() {
        ExportPaths.ensureExportDirectories()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
        }
    }
}
