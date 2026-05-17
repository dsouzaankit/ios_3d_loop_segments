import SwiftUI

struct ExportView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var network = NetworkPathMonitor()
    let item: WebDAVItem

    @State private var seekMs: Int64 = 0
    @State private var status = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Network (pCloud)") {
                Text(network.interfaceLabel)
                if network.usesCellular {
                    Text("pCloud uses iPhone cellular. PC is not involved until USB sync.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Tip: Settings → Cellular → Loop Segments → On. Wi‑Fi can stay off to avoid hotspot.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("File") {
                Text(item.name)
                Text(item.href).font(.caption).foregroundStyle(.secondary)
            }
            Section("Start position") {
                Text("Resume: \(formatMs(seekMs))")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(SeekPreset.allCases) { preset in
                            Button(preset.label) { seekMs = preset.seekMs }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            Section("Output (USB → PC → DLNA)") {
                Text(ExportPaths.exportsDirectory.path)
                    .font(.caption)
                Text("1. Export creates 3d_op_00.mkv / 3d_op_01.mkv here")
                Text("2. Plug iPhone into Windows PC (USB)")
                Text("3. Run Sync-IphoneSegments.ps1 on PC")
                Text("4. Play from PC DLNA server on WLAN")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !status.isEmpty {
                Section("Status") {
                    Text(status).font(.caption)
                }
            }
            Section {
                Button(session.isExportRunning ? "Exporting…" : "Start export") {
                    Task { await startExport() }
                }
                .disabled(session.isExportRunning)
                if session.isExportRunning {
                    Button("Stop", role: .destructive) {
                        session.cancelExport()
                        status = "Cancelled"
                    }
                }
            }
        }
        .navigationTitle("Export")
        .onAppear {
            seekMs = ResumeStore.shared.seekMs(for: item)
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func startExport() async {
        status = "Reading from pCloud over \(network.usesCellular ? "cellular" : "network"); writing segments…"
        do {
            try await session.startExport(item: item, seekMs: seekMs)
            status = "Done. USB sync to PC, then DLNA on WLAN."
        } catch {
            errorMessage = error.localizedDescription
            status = "Failed"
        }
    }

    private func formatMs(_ ms: Int64) -> String {
        let totalSec = ms / 1000
        let min = totalSec / 60
        let sec = totalSec % 60
        return String(format: "%d:%02d", min, sec)
    }
}
