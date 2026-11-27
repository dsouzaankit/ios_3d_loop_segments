import SwiftUI

/// Paused / interrupted export checkpoints (multi-pause handoff). Browse keeps only the last-finished pin.
/// Pending FIFO lives on the Queued tab.
struct PausedExportsView: View {
    @EnvironmentObject private var session: AppSession
    @ObservedObject private var resumeStore = ResumeStore.shared
    @ObservedObject private var pendingQueue = PendingExportQueue.shared
    @ObservedObject private var lanResolve = LANExportResolveState.shared

    @State private var selectedEntry: ResumeEntry?
    @State private var entries: [ResumeEntry] = []
    /// Select mode: tick rows, then Queue selected (fresh jobs, same as Move to queued but only those rows).
    @State private var isSelecting = false
    @State private var selectedKeys: Set<String> = []

    private var selectableKeys: Set<String> {
        Set(entries.filter { !$0.isSourceUnavailable }.map(\.fileKey))
    }

    var body: some View {
        NavigationStack {
            List {
                if isSelecting {
                    Section {
                        Button("Queue \(selectedKeys.count) selected") {
                            _ = resumeStore.moveAllPausedExportsToPendingQueue(
                                exceptFileKey: session.activeExportFileKey,
                                onlyFileKeys: selectedKeys
                            )
                            PendingExportQueue.shared.drainIfIdle(session: session)
                            selectedKeys = []
                            isSelecting = false
                            refresh()
                        }
                        .disabled(selectedKeys.isEmpty)
                        let all = selectableKeys
                        if !all.isEmpty && selectedKeys == all {
                            Button("Deselect all") { selectedKeys = [] }
                        } else {
                            Button("Select all") { selectedKeys = all }
                                .disabled(all.isEmpty)
                        }
                    }
                } else if !entries.isEmpty {
                    Section {
                        Button("Move to queued") {
                            _ = resumeStore.moveAllPausedExportsToPendingQueue(
                                exceptFileKey: session.activeExportFileKey
                            )
                            PendingExportQueue.shared.drainIfIdle(session: session)
                            refresh()
                        }
                        Button("Clear paused", role: .destructive) {
                            resumeStore.clearPausedExports(exceptFileKey: session.activeExportFileKey)
                            refresh()
                        }
                    }
                }
                Section {
                    if entries.isEmpty {
                        Text("No paused exports")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(entries) { entry in
                            Button {
                                if isSelecting {
                                    toggleSelection(entry)
                                } else {
                                    selectedEntry = entry
                                }
                            } label: {
                                HStack(alignment: .center) {
                                    if isSelecting {
                                        selectionMark(entry: entry)
                                    }
                                    pausedRow(entry: entry)
                                    Spacer(minLength: 4)
                                    if !isSelecting {
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.hapticPlain)
                            .contextMenu {
                                Button("Copy name") {
                                    UIPasteboard.general.string = entry.resolvedDisplayName
                                }
                                Button("Search in Browse") {
                                    session.pendingBrowseSearch = entry.resolvedDisplayName
                                    session.selectedMainTab = .browse
                                }
                                Button("Remove", role: .destructive) {
                                    resumeStore.dismissPausedExport(entry)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Remove", role: .destructive) {
                                    resumeStore.dismissPausedExport(entry)
                                }
                            }
                        }
                    }
                } footer: {
                    Text(
                        "Cap is \(ResumeStore.maxPausedExports) in-progress slots total (includes the live export). " +
                            "While exporting, this list shows up to \(ResumeStore.maxPausedExports - 1); a handoff may briefly show \(ResumeStore.maxPausedExports) then drop the oldest. " +
                            "Handoff parks root media under pcld_ios_media/\(ExportParkedMedia.folderName)/ (LAN-playable); resume restores then sparse-adopts. " +
                            "Each row stores its pCloud folder for a fast one-level resume list. If that folder no longer has the file, the row is unavailable — redo search and re-export using web companion, or Copy name / Search in Browse (stale path is dropped so a move can still match). Swipe to remove. " +
                            "Select lets you tick rows and Queue selected moves just those (unavailable rows can't be picked). " +
                            "Move to queued appends all paused rows onto the Queued tab as fresh jobs (checkpoints and parked media dropped; releases Pause hold) so they auto-start when idle. " +
                            "Clear paused removes checkpoints (and parked media) but keeps a live export running."
                    )
                    .font(.footnote)
                }
            }
            .navigationTitle("Paused")
            .toolbar {
                if isSelecting || !selectableKeys.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(isSelecting ? "Done" : "Select") {
                            isSelecting.toggle()
                            selectedKeys = []
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if session.isExportRunning, let item = session.activeExportDisplayItem {
                    NavigationLink {
                        ExportView(item: item)
                    } label: {
                        ExportActivityBanner(itemName: item.name)
                    }
                    .buttonStyle(.hapticPlain)
                } else if let name = lanResolve.displayName {
                    ExportActivityBanner(title: "Starting…", itemName: name, showsOpen: false)
                }
            }
            .navigationDestination(item: $selectedEntry) { entry in
                PausedExportDestinationView(
                    entry: entry,
                    browsing: []
                )
            }
            .onAppear { refresh() }
            .onChange(of: resumeStore.revision) { _, _ in refresh() }
            .onChange(of: pendingQueue.revision) { _, _ in refresh() }
            .onChange(of: session.isExportRunning) { _, _ in refresh() }
            .onChange(of: session.isExportSessionActive) { _, _ in refresh() }
            .onChange(of: session.activeExportItem?.fileKey) { _, _ in refresh() }
        }
    }

    @ViewBuilder
    private func pausedRow(entry: ResumeEntry) -> some View {
        let ms = entry.effectiveResumeSeekMs
        let title = entry.resolvedDisplayName.isEmpty ? "Untitled export" : entry.resolvedDisplayName
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .lineLimit(2)
            if entry.isSourceUnavailable {
                Text(ResumeStore.pCloudSourceUnavailableMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Paused at \(ResumeTimeFormat.formatMs(ms)) · \(ResumeTimeFormat.relative(entry.updatedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let folder = entry.folderPath, !folder.isEmpty {
                Text(folder)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func selectionMark(entry: ResumeEntry) -> some View {
        if entry.isSourceUnavailable {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.tertiary)
        } else if selectedKeys.contains(entry.fileKey) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }

    private func toggleSelection(_ entry: ResumeEntry) {
        guard !entry.isSourceUnavailable else { return }
        if selectedKeys.contains(entry.fileKey) {
            selectedKeys.remove(entry.fileKey)
        } else {
            selectedKeys.insert(entry.fileKey)
        }
    }

    private func refresh() {
        let activeKey = session.activeExportFileKey
        entries = resumeStore.interruptedEntries(excludingFileKey: activeKey)
        selectedKeys.formIntersection(selectableKeys)
        if isSelecting && selectableKeys.isEmpty {
            isSelecting = false
        }
        if let selected = selectedEntry,
           !entries.contains(where: { $0.fileKey == selected.fileKey }) {
            selectedEntry = nil
        }
    }
}
