import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: AppSession
    @ObservedObject private var resumeStore = ResumeStore.shared
    @ObservedObject private var pendingQueue = PendingExportQueue.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var nightModeEnabled = AppearanceSettings.isNightModeEnabled

    /// Foreground, export in flight, or Keep Alive audio playing — keep LAN server + trigger polling.
    private var lanServicesActive: Bool {
        scenePhase == .active
            || session.isExportSessionActive
            || ExportBackgroundKeepAlive.shared.isActive
    }

    private var pausedTabBadge: Int {
        resumeStore.interruptedEntries(excludingFileKey: session.activeExportFileKey).count
            + pendingQueue.count
    }

    var body: some View {
        Group {
            if session.credentials != nil {
                TabView(selection: $session.selectedMainTab) {
                    BrowserView()
                        .tabItem {
                            Label("Browse", systemImage: "folder")
                        }
                        .tag(MainTab.browse)

                    PausedExportsView()
                        .tabItem {
                            Label("Paused", systemImage: "pause.circle")
                        }
                        .badge(pausedTabBadge)
                        .tag(MainTab.paused)
                }
            } else {
                AuthView()
            }
        }
        .preferredColorScheme(nightModeEnabled ? .dark : .light)
        .background {
            NowPlayingFirstResponderAnchor()
                .frame(width: 0, height: 0)
        }
        .onAppear {
            nightModeEnabled = AppearanceSettings.isNightModeEnabled
            if scenePhase == .active {
                ExportBackgroundKeepAlive.shared.beginAppForegroundSession()
            }
            syncLANServices()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appearanceNightModeDidChange)) { _ in
            nightModeEnabled = AppearanceSettings.isNightModeEnabled
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
