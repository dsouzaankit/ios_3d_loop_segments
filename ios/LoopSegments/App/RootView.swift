import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.scenePhase) private var scenePhase

    /// Foreground, export in flight, or Keep Alive audio playing — keep LAN server + trigger polling.
    private var lanServicesActive: Bool {
        scenePhase == .active
            || session.isExportSessionActive
            || ExportBackgroundKeepAlive.shared.isActive
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
            if scenePhase == .active {
                ExportBackgroundKeepAlive.shared.beginAppForegroundSession()
            }
            syncLANServices()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                ExportBackgroundKeepAlive.shared.beginAppForegroundSession()
            }
            syncLANServices()
        }
        .onChange(of: session.isExportSessionActive) { _, _ in
            syncLANServices()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .exportBackgroundKeepAliveActiveDidChange
            )
        ) { _ in
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
