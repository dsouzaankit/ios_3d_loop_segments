import SwiftUI

struct ExportView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var network = NetworkPathMonitor()
    let item: WebDAVItem

    @State private var seekMs: Int64 = 0
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var logHint = ""
    @State private var photosAccessNote = ""

    var body: some View {
        Form {
            Section("Network (pCloud)") {
                Text(network.interfaceLabel)
                if network.usesCellular {
                    Text("pCloud uses cellular — keep app open; timeouts retry automatically. USB to PC only after export.")
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
            Section("Photos (optional — PC camera roll)") {
                Toggle("Save segments to Photos", isOn: Binding(
                    get: { PhotosSegmentPublisher.isEnabled },
                    set: { newValue in
                        PhotosSegmentPublisher.isEnabled = newValue
                        if newValue {
                            Task { await requestPhotosAccess() }
                        }
                    }
                ))
                if !photosAccessNote.isEmpty {
                    Text(photosAccessNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("iOS will ask for Photos access when you turn this on or start export. After a normal finish (including EOF), segments stay on the phone until you copy to PC, tap Stop, or leave the app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Output (USB → PC → DLNA)") {
                Text(ExportPaths.exportsDirectory.path)
                    .font(.caption)
                Text("1. Export creates 3d_op_00.mp4 / 3d_op_01.mp4 in app storage")
                Text(logHint.isEmpty ? "Logs: Exports/export_latest.txt" : logHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("2. With Photos on: also check Loop Segments album on PC (Apple Devices → Photos)")
                Text("3. Or Apple Devices → Loop Segments → Exports → Save to PC")
                Text("4. PC DLNA folder: F:\\f1_media\\3d_fullsbs_trans")
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
            if PhotosSegmentPublisher.isEnabled {
                Task { await requestPhotosAccess() }
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func requestPhotosAccess() async {
        guard PhotosSegmentPublisher.isEnabled else {
            photosAccessNote = ""
            return
        }
        if await PhotosSegmentPublisher.ensureAccess() {
            photosAccessNote = "Photos access OK — clips go to the Loop Segments album."
        } else {
            photosAccessNote = "Photos access needed: Settings → Loop Segments → Photos → allow access."
        }
    }

    private func startExport() async {
        if PhotosSegmentPublisher.isEnabled {
            await requestPhotosAccess()
        }
        status = "Reading from pCloud over \(network.usesCellular ? "cellular" : "network"); writing segments…"
        do {
            try await session.startExport(item: item, seekMs: seekMs)
            status = "Done — 3d_op_00/01 kept in Exports (and Photos if enabled). Copy to PC, then leave the app to clear."
        } catch SegmentExporterError.cancelled {
            status = "Stopped — segment files removed from device"
        } catch {
            errorMessage = error.localizedDescription
            status = "Failed — partial segments kept in Exports for USB sync"
        }
        refreshLogHint()
        if fileByteCount(ExportPaths.latestLogTextURL) == 0 {
            logHint += " · log empty — retry export; check sign-in region (US/EU)"
        }
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
