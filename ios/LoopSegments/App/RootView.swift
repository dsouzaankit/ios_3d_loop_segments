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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                ExportLANServer.ensureRunning(log: { SearchDebugLog.log("LAN export: \($0)") })
            }
        }
    }
}
