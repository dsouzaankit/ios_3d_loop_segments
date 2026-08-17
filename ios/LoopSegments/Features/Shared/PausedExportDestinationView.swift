import SwiftUI

/// Resolves a paused or pinned resume row to `ExportView` (listing match, or unavailable if the saved folder moved).
struct PausedExportDestinationView: View {
    @EnvironmentObject private var session: AppSession
    @ObservedObject private var resumeStore = ResumeStore.shared
    let entry: ResumeEntry
    let browsing: [WebDAVItem]

    @State private var searchItem: WebDAVItem?
    @State private var isSearching = false
    @State private var searchStatusLine = ""
    @State private var resolveError: String?

    private var liveEntry: ResumeEntry {
        resumeStore.snapshotEntries().first { $0.fileKey == entry.fileKey } ?? entry
    }

    var body: some View {
        Group {
            if liveEntry.isSourceUnavailable {
                unavailableView
            } else if let item = searchItem {
                ExportView(item: item)
            } else if let item = resumeStore.resolveItem(for: liveEntry, browsing: browsing), !browsing.isEmpty {
                ExportView(item: item)
            } else if isSearching {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Finding \(liveEntry.resolvedDisplayName.isEmpty ? "paused export" : liveEntry.resolvedDisplayName)…")
                        .font(.subheadline)
                    if !searchStatusLine.isEmpty {
                        Text(searchStatusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                            .padding(.horizontal)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(notFoundTitle, systemImage: "film")
                } description: {
                    Text(notFoundDescription)
                } actions: {
                    if !liveEntry.isSourceUnavailable {
                        Button("Try folder again") {
                            Task { await resolveViaFolderList() }
                        }
                    }
                }
            }
        }
        .navigationTitle(liveEntry.resolvedDisplayName.isEmpty ? "Paused export" : liveEntry.resolvedDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            resumeStore.reconcilePausedWithWorkingSource()
            if liveEntry.isSourceUnavailable { return }
            if !browsing.isEmpty, resumeStore.resolveItem(for: liveEntry, browsing: browsing) != nil {
                return
            }
            await resolveViaFolderList()
        }
    }

    private var unavailableView: some View {
        ContentUnavailableView {
            Label("Unavailable", systemImage: "icloud.slash")
        } description: {
            Text(ResumeStore.pCloudSourceUnavailableMessage)
        } actions: {
            Button("Copy name") {
                UIPasteboard.general.string = liveEntry.resolvedDisplayName
            }
            Button("Search in Browse") {
                session.pendingBrowseSearch = liveEntry.resolvedDisplayName
                session.selectedMainTab = .browse
            }
            Button("Remove from Paused", role: .destructive) {
                resumeStore.dismissPausedExport(liveEntry)
            }
        }
    }

    private var notFoundTitle: String {
        liveEntry.pinnedCompleted ? "Source not found yet" : "File not in this folder"
    }

    private var notFoundDescription: String {
        if let resolveError, !resolveError.isEmpty {
            return resolveError
        }
        if liveEntry.pinnedCompleted {
            return ResumeStore.pCloudSourceUnavailableMessage
        }
        return ResumeStore.pCloudSourceUnavailableMessage
    }

    private func resolveViaFolderList() async {
        guard searchItem == nil, !liveEntry.isSourceUnavailable else { return }
        SearchDebugLog.ensureReady()
        isSearching = true
        searchStatusLine = "Checking saved pCloud folder…"
        resolveError = nil
        defer { isSearching = false }

        let folder = liveEntry.folderPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !folder.isEmpty else {
            resumeStore.markPCloudSourceUnavailable(
                displayName: liveEntry.resolvedDisplayName,
                href: liveEntry.href,
                folderPath: nil
            )
            resolveError = ResumeStore.pCloudSourceUnavailableMessage
            return
        }

        let credentials: WebDAVCredentials
        do {
            guard let prepared = try await session.prepareCredentialsForSearch() else {
                SearchDebugLog.log("resume resolve UI: not signed in")
                resolveError = "Sign in to check the saved pCloud folder."
                return
            }
            credentials = prepared
        } catch is CancellationError {
            return
        } catch {
            SearchDebugLog.log("resume resolve UI: prepare failed — \(error.localizedDescription)")
            resolveError = error.localizedDescription
            return
        }

        do {
            let match = try await AlternateExportFilePicker.findVideo(
                named: liveEntry.resolvedDisplayName,
                in: folder,
                credentials: credentials
            )
            searchItem = match
            resumeStore.backfillHrefs(from: [match])
            searchStatusLine = ""
        } catch is CancellationError {
            SearchDebugLog.log("resume resolve UI: cancelled")
        } catch {
            SearchDebugLog.log("resume resolve UI: folder miss — \(error.localizedDescription)")
            resumeStore.markPCloudSourceUnavailable(
                displayName: liveEntry.resolvedDisplayName,
                href: liveEntry.href,
                folderPath: folder
            )
            resolveError = ResumeStore.pCloudSourceUnavailableMessage
        }
    }
}
