import SwiftUI

struct ExportView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var network = NetworkPathMonitor()
    @ObservedObject private var resumeStore = ResumeStore.shared
    let item: WebDAVItem
    var autoStartExport: Bool = false
    var autoStartSeekMs: Int64 = 0

    @State private var seekMs: Int64 = 0
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var logHint = ""
    @State private var liveLogTail = ""
    @State private var lanHostURL: String?
    @State private var lanIPURL: String?
    @State private var showAutoLockHelp = false
    @State private var copiedLANURL = false
    @State private var clearMediaAcknowledged = false
    @State private var clearMediaAckTrigger = 0
    @State private var clearLogsAcknowledged = false
    @State private var clearLogsAckTrigger = 0
    @State private var trimMediaAcknowledged = false
    @State private var trimMediaAckTrigger = 0
    @State private var prefetchCutoffMbps = ExportLANServer.backgroundPrefetchCutoffMbps
    @State private var hlsTranscodeCutoffMultiplier = PCloudHLSLink.transcodeCutoffMultiplier
    @State private var vanillaDownloadBackup = VanillaWebDAVDownload.isBackupEnabled
    @State private var exportKeepAliveEnabled = ExportKeepAliveSettings.isEnabled
    @State private var exportKeepAliveTimeoutHours = ExportKeepAliveSettings.timeoutHours
    @State private var exportKeepAlivePreferControls = ExportKeepAliveSettings.preferLockScreenControls
    @State private var alternateExportSource = AlternateExportFileSource.stored
    @State private var alternateExportBusy = false
    @State private var showAlternateFilePicker = false
    @State private var switchExportTarget: ExportSwitchTarget?
    @State private var didAutoStartExport = false

    var body: some View {
        Form {
            exportControlsSection
            keepAliveSection
            randomExportTriggerSection
            exportsFolderSection
            if !status.isEmpty {
                Section("Status") {
                    Text(status).font(.caption)
                }
            }
            Section("LAN export") {
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
                    .disabled(session.isExportSessionActive)
                    .onChange(of: prefetchCutoffMbps) { _, newValue in
                        ExportLANServer.backgroundPrefetchCutoffMbps = newValue
                    }
                    .onAppear {
                        prefetchCutoffMbps = ExportLANServer.backgroundPrefetchCutoffMbps
                    }
                    if session.isExportSessionActive {
                        Text("Cutoff locked while export is running.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(
                        "Below the Mbps cutoff: LAN preload or full-file download only. At or above: 60s segments when the codec allows."
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Turn on to share pcld_ios_media on port 8765 and set the Mbps segment cutoff (default 35 Mbps).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Same Wi‑Fi as the device playing or controlling export. Use the LAN IP below — most PCs need the numeric address, not .local.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LabeledContent("About → Name") {
                    Text(ExportLANServer.deviceAboutName)
                        .font(.caption)
                }
                if let lanIPURL {
                    LabeledContent("LAN IP") {
                        Text(lanIPURL)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Button(copiedLANURL ? "Copied" : "Copy LAN URL") {
                        UIPasteboard.general.string = lanIPURL
                        copiedLANURL = true
                    }
                } else if ExportLANServer.isEnabled {
                    Text("No Wi‑Fi IPv4 address — connect to Wi‑Fi on the same network as the LAN client.")
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
                Text("WebDAV auth: \(ExportLANServer.lanWebDAVUsername) / \(ExportLANServer.lanWebDAVPassword)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("PC: Mount-LoopSegmentsRclone.ps1 maps pcld_ios_media/ over Wi‑Fi (use the LAN IP above).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(inProgressLANFootnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("Full WebDAV download", isOn: $vanillaDownloadBackup)
                    .disabled(session.isExportSessionActive)
                    .onChange(of: vanillaDownloadBackup) { _, enabled in
                        VanillaWebDAVDownload.isBackupEnabled = enabled
                    }
                    .onAppear { vanillaDownloadBackup = VanillaWebDAVDownload.isBackupEnabled }
                Text(
                    "When sparse export cannot start, copy the whole file to pcld_ios_media/_vanilla_download.<ext>. Visible on LAN while downloading; reliable for WMV/MKV and similar."
                )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("LAN page (`http://<phone-ip>:8765/`) can browse pCloud and start, pause, or stop export — keep the app open in the foreground.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                DisclosureGroup("Advanced fallback") {
                    Picker(
                        "pCloud HLS threshold",
                        selection: $hlsTranscodeCutoffMultiplier
                    ) {
                        ForEach(PCloudHLSLink.transcodeCutoffMultipliers, id: \.self) { mult in
                            Text(PCloudHLSLink.transcodeCutoffOptionLabel(multiplier: mult))
                                .tag(mult)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(session.isExportSessionActive)
                    .onChange(of: hlsTranscodeCutoffMultiplier) { _, newValue in
                        PCloudHLSLink.transcodeCutoffMultiplier = newValue
                    }
                    .onAppear {
                        hlsTranscodeCutoffMultiplier = PCloudHLSLink.transcodeCutoffMultiplier
                    }
                    if session.isExportSessionActive {
                        Text("Locked while export is running.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(
                        "Optional last resort if WebDAV probe fails and full download is off. Needs pCloud API token; often unavailable — prefer full WebDAV download or sparse _working on LAN."
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Network (pCloud)") {
                Text(network.interfaceLabel)
                if network.usesCellular {
                    Text("pCloud uses cellular — connection drops retry automatically (up to ~2 min). Keep the app open. “Network connection lost” usually recovers; try seek 0 min.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Tip: Settings → Cellular → Loop Segments → On to use pCloud over cellular.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("File") {
                Text(item.name)
                Text(item.href).font(.caption).foregroundStyle(.secondary)
            }
            Section("Output files") {
                Text("Logs (Files/USB): \(ExportPaths.exportsDirectory.path)")
                Text("Media (LAN only): Application Support/\(ExportPaths.mediaExportFolderName)/")
                    .font(.caption)
                Text("Segments: pcld_ios_media/loop/op_00|01.mp4")
                Text("Working copy: pcld_ios_media/_working.mp4 (sparse while export runs)")
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
        }
        .navigationTitle("Export")
        .safeAreaInset(edge: .top, spacing: 0) {
            if session.isExportActive(for: item) {
                let resume = resumeStore.resumeStatus(for: item)
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Exporting")
                            .font(.subheadline.weight(.semibold))
                        Text(ResumeTimeFormat.formatMs(resume.effectiveMs))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.16))
            }
        }
        .navigationDestination(item: $switchExportTarget) { target in
            ExportView(
                item: target.item,
                autoStartExport: target.autoStart,
                autoStartSeekMs: target.seekMs
            )
        }
        .sheet(isPresented: $showAlternateFilePicker) {
            AlternateExportFileSheet(
                currentItem: item,
                folderPath: nil,
                source: alternateExportSource
            ) { picked in
                beginExportOnDifferentFile(picked, autoStart: true, seekMs: 0)
            }
        }
        .onAppear {
            ExportAutoLockCoordinator.setExportPageVisible(true)
            applyForegroundResume()
            triggerAutoStartExportIfNeeded()
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
        .task(id: ExportLANServer.isEnabled) {
            guard ExportLANServer.isEnabled else {
                lanHostURL = nil
                lanIPURL = nil
                return
            }
            ExportLANServer.ensureRunning(log: { SearchDebugLog.log("LAN export: \($0)") })
            while ExportLANServer.isEnabled, !Task.isCancelled {
                if session.isExportSessionActive {
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
            return "In-progress: full download → \(path). Segments: pcld_ios_media/loop/op_*.mp4 when export runs."
        }
        if ExportPlaybackState.shared.usesPCloudTranscodedWorkingForLAN() {
            return "In-progress: pCloud transcode → pcld_ios_media/_working_pcloud_transcode.mp4 (not the original file). Segments: loop/op_*.mp4"
        }
        return "In-progress: index → plain _working link (WebDAV) or browser #t= when seek>0. Segments: pcld_ios_media/loop/op_*.mp4"
    }

    @ViewBuilder
    private var keepAliveSection: some View {
        Section("Keep Alive") {
            Toggle("Keep Alive (lock screen)", isOn: $exportKeepAliveEnabled)
                .onAppear {
                    if exportKeepAliveEnabled {
                        ExportBackgroundKeepAlive.shared.prepareAudioSessionIfEnabled()
                    }
                }
                .onChange(of: exportKeepAliveEnabled) { _, enabled in
                    ExportKeepAliveSettings.isEnabled = enabled
                    if enabled {
                        ExportBackgroundKeepAlive.shared.prepareAudioSessionIfEnabled()
                        if session.isExportActive(for: item) {
                            ExportBackgroundKeepAlive.shared.startIfEnabled(exportTitle: item.name)
                        }
                    } else {
                        ExportBackgroundKeepAlive.shared.stopForUserSettingOff()
                    }
                }
            if exportKeepAliveEnabled {
                Toggle("Prefer lock screen controls (stops other audio)", isOn: $exportKeepAlivePreferControls)
                    .onChange(of: exportKeepAlivePreferControls) { _, enabled in
                        ExportKeepAliveSettings.preferLockScreenControls = enabled
                        ExportBackgroundKeepAlive.shared.prepareAudioSessionIfEnabled()
                        if session.isExportActive(for: item) {
                            ExportBackgroundKeepAlive.shared.startIfEnabled(exportTitle: item.name)
                        }
                    }
                Picker("Keep Alive duration", selection: $exportKeepAliveTimeoutHours) {
                    ForEach(ExportKeepAliveSettings.timeoutOptions, id: \.hours) { option in
                        Text(option.label).tag(option.hours)
                    }
                }
                .onChange(of: exportKeepAliveTimeoutHours) { _, hours in
                    ExportKeepAliveSettings.timeoutHours = hours
                }
                Text(
                    exportKeepAlivePreferControls
                        ? "Keeps export alive and shows Keep Alive on lock screen / Control Center (may stop other audio apps). Play/Pause on that card controls the silence loop."
                        : "Keeps export alive without owning lock screen while other apps play. After another app stops, Keep Alive reclaims the card and resumes the loop. Turn on “Prefer lock screen controls” for Play/Pause on the card at all times."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                if ExportBackgroundKeepAlive.shared.isActive {
                    Text("Keep Alive is playing — lock the phone to see Now Playing.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else if session.isExportActive(for: item),
                          let err = ExportBackgroundKeepAlive.shared.lastStartError {
                    Text("Keep Alive failed: \(err)")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if exportKeepAliveEnabled {
                    Text("Turn on before Start export. After export starts, lock the phone — check Control Center if the lock screen card is hidden.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(
                    "Without Keep Alive, keep the app in the foreground; locking or backgrounding can stop export."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Button("Open Display in Settings") {
                Task {
                    _ = await ExportAutoLockCoordinator.openAutoLockSettings()
                    showAutoLockHelp = true
                }
            }
            Text("Screen stays on while Loop Segments is open in the foreground. Path: \(ExportAutoLockCoordinator.manualPath).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var randomExportTriggerSection: some View {
        Section("Export another file") {
            alternateExportControls
        }
    }

    @ViewBuilder
    private var alternateExportControls: some View {
        Picker("Random pool", selection: $alternateExportSource) {
            ForEach(AlternateExportFileSource.allCases) { source in
                Text(source.label).tag(source)
            }
        }
        .pickerStyle(.menu)
        .disabled(alternateExportBusy)
        .onChange(of: alternateExportSource) { _, newValue in
            AlternateExportFileSource.stored = newValue
        }

        if session.isExportSessionActive {
            Text("Stop or pause the current export before switching to another file.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Button {
            Task { await exportRandomFile() }
        } label: {
            if alternateExportBusy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Choosing…")
                }
            } else {
                Label("Export random file", systemImage: "shuffle")
            }
        }
        .disabled(session.isExportSessionActive || alternateExportBusy)

        Button {
            showAlternateFilePicker = true
        } label: {
            Label("Choose file…", systemImage: "film.stack")
        }
        .disabled(session.isExportSessionActive || alternateExportBusy)

        Text(
            "Opens export for another video at 0:00 — random from the pool above, or pick from the list. " +
                "Same folder = parent of this file on pCloud. Bookmarks = folders saved in Browse."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var exportControlsSection: some View {
        let resume = resumeStore.resumeStatus(for: item)
        let isThisFileExporting = session.isExportActive(for: item)

        Section {
            if isThisFileExporting {
                Label("Export in progress", systemImage: "arrow.down.circle")
                    .foregroundStyle(.orange)
                LabeledContent("Current position") {
                    Text(ResumeTimeFormat.formatMs(resume.effectiveMs))
                        .monospacedDigit()
                }
            } else if resume.isPaused, !isThisFileExporting {
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

            if resume.hasResumePoint, !session.isExportSessionActive {
                Button("Reset to 0:00", role: .destructive) {
                    resumeStore.clearResume(for: item)
                    seekMs = 0
                    status = "Resume cleared — next export starts at 0:00"
                }
            }

            Button(isThisFileExporting ? "Exporting…" : "Start export") {
                session.runExportUITask { await startExport() }
            }
            .disabled(session.isExportSessionActive)

            if isThisFileExporting {
                Button("Pause") {
                    session.pauseExport()
                    status = "Paused — tap Start export to continue from checkpoint"
                }
                Button("Stop", role: .destructive) {
                    session.cancelExport()
                    status = "Stopping…"
                }
            }
        } header: {
            Text("Export")
        } footer: {
            Text(
                "Pause keeps checkpoint, _working.mp4, and loop/ segments. Stop clears paused state, removes loop/ segments, " +
                    "and moves _working/vanilla/transcode copies into archive/. Clear media deletes active + archive/ (not logs)."
            )
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
            .disabled(session.isExportSessionActive)
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
            .disabled(session.isExportSessionActive)
            .foregroundStyle(clearLogsAcknowledged ? .green : Color.red)
            .sensoryFeedback(.success, trigger: clearLogsAckTrigger)
            Button {
                trimExportMediaKeepingRecent()
                acknowledgeTrimMediaTap()
            } label: {
                Label(
                    trimMediaAcknowledged ? "Trimmed" : "Trim media (keep last 2)",
                    systemImage: trimMediaAcknowledged ? "checkmark.circle.fill" : "externaldrive.fill"
                )
            }
            .disabled(session.isExportSessionActive)
            .foregroundStyle(trimMediaAcknowledged ? .green : Color.orange)
            .sensoryFeedback(.success, trigger: trimMediaAckTrigger)
            Text(
                "Active: loop/op_00|01.mp4, _working.mp4, _vanilla_faststart.mp4 (or _vanilla_download.* while downloading). Moov-at-EOF: faststart replaces download when complete. Archive: pCloud basename[_3D_*][_appFast_]<time>. Finish copies to archive/; root stays on LAN. Stop/new export moves to archive/. " +
                    "10 timestamp batches; loop/ not archived. Trim keeps 2. Clear wipes active + archive/."
            )
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func syncLANResumeHintFromStore() {
        guard FileManager.default.fileExists(atPath: ExportPaths.workingSourceURL.path) else { return }
        WorkingSourceSparseCatalog.refreshPlaybackState(for: ExportPaths.workingSourceURL)
    }

    /// `Start at` uses this field; live export position is shown separately via `resume.effectiveMs`.
    private func syncSeekFromStore() {
        let resume = resumeStore.resumeStatus(for: item)
        seekMs = resume.isPaused ? resume.effectiveMs : resume.savedSeekMs
    }

    private func applyForegroundResume() {
        let resume = resumeStore.resumeStatus(for: item)
        syncLANResumeHintFromStore()
        if session.isExportActive(for: item) {
            if status.isEmpty || status.hasPrefix("Export paused") {
                status = "Export running — logs refresh while app is open"
            }
        } else {
            syncSeekFromStore()
            if resume.isPaused, !session.isExportActive(for: item) {
                status = "Export paused — continue from \(ResumeTimeFormat.formatMs(seekMs)) (tap Start export)"
            } else if resume.savedSeekMs > 0, status.isEmpty {
                status = "Will start from \(ResumeTimeFormat.formatMs(seekMs))"
            }
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
        guard !session.isExportSessionActive else { return }
        let count = session.clearExportMedia(referenceItem: item)
        liveLogTail = ""
        status = count > 0 ? "Cleared \(count) media file(s) from Exports" : "No media files in Exports"
        refreshLogHint()
    }

    private func clearExportLogs() {
        guard !session.isExportSessionActive else { return }
        let count = ExportPaths.clearExportLogs()
        liveLogTail = ""
        status = count > 0 ? "Cleared \(count) log file(s) from Exports" : "No log files in Exports"
        refreshLogHint()
    }

    private func trimExportMediaKeepingRecent() {
        guard !session.isExportSessionActive else { return }
        let count = session.trimExportMediaArchives()
        liveLogTail = ""
        let keep = ExportMediaArchive.manualKeepCount
        let stamps = ExportMediaArchive.collectRetentionStampSuffixes().count
        status = count > 0
            ? "Trimmed archive/ media — kept \(min(stamps, keep)) timestamp batch(es), removed \(count) file(s)"
            : "No retained exports to trim (at or below \(keep) batches in pcld_ios_media/archive/)"
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

    private func acknowledgeTrimMediaTap() {
        trimMediaAcknowledged = true
        trimMediaAckTrigger += 1
        scheduleClearAcknowledgementReset { trimMediaAcknowledged = false }
    }

    private func scheduleClearAcknowledgementReset(_ reset: @escaping () -> Void) {
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { reset() }
        }
    }

    private func startExport() async {
        status = "Downloading from pCloud; publishing 60s segments as each minute completes…"
        do {
            try await session.startExport(item: item, seekMs: seekMs)
            syncSeekFromStore()
            status = "Done — segments in Exports. LAN :8765 shares media while the LAN server toggle is on."
        } catch SegmentExporterError.paused {
            syncSeekFromStore()
            let resume = resumeStore.resumeStatus(for: item)
            let at = ResumeTimeFormat.formatMs(resume.effectiveMs)
            status = "Paused — tap Start export to continue from \(at)"
        } catch is CancellationError {
            let resume = resumeStore.resumeStatus(for: item)
            if resume.isPaused {
                status = "Paused — tap Start export to continue from \(ResumeTimeFormat.formatMs(resume.effectiveMs))"
            } else {
                status = "Stopped — loop/ removed; working copies archived"
            }
        } catch SegmentExporterError.cancelled {
            status = "Stopped — loop/ removed; working copies archived"
        } catch ExportError.stillStopping {
            errorMessage = ExportError.stillStopping.errorDescription
            status = "Wait for the previous export to finish stopping"
        } catch SegmentExporterError.readerInterrupted {
            errorMessage = "pCloud read was interrupted (not Stop). Try seek 0 min or Wi‑Fi."
            status = "Interrupted — partial segments may be in Exports"
        } catch {
            errorMessage = error.localizedDescription
            status = "Failed — partial segments kept in Exports"
            syncSeekFromStore()
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
        let historyCount = ExportPaths.listExportHistoryLogRelativePaths().count
        logHint =
            "export_latest.txt \(latestBytes) B · export_progress.txt \(progressBytes) B · " +
            "logs/ \(historyCount) saved run(s) · ok.txt \(probeBytes) B"
    }

    private func fileByteCount(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber else { return 0 }
        return n.int64Value
    }

    private func triggerAutoStartExportIfNeeded() {
        guard autoStartExport, !didAutoStartExport else { return }
        didAutoStartExport = true
        seekMs = max(0, autoStartSeekMs)
        resumeStore.saveSeekMs(seekMs, for: item)
        guard !session.isExportSessionActive else { return }
        session.runExportUITask { await startExport() }
    }

    private func beginExportOnDifferentFile(_ picked: WebDAVItem, autoStart: Bool, seekMs startSeekMs: Int64 = 0) {
        let seek = max(0, startSeekMs)
        resumeStore.saveSeekMs(seek, for: picked)
        if picked.fileKey == item.fileKey {
            seekMs = seek
            guard autoStart, !session.isExportSessionActive else { return }
            session.runExportUITask { await startExport() }
            return
        }
        switchExportTarget = ExportSwitchTarget(item: picked, autoStart: autoStart, seekMs: seek)
    }

    private func exportRandomFile() async {
        guard !session.isExportSessionActive else { return }
        guard let credentials = session.credentials else {
            errorMessage = ExportError.notSignedIn.errorDescription
            return
        }
        alternateExportBusy = true
        defer { alternateExportBusy = false }
        do {
            let picked = try await AlternateExportFilePicker.pickRandom(
                excluding: item.fileKey,
                source: alternateExportSource,
                currentItem: item,
                credentials: credentials
            )
            beginExportOnDifferentFile(picked, autoStart: true, seekMs: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}
