import SwiftUI

/// Lists every paused / interrupted export (multi-pause handoff). Browse keeps only the last-finished pin.
struct PausedExportsView: View {
    @EnvironmentObject private var session: AppSession
    @ObservedObject private var resumeStore = ResumeStore.shared

    @State private var selectedEntry: ResumeEntry?
    @State private var entries: [ResumeEntry] = []

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No paused exports",
                        systemImage: "pause.circle",
                        description: Text(
                            "When you start another export while one is running, the previous file stays here with its checkpoint."
                        )
                    )
                } else {
                    List {
                        Section {
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
                        } footer: {
                            Text(
                                "Cap is \(ResumeStore.maxPausedExports) in-progress slots total (includes the live export). " +
                                    "While exporting, this list shows up to \(ResumeStore.maxPausedExports - 1); a handoff may briefly show \(ResumeStore.maxPausedExports) then drop the oldest. " +
                                    "Each row stores its pCloud folder for a fast one-level resume list before a full walk. Swipe to remove."
                            )
                            .font(.footnote)
                        }
                    }
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
            .onChange(of: session.isExportRunning) { _, _ in refresh() }
            .onChange(of: session.isExportSessionActive) { _, _ in refresh() }
            .onChange(of: session.activeExportItem?.fileKey) { _, _ in refresh() }
        }
    }

    @ViewBuilder
    private func pausedRow(entry: ResumeEntry) -> some View {
        let ms = max(entry.lastSeekMs, entry.checkpointMediaMs ?? 0)
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.displayName)
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
    }
}
