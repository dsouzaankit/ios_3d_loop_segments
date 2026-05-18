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
    @State private var liveLogTail = ""

    var body: some View {
        Form {
            Section("Network (pCloud)") {
                Text(network.interfaceLabel)
                if network.usesCellular {
                    Text("pCloud uses cellular — connection drops retry automatically (up to ~2 min). Keep the app open. “Network connection lost” usually recovers; try seek 0 min.")
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
            Section("Photos (optional — PC sync)") {
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
                Text("With Photos on: each 60s overwrites one clip on the phone; PC sync builds 3d_op_00/01 (MTP may show IMG_*.mp4). Backward jumps in the DLNA loop are OK.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Turn Photos off to use sparse temp (saves cellular/disk, slower).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("3d_op_*.mp4 stay in Exports until Stop or leaving the app; temp _export_source_working.mp4 is removed when export ends or on cleanup.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Output (USB → PC → DLNA)") {
                Text(ExportPaths.exportsDirectory.path)
                    .font(.caption)
                Text("1. Large files use a sparse temp copy (only bytes needed per minute, not the full file).")
                Text("2. Each ~60s segment stages then publishes to 3d_op_00.mp4 on the phone (PC keeps two DLNA files via USB sync)")
                Text(logHint.isEmpty ? "Logs: export_latest.txt (full) · export_progress.txt (last 12 lines)" : logHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !liveLogTail.isEmpty {
                    Text(liveLogTail)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("3. With Photos on: PC can pick newest videos from Internal Storage (202605_a, etc.)")
                Text("4. Or Apple Devices → Loop Segments → Exports → Save to PC")
                Text("5. PC DLNA folder: F:\\f1_media\\3d_fullsbs_trans")
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
            refreshLogFromDisk()
            if PhotosSegmentPublisher.isEnabled {
                Task { await requestPhotosAccess() }
            }
        }
        .task(id: session.isExportRunning) {
            guard session.isExportRunning else { return }
            while session.isExportRunning, !Task.isCancelled {
                refreshLogFromDisk()
                try? await Task.sleep(for: .seconds(2))
            }
            refreshLogFromDisk()
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
            photosAccessNote = "Photos access OK — clips save to your library (USB import friendly)."
        } else {
            photosAccessNote = "Photos access needed: Settings → Loop Segments → Photos → allow access."
        }
    }

    private func startExport() async {
        if PhotosSegmentPublisher.isEnabled {
            await requestPhotosAccess()
        }
        status = "Downloading to temp; publishing 60s chunks for DLNA as each minute is on disk…"
        do {
            try await session.startExport(item: item, seekMs: seekMs)
            status = "Done — latest segment in Exports (and Photos if enabled). Run Photos sync on PC; leave app to clear."
        } catch SegmentExporterError.cancelled {
            status = "Stopped — segment files removed from device"
        } catch SegmentExporterError.readerInterrupted {
            errorMessage = "pCloud read was interrupted (not Stop). Try seek 0 min or Wi‑Fi."
            status = "Interrupted — partial segments may be in Exports"
        } catch {
            errorMessage = error.localizedDescription
            status = "Failed — partial segments kept in Exports for USB sync"
        }
        refreshLogFromDisk()
        if fileByteCount(ExportPaths.latestLogTextURL) == 0 {
            logHint += " · log empty — open Files → Loop Segments → Exports on phone"
        }
    }

    private func refreshLogFromDisk() {
        refreshLogHint()
        if let full = try? String(contentsOf: ExportPaths.latestLogTextURL, encoding: .utf8), !full.isEmpty {
            let lines = full.split(separator: "\n", omittingEmptySubsequences: true)
            liveLogTail = lines.suffix(12).joined(separator: "\n")
            return
        }
        if let progress = try? String(contentsOf: ExportPaths.exportProgressURL, encoding: .utf8),
           !progress.isEmpty {
            liveLogTail = progress.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func refreshLogHint() {
        let latest = ExportPaths.latestLogTextURL
        let progress = ExportPaths.exportProgressURL
        let probe = ExportPaths.exportsDirectory.appendingPathComponent("loop_segments_ok.txt")
        let latestBytes = fileByteCount(latest)
        let progressBytes = fileByteCount(progress)
        let probeBytes = fileByteCount(probe)
        logHint = "export_latest.txt \(latestBytes) B · export_progress.txt \(progressBytes) B · ok.txt \(probeBytes) B"
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
