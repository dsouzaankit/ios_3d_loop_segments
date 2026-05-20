import SwiftUI

struct ExportView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var network = NetworkPathMonitor()
    @ObservedObject private var resumeStore = ResumeStore.shared
    let item: WebDAVItem

    @State private var seekMs: Int64 = 0
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var logHint = ""
    @State private var photosAccessNote = ""
    @State private var liveLogTail = ""
    @State private var lanExportURL: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var showClearMediaConfirm = false
    @State private var showClearLogsConfirm = false
    @State private var showAutoLockHelp = false

    var body: some View {
        Form {
            Section("Network (pCloud)") {
                Text(network.interfaceLabel)
                if network.usesCellular {
                    Text("pCloud uses cellular — connection drops retry automatically (up to ~2 min). Keep the app open. “Network connection lost” usually recovers; try seek 0 min.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Tip: Settings → Cellular → Loop Segments → On. Wi‑Fi/LAN can stay on for PC sync while pCloud uses cellular.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("LAN export (PC sync)") {
                Toggle("Serve Exports on Wi‑Fi", isOn: Binding(
                    get: { ExportLANServer.isEnabled },
                    set: { enabled in
                        ExportLANServer.isEnabled = enabled
                        if enabled {
                            ExportLANServer.ensureRunning(log: { SearchDebugLog.log("LAN export: \($0)") })
                        } else {
                            ExportLANServer.stop(log: nil)
                            lanExportURL = nil
                        }
                    }
                ))
                Text("Phone and PC on same LAN (HTTP + WebDAV :8765). In-progress: LAN index → _working.mp4 (#t= resume). PC: Mount-LoopSegmentsRclone.ps1 maps full Exports (loop/ + _working.mp4).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let lanExportURL {
                    Text(lanExportURL)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            Section("File") {
                Text(item.name)
                Text(item.href).font(.caption).foregroundStyle(.secondary)
            }
            resumeSection
            if PhotosSegmentPublisher.workflowEnabled {
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
                    if PhotosSegmentPublisher.isEnabled {
                        Toggle("H.264 for Photos (skip passthrough)", isOn: Binding(
                            get: { PhotosSegmentPublisher.alwaysTranscodeH264ForPhotos },
                            set: { PhotosSegmentPublisher.alwaysTranscodeH264ForPhotos = $0 }
                        ))
                        Text("On: every segment is transcoded to H.264 for Photos only (~1–3 min/segment). Off: try passthrough first; on 3302 the app transcodes. DLNA file in Exports stays full quality.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !photosAccessNote.isEmpty {
                        Text(photosAccessNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("With Photos on: each minute is dense-downloaded from pCloud, then saved to Photos and Exports (loop/op_00.mp4). First segment can take a few minutes on large files.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("PC: Mount-LoopSegmentsRclone.ps1 (Wi‑Fi) or Apple Devices → Exports → Save to PC.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("During export") {
                Text("Keep Loop Segments open on this screen. The app keeps the display on while export runs; leaving the app or locking the phone can stop export.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open Display in Settings") {
                    Task {
                        _ = await ExportAutoLockCoordinator.openAutoLockSettings()
                        showAutoLockHelp = true
                    }
                }
                Text("Optional: Auto-Lock → Never only if you must leave the app during a long run. Path: \(ExportAutoLockCoordinator.manualPath).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Output (USB → PC → DLNA)") {
                Text(ExportPaths.exportsDirectory.path)
                    .font(.caption)
                Text("1. Large files: sparse temp shell; each minute dense-fills only that window from pCloud (not the full file).")
                Text("2. Passthrough to loop/op_*.mp4; PC: Mount-LoopSegmentsRclone.ps1")
                Text(logHint.isEmpty ? "Logs: export_latest.txt (full) · export_progress.txt (last 12 lines)" : logHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !liveLogTail.isEmpty {
                    Text(liveLogTail)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("3. Or Apple Devices → Loop Segments → Exports → Save to PC")
                Text("4. PC DLNA folder: F:\\f1_media\\3d_fullsbs_trans")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Exports folder") {
                Button("Clear media", role: .destructive) {
                    showClearMediaConfirm = true
                }
                .disabled(session.isExportRunning)
                Button("Clear logs", role: .destructive) {
                    showClearLogsConfirm = true
                }
                .disabled(session.isExportRunning)
                Text("Media: loop/op_00|01.mp4, _working.mp4. Logs: export_latest/progress, export_session_*, search_debug.txt, Exports/logs/.")
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
                    exportTask?.cancel()
                    exportTask = Task { await startExport() }
                }
                .disabled(session.isExportRunning)
                if session.isExportRunning {
                    Button("Stop", role: .destructive) {
                        session.cancelExport()
                        exportTask?.cancel()
                        exportTask = nil
                        status = "Stopping…"
                    }
                }
            }
        }
        .navigationTitle("Export")
        .onAppear {
            applyForegroundResume()
            if PhotosSegmentPublisher.workflowEnabled, PhotosSegmentPublisher.isEnabled {
                Task { await requestPhotosAccess() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                applyForegroundResume()
            }
        }
        .onChange(of: resumeStore.revision) { _, _ in
            guard session.isExportRunning,
                  session.activeExportItem?.fileKey == item.fileKey else { return }
            let live = resumeStore.resumeStatus(for: item).effectiveMs
            if live > seekMs {
                seekMs = live
            }
        }
        .task(id: ExportLANServer.isEnabled) {
            guard ExportLANServer.isEnabled else {
                lanExportURL = nil
                return
            }
            ExportLANServer.ensureRunning(log: { SearchDebugLog.log("LAN export: \($0)") })
            while ExportLANServer.isEnabled, !Task.isCancelled {
                if session.isExportRunning {
                    refreshLogFromDisk()
                }
                lanExportURL = ExportLANServer.baseURLString
                try? await Task.sleep(for: .seconds(2))
            }
            if !ExportLANServer.isEnabled {
                lanExportURL = nil
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Clear export media?",
            isPresented: $showClearMediaConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear media", role: .destructive) { clearExportMedia() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes segment MP4s and temp source from Exports. Photos library is unchanged.")
        }
        .confirmationDialog(
            "Clear export logs?",
            isPresented: $showClearLogsConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear logs", role: .destructive) { clearExportLogs() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes export and search log files from Exports. loop_segments_ok.txt is kept.")
        }
        .alert("Auto-Lock", isPresented: $showAutoLockHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "If Settings did not open to Auto-Lock, go to \(ExportAutoLockCoordinator.manualPath). " +
                    "On recent iOS versions Apple often only opens the Settings app — the path above is required."
            )
        }
    }

    @ViewBuilder
    private var resumeSection: some View {
        let resume = resumeStore.resumeStatus(for: item)
        let isThisFileExporting = session.isExportRunning
            && session.activeExportItem?.fileKey == item.fileKey

        Section {
            if isThisFileExporting {
                Label("Export in progress", systemImage: "arrow.down.circle")
                    .foregroundStyle(.orange)
                LabeledContent("Current position") {
                    Text(ResumeTimeFormat.formatMs(resume.effectiveMs))
                        .monospacedDigit()
                }
            } else if resume.isPaused {
                Label("Export paused", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
                Text("Interrupted or app left mid-run. Next export continues from the checkpoint below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if resume.effectiveMs > 0 {
                Label("Saved resume point", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Text("Last export stopped before the end of the file. You can continue from this time or pick a preset.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Start from the beginning or pick a preset below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Start at") {
                Text(ResumeTimeFormat.formatMs(seekMs))
                    .font(.body.monospacedDigit())
            }

            if resume.savedSeekMs > 0, resume.savedSeekMs != seekMs || resume.isPaused {
                LabeledContent("Last finished at") {
                    Text(ResumeTimeFormat.formatMs(resume.savedSeekMs))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let checkpoint = resume.checkpointMs, checkpoint > 0 {
                LabeledContent(resume.isPaused ? "Checkpoint" : "Last checkpoint") {
                    Text(ResumeTimeFormat.formatMs(checkpoint))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(resume.isPaused ? .orange : .secondary)
                }
            }
            if let updated = resume.updatedAt {
                LabeledContent("Updated") {
                    Text(ResumeTimeFormat.relative(updated))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(SeekPreset.allCases) { preset in
                        Button(preset.label) {
                            seekMs = preset.seekMs
                            resumeStore.saveSeekMs(seekMs, for: item)
                            syncLANResumeHintFromStore()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if resume.hasResumePoint, !session.isExportRunning {
                Button("Reset to 0:00", role: .destructive) {
                    resumeStore.clearResume(for: item)
                    seekMs = 0
                    status = "Resume cleared — next export starts at 0:00"
                }
            }
        } header: {
            Text("Resume")
        }
    }

    private func syncLANResumeHintFromStore() {
        guard FileManager.default.fileExists(atPath: ExportPaths.workingSourceURL.path) else { return }
        WorkingSourceSparseCatalog.refreshPlaybackState(for: ExportPaths.workingSourceURL)
    }

    private func applyForegroundResume() {
        let resume = resumeStore.resumeStatus(for: item)
        seekMs = resume.effectiveMs
        syncLANResumeHintFromStore()
        if session.isExportRunning, session.activeExportItem?.fileKey == item.fileKey {
            if let checkpoint = resumeStore.checkpointMediaMs(for: item), checkpoint > seekMs {
                seekMs = checkpoint
            }
            if status.isEmpty || status.hasPrefix("Export paused") {
                status = "Export running — logs refresh while app is open"
            }
        } else if resume.isPaused {
            status = "Export paused — continue from \(ResumeTimeFormat.formatMs(seekMs)) (tap Start export)"
        } else if resume.effectiveMs > 0, status.isEmpty {
            status = "Will start from \(ResumeTimeFormat.formatMs(seekMs))"
        }
        refreshLogFromDisk()
        refreshLogHint()
        ExportLANServer.ensureRunning(log: { SearchDebugLog.log("LAN export: \($0)") })
        if FileManager.default.fileExists(atPath: ExportPaths.workingSourceURL.path) {
            WorkingSourceSparseCatalog.refreshPlaybackState(for: ExportPaths.workingSourceURL)
        }
        lanExportURL = ExportLANServer.baseURLString
    }

    private func clearExportMedia() {
        guard !session.isExportRunning else { return }
        ResumeStore.shared.finishExport(for: item)
        let count = SegmentCleanup.removeExportMedia()
        liveLogTail = ""
        status = count > 0 ? "Cleared \(count) media file(s) from Exports" : "No media files in Exports"
        refreshLogHint()
    }

    private func clearExportLogs() {
        guard !session.isExportRunning else { return }
        let count = ExportPaths.clearExportLogs()
        liveLogTail = ""
        status = count > 0 ? "Cleared \(count) log file(s) from Exports" : "No log files in Exports"
        refreshLogHint()
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
        if PhotosSegmentPublisher.workflowEnabled, PhotosSegmentPublisher.isEnabled {
            await requestPhotosAccess()
        }
        status = "Downloading to temp; publishing 60s chunks for DLNA as each minute is on disk…"
        do {
            try await session.startExport(item: item, seekMs: seekMs)
            status = PhotosSegmentPublisher.workflowEnabled && PhotosSegmentPublisher.isEnabled
                ? "Done — segment in Files → Loop Segments → Exports (and Photos). Stays until Clear media or next export."
                : "Done — segment in Files → Exports. LAN sync while app is open and Serve Exports is on."
        } catch is CancellationError, SegmentExporterError.cancelled {
            status = "Stopped — segment files removed from device"
        } catch ExportError.stillStopping {
            errorMessage = ExportError.stillStopping.errorDescription
            status = "Wait for the previous export to finish stopping"
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

}
