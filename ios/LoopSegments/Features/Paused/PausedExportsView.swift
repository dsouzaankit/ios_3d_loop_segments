import SwiftUI

/// Paused / interrupted export checkpoints (multi-pause handoff). Browse keeps only the last-finished pin.
/// Pending FIFO lives on the Queued tab.
struct PausedExportsView: View {
    @EnvironmentObject private var session: AppSession
    @ObservedObject private var resumeStore = ResumeStore.shared
    @ObservedObject private var pendingQueue = PendingExportQueue.shared

    @State private var selectedEntry: ResumeEntry?
    @State private var entries: [ResumeEntry] = []

    var body: some View {
        NavigationStack {
            List {
                if !entries.isEmpty {
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
                                selectedEntry = entry
                            } label: {
                                HStack(alignment: .center) {
                                    pausedRow(entry: entry)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
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
                            "Move to queued appends all paused rows onto the Queued tab as fresh jobs (checkpoints and parked media dropped; releases Pause hold) so they auto-start when idle. " +
                            "Clear paused removes checkpoints (and parked media) but keeps a live export running."
                    )
                    .font(.footnote)
                }
            }
            .navigationTitle("Paused")
            .safeAreaInset(edge: .top, spacing: 0) {
                if session.isExportRunning, let item = session.activeExportDisplayItem {
                    NavigationLink {
                        ExportView(item: item)
                    } label: {
                        ExportActivityBanner(itemName: item.name)
                    }
                    .buttonStyle(.hapticPlain)
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

    private func refresh() {
        let activeKey = session.activeExportFileKey
        entries = resumeStore.interruptedEntries(excludingFileKey: activeKey)
        if let selected = selectedEntry,
           !entries.contains(where: { $0.fileKey == selected.fileKey }) {
            selectedEntry = nil
        }
    }
}
