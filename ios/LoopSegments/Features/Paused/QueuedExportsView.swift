import SwiftUI

/// Pending export FIFO (not started yet). Separate from Paused checkpoints.
struct QueuedExportsView: View {
    @EnvironmentObject private var session: AppSession
    @ObservedObject private var pendingQueue = PendingExportQueue.shared

    var body: some View {
        NavigationStack {
            List {
                if pendingQueue.count > 0 {
                    Section {
                        Button("Clear queue", role: .destructive) {
                            pendingQueue.clear()
                        }
                    }
                }
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
                    }
                } footer: {
                    Text(
                        "Not started yet. Auto-starts when the phone is idle after an export finishes or Stop. " +
                            "User Pause holds the queue. Cap \(PendingExportQueue.maxItems). Companion multi-select prepends here. " +
                            "Paused tab → Move to queued appends here as fresh jobs."
                    )
                    .font(.footnote)
                }
            }
            .navigationTitle("Queued")
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
        }
    }
}
