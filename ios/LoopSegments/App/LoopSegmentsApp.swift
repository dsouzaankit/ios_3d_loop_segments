import SwiftUI

@main
struct LoopSegmentsApp: App {
    @StateObject private var session = AppSession()

    init() {
        ExportPaths.ensureExportDirectories()
        SearchLocationCache.refreshLANSnapshot()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
        }
    }
}
