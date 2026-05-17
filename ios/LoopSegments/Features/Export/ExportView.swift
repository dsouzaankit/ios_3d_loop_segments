import SwiftUI

struct ExportView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var network = NetworkPathMonitor()
    let item: WebDAVItem

    @State private var seekMs: Int64 = 0
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var logHint = ""

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
                Text("1. Export creates 3d_op_00.mp4 / 3d_op_01.mp4 here")
                Text(logHint.isEmpty ? "Logs: Exports/export_latest.txt" : logHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
            refreshLogHint()
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
        refreshLogHint()
    }

    private func refreshLogHint() {
        let latest = ExportPaths.latestLogTextURL
        let probe = ExportPaths.exportsDirectory.appendingPathComponent("loop_segments_ok.txt")
        let latestBytes = fileByteCount(latest)
        let probeBytes = fileByteCount(probe)
        logHint = "export_latest.txt \(latestBytes) B · loop_segments_ok.txt \(probeBytes) B (in Exports)"
    }

    private func fileByteCount(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber else { return 0 }
        return n.int64Value
    }

    private func formatMs(_ ms: Int64) -> String {
        let totalSec = ms / 1000
        let min = totalSec / 60
        let sec = totalSec % 60
        return String(format: "%d:%02d", min, sec)
    }
}
