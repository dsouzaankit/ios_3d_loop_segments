import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.scenePhase) private var scenePhase

    /// Foreground, or export still running (Keep Alive / background task) — keep LAN server + trigger polling.
    private var lanServicesActive: Bool {
        scenePhase == .active || session.isExportSessionActive
    }

    var body: some View {
        Group {
            if session.credentials != nil {
                BrowserView()
            } else {
                AuthView()
            }
        }
        .background {
            NowPlayingFirstResponderAnchor()
                .frame(width: 0, height: 0)
        }
        .onAppear {
            LANPhoneInteractionState.update(scenePhase: scenePhase)
            syncLANServices()
        }
        .onChange(of: scenePhase) { _, newPhase in
            LANPhoneInteractionState.update(scenePhase: newPhase)
            syncLANServices()
        }
        .onChange(of: session.isExportSessionActive) { _, _ in
            syncLANServices()
        }
    }

    private func syncLANServices() {
        if lanServicesActive {
            ExportLANServer.ensureRunning(log: { SearchDebugLog.log("LAN export: \($0)") })
        }
        LANExportTriggerRunner.setAppActive(lanServicesActive, session: session)
    }
}
