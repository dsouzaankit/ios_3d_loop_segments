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
                    Text("pCloud uses cellular — keep the app open while FFmpeg runs with `-re` pacing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Experimental FFmpeg-iOS build (not ffmpeg-kit). May not launch on iOS 26. Use the main Loop Segments app for production.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
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
                Text("Segments copy to Photos when export finishes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Output (USB → PC → DLNA)") {
                Text(ExportPaths.exportsDirectory.path)
                    .font(.caption)
                Text("FFmpeg writes `3d_op_00.mp4` / `3d_op_01.mp4` directly (60s segment mux, wrap 2).")
                Text("Stream copy (`-c copy`), WebDAV auth via `-headers`, real-time read (`-re`).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(logHint.isEmpty ? "Logs: export_latest.txt · export_progress.txt" : logHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !liveLogTail.isEmpty {
                    Text(liveLogTail)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
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
                        status = "Stop requested — waits for current FFmpeg run to finish"
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
            photosAccessNote = "Photos access OK."
        } else {
            photosAccessNote = "Settings → Loop Segments FFmpeg → Photos → allow access."
        }
    }

    private func startExport() async {
        if PhotosSegmentPublisher.isEnabled {
            await requestPhotosAccess()
        }
        status = "FFmpeg running (stream copy, 60s segment wrap)…"
        do {
            try await session.startExport(item: item, seekMs: seekMs)
            status = "Done — 3d_op_00/01 in Exports (and Photos if enabled)."
        } catch FFmpegRunnerError.cancelled {
            status = "Stopped — segment files removed from device"
        } catch {
            errorMessage = error.localizedDescription
            status = "Failed — partial segments may remain in Exports"
        }
        refreshLogFromDisk()
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
        logHint = "export_latest.txt \(fileByteCount(latest)) B · export_progress.txt \(fileByteCount(progress)) B · ok.txt \(fileByteCount(probe)) B"
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
