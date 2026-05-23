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
    @State private var lanHostURL: String?
    @State private var lanIPURL: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var showAutoLockHelp = false
    @State private var copiedLANURL = false
    @State private var clearMediaAcknowledged = false
    @State private var clearMediaAckTrigger = 0
    @State private var clearLogsAcknowledged = false
    @State private var clearLogsAckTrigger = 0
    @State private var prefetchCutoffMbps = ExportLANServer.backgroundPrefetchCutoffMbps
    @State private var hlsTranscodeCutoffMultiplier = PCloudHLSLink.transcodeCutoffMultiplier
    @State private var vanillaDownloadBackup = VanillaWebDAVDownload.isBackupEnabled

    var body: some View {
        Form {
            exportControlsSection
            exportsFolderSection
            if !status.isEmpty {
                Section("Status") {
                    Text(status).font(.caption)
                }
            }
            Section("LAN export (PC sync)") {
                Toggle(ExportLANServer.lanServerToggleTitle, isOn: Binding(
                    get: { ExportLANServer.isEnabled },
                    set: { enabled in
                        ExportLANServer.isEnabled = enabled
                        if enabled {
                            prefetchCutoffMbps = ExportLANServer.backgroundPrefetchCutoffMbps
                            ExportLANServer.ensureRunning(log: { SearchDebugLog.log("LAN export: \($0)") })
                        } else {
                            ExportLANServer.stop(log: nil)
                            lanHostURL = nil
                            lanIPURL = nil
                        }
                    }
                ))
                if ExportLANServer.isEnabled {
                    Picker(
                        "60s segments when at/above",
                        selection: $prefetchCutoffMbps
                    ) {
                        ForEach(ExportLANServer.backgroundPrefetchCutoffOptions, id: \.self) { mbps in
                            Text(ExportLANServer.prefetchCutoffOptionLabel(mbps: mbps))
                                .tag(mbps)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(session.isExportRunning)
                    .onChange(of: prefetchCutoffMbps) { _, newValue in
                        ExportLANServer.backgroundPrefetchCutoffMbps = newValue
                    }
                    .onAppear {
                        prefetchCutoffMbps = ExportLANServer.backgroundPrefetchCutoffMbps
                    }
                    if session.isExportRunning {
                        Text("Cutoff locked while export is running.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(
                        "Below Mbps cutoff: LAN preload or vanilla only (no op_00/op_01). At or above: 60s segments when codec allows — LAN server can stay on. High-bitrate mode uses minimal _working prefetch ahead of export."
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        "Turn on LAN server to share pcld_ios_media on :8765 and set the Mbps segment cutoff (default 35 Mbps)."
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Same Wi‑Fi as the PC. Use the LAN IP line below on Windows. http://iphone.local:8765/ is not a default URL — it only matches if About → Name is exactly “iPhone” and your PC resolves .local (most Windows PCs need the numeric IP).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LabeledContent("About → Name") {
                    Text(ExportLANServer.deviceAboutName)
                        .font(.caption)
                }
                if let lanIPURL {
                    LabeledContent("LAN IP (use on PC)") {
                        Text(lanIPURL)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Button(copiedLANURL ? "Copied" : "Copy LAN IP URL") {
                        UIPasteboard.general.string = lanIPURL
                        copiedLANURL = true
                    }
                } else if ExportLANServer.isEnabled {
                    Text("No Wi‑Fi IPv4 address — connect the phone to Wi‑Fi (same network as the PC). `.local` URLs will not work until an IP appears here.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let lanHostURL {
                    LabeledContent("Optional .local URL") {
                        Text(lanHostURL)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Text("Skybox WebDAV: \(ExportLANServer.lanWebDAVUsername) / \(ExportLANServer.lanWebDAVPassword). Bonjour: \(ExportLANServer.bonjourServiceName)._http._tcp")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(inProgressLANFootnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("Vanilla download first (before HLS)", isOn: $vanillaDownloadBackup)
                    .disabled(session.isExportRunning)
                    .onChange(of: vanillaDownloadBackup) { _, enabled in
                        VanillaWebDAVDownload.isBackupEnabled = enabled
                    }
                    .onAppear { vanillaDownloadBackup = VanillaWebDAVDownload.isBackupEnabled }
                Text(
                    "After sparse probe fails: WebDAV download to _vanilla_download.<ext> (visible on LAN while downloading). MP4/MOV/M4V also refresh _vanilla_faststart.mp4 during download."
                )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker(
                    "pCloud HLS if WebDAV fails above",
                    selection: $hlsTranscodeCutoffMultiplier
                ) {
                    ForEach(PCloudHLSLink.transcodeCutoffMultipliers, id: \.self) { mult in
                        Text(PCloudHLSLink.transcodeCutoffOptionLabel(multiplier: mult))
                            .tag(mult)
                    }
                }
                .pickerStyle(.menu)
                .disabled(session.isExportRunning)
                .onChange(of: hlsTranscodeCutoffMultiplier) { _, newValue in
                    PCloudHLSLink.transcodeCutoffMultiplier = newValue
                }
                .onAppear {
                    hlsTranscodeCutoffMultiplier = PCloudHLSLink.transcodeCutoffMultiplier
                }
                if session.isExportRunning {
                    Text("HLS cutoff locked while export is running.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(
                    "WMV/ASF and similar: after WebDAV probe fails, use pCloud transcode only when estimated source bitrate is above this (default 2.5 Mbps at 1×)."
                )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
            Section("File") {
                Text(item.name)
                Text(item.href).font(.caption).foregroundStyle(.secondary)
            }
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
                    Text("With Photos on: each minute is dense-downloaded from pCloud, then saved to Photos and Exports (pcld_ios_media/loop/op_00.mp4). First segment can take a few minutes on large files.")
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
                Text("Screen stays on while this Export page is open. Optional: Auto-Lock → Never if you leave the app during a run. Path: \(ExportAutoLockCoordinator.manualPath).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Output (USB → PC → DLNA)") {
                Text(ExportPaths.exportsDirectory.path)
                    .font(.caption)
                Text("1. Large files: sparse temp shell; each minute dense-fills only that window from pCloud (not the full file).")
                Text("2. Passthrough to pcld_ios_media/loop/op_*.mp4; PC: Mount-LoopSegmentsRclone.ps1")
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
        }
        .navigationTitle("Export")
        .onAppear {
            ExportAutoLockCoordinator.setExportPageVisible(true)
            applyForegroundResume()
            if PhotosSegmentPublisher.workflowEnabled, PhotosSegmentPublisher.isEnabled {
                Task { await requestPhotosAccess() }
            }
        }
        .onDisappear {
            ExportAutoLockCoordinator.setExportPageVisible(false)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                ExportAutoLockCoordinator.setExportPageVisible(true)
                applyForegroundResume()
            case .inactive, .background:
                ExportAutoLockCoordinator.setExportPageVisible(false)
            @unknown default:
                break
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
                lanHostURL = nil
                lanIPURL = nil
                return
            }
            ExportLANServer.ensureRunning(log: { SearchDebugLog.log("LAN export: \($0)") })
            while ExportLANServer.isEnabled, !Task.isCancelled {
                if session.isExportRunning {
                    refreshLogFromDisk()
                }
                let urls = ExportLANServer.displayLANURLs
                lanHostURL = urls.host
                lanIPURL = urls.ip
                try? await Task.sleep(for: .seconds(2))
            }
            if !ExportLANServer.isEnabled {
                lanHostURL = nil
                lanIPURL = nil
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
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

    private var inProgressLANFootnote: String {
        if ExportPlaybackState.shared.usesVanillaDownloadForLAN() {
            let path = ExportPlaybackState.shared.vanillaLANRelativePath()
            return "In-progress: vanilla download → \(path) (full file). Segments: pcld_ios_media/loop/op_*.mp4 when export runs."
        }
        if ExportPlaybackState.shared.usesPCloudTranscodedWorkingForLAN() {
            return "In-progress: pCloud transcode → pcld_ios_media/_working_pcloud_transcode.mp4 (not the original file). Segments: loop/op_*.mp4"
        }
        return "In-progress: index → pcld_ios_media/_working.mp4 (#t= resume while paused). Segments: pcld_ios_media/loop/op_*.mp4"
    }

    @ViewBuilder
    private var exportControlsSection: some View {
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
                Text("Checkpoint saved. Tap Start export to continue — segments and _working.mp4 stay on the phone.")
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

            Button(session.isExportRunning ? "Exporting…" : "Start export") {
                exportTask?.cancel()
                exportTask = Task { await startExport() }
            }
            .disabled(session.isExportRunning)

            if session.isExportRunning {
                Button("Pause") {
                    session.pauseExport()
                    exportTask?.cancel()
                    exportTask = nil
                    status = "Paused — tap Start export to continue from checkpoint"
                }
                Button("Stop", role: .destructive) {
                    session.cancelExport()
                    exportTask?.cancel()
                    exportTask = nil
                    status = "Stopping…"
                }
            }
        } header: {
            Text("Export")
        } footer: {
            Text("Pause keeps the checkpoint and files on disk. Stop clears paused state and removes published segment files.")
                .font(.footnote)
        }
    }

    private var exportsFolderSection: some View {
        Section("Exports folder") {
            Button {
                clearExportMedia()
                acknowledgeClearMediaTap()
            } label: {
                Label(
                    clearMediaAcknowledged ? "Cleared" : "Clear media",
                    systemImage: clearMediaAcknowledged ? "checkmark.circle.fill" : "film"
                )
            }
            .disabled(session.isExportRunning)
            .foregroundStyle(clearMediaAcknowledged ? .green : Color.red)
            .sensoryFeedback(.success, trigger: clearMediaAckTrigger)
            Button {
                clearExportLogs()
                acknowledgeClearLogsTap()
            } label: {
                Label(
                    clearLogsAcknowledged ? "Cleared" : "Clear logs",
                    systemImage: clearLogsAcknowledged ? "checkmark.circle.fill" : "doc.text"
                )
            }
            .disabled(session.isExportRunning)
            .foregroundStyle(clearLogsAcknowledged ? .green : Color.red)
            .sensoryFeedback(.success, trigger: clearLogsAckTrigger)
            Text("Media: pcld_ios_media/loop/op_00|01.mp4, pcld_ios_media/_working.mp4. Logs: export_latest/progress, export_session_*, search_debug.txt, Exports/logs/.")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
        let urls = ExportLANServer.displayLANURLs
        lanHostURL = urls.host
        lanIPURL = urls.ip
    }

    private func clearExportMedia() {
        guard !session.isExportRunning else { return }
        ResumeStore.shared.clearPinnedCompletedExports()
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

    private func acknowledgeClearMediaTap() {
        clearMediaAcknowledged = true
        clearMediaAckTrigger += 1
        scheduleClearAcknowledgementReset { clearMediaAcknowledged = false }
    }

    private func acknowledgeClearLogsTap() {
        clearLogsAcknowledged = true
        clearLogsAckTrigger += 1
        scheduleClearAcknowledgementReset { clearLogsAcknowledged = false }
    }

    private func scheduleClearAcknowledgementReset(_ reset: @escaping () -> Void) {
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { reset() }
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
        if PhotosSegmentPublisher.workflowEnabled, PhotosSegmentPublisher.isEnabled {
            await requestPhotosAccess()
        }
        status = "Downloading to temp; publishing 60s chunks for DLNA as each minute is on disk…"
        do {
            try await session.startExport(item: item, seekMs: seekMs)
            status = PhotosSegmentPublisher.workflowEnabled && PhotosSegmentPublisher.isEnabled
                ? "Done — segment in Files → Loop Segments → Exports (and Photos). Stays until Clear media or next export."
                : "Done — segment in Files → Exports. LAN :8765 shares media while the LAN server toggle is on."
        } catch SegmentExporterError.paused {
            let resume = resumeStore.resumeStatus(for: item)
            let at = ResumeTimeFormat.formatMs(resume.effectiveMs)
            status = "Paused — tap Start export to continue from \(at)"
        } catch is CancellationError {
            let resume = resumeStore.resumeStatus(for: item)
            if resume.isPaused {
                status = "Paused — tap Start export to continue from \(ResumeTimeFormat.formatMs(resume.effectiveMs))"
            } else {
                status = "Stopped — segment files removed from device"
            }
        } catch SegmentExporterError.cancelled {
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
