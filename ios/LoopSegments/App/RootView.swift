import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if session.credentials != nil {
                BrowserView()
            } else {
                AuthView()
            }
        }
        .onAppear {
            LANExportTriggerRunner.setAppActive(true, session: session)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                ExportLANServer.ensureRunning(log: { SearchDebugLog.log("LAN export: \($0)") })
            }
            LANExportTriggerRunner.setAppActive(phase == .active, session: session)
        }
    }
}
