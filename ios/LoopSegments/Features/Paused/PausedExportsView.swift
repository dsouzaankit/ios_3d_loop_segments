import SwiftUI

/// Lists every paused / interrupted export (multi-pause handoff). Browse keeps only the last-finished pin.
/// Also shows **Queued** pending FIFO (not started yet) above paused rows — section always visible.
struct PausedExportsView: View {
    @EnvironmentObject private var session: AppSession
    @ObservedObject private var resumeStore = ResumeStore.shared
    @ObservedObject private var pendingQueue = PendingExportQueue.shared

    @State private var selectedEntry: ResumeEntry?
    @State private var entries: [ResumeEntry] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if pendingQueue.items.isEmpty {
                        Text("No queued exports")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pendingQueue.items) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayName)
                                    .lineLimit(2)
                                Text("Queued · waiting")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let folder = item.folderPath, !folder.isEmpty {
                                    Text(folder)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Remove", role: .destructive) {
                                    pendingQueue.remove(id: item.id)
                                }
                            }
                        }
                        Button("Clear queue", role: .destructive) {
                            pendingQueue.clear()
                        }
                    }
                } header: {
                    Text("Queued (\(pendingQueue.count))")
                } footer: {
                    Text(
                        "Not started yet. Auto-starts when the phone is idle after an export finishes or Stop. " +
                            "User Pause holds the queue. Cap \(PendingExportQueue.maxItems). Companion multi-select prepends here."
                    )
                    .font(.footnote)
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
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button("Remove", role: .destructive) {
                                    resumeStore.dismissPausedExport(entry)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Paused (\(entries.count))")
                } footer: {
                    Text(
                        "Cap is \(ResumeStore.maxPausedExports) in-progress slots total (includes the live export). " +
                            "While exporting, this list shows up to \(ResumeStore.maxPausedExports - 1); a handoff may briefly show \(ResumeStore.maxPausedExports) then drop the oldest. " +
                            "Handoff parks root media under pcld_ios_media/\(ExportParkedMedia.folderName)/ (LAN-playable); resume restores then sparse-adopts. " +
                            "Each row stores its pCloud folder for a fast one-level resume list before a full walk. Swipe to remove."
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
                        exportActivityBanner(for: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationDestination(item: $selectedEntry) { entry in
                PausedExportDestinationView(
                    entry: entry,
                    browsing: [],
                    browsePathStack: session.browserPathStack,
                    onSearchByName: { name in
                        session.pendingBrowseSearch = name
                        session.selectedMainTab = .browse
                    }
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
        let ms = max(entry.lastSeekMs, entry.checkpointMediaMs ?? 0)
        let title = entry.resolvedDisplayName.isEmpty ? "Untitled export" : entry.resolvedDisplayName
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .lineLimit(2)
            Text("Paused at \(ResumeTimeFormat.formatMs(ms)) · \(ResumeTimeFormat.relative(entry.updatedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let folder = entry.folderPath, !folder.isEmpty {
                Text(folder)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func exportActivityBanner(for item: WebDAVItem) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Exporting")
                    .font(.subheadline.weight(.semibold))
                Text(item.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("Open")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.16))
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
