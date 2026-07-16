import SwiftUI

/// Resolves a paused or pinned resume row to `ExportView` (listing match, sparse href, or pCloud search).
struct PausedExportDestinationView: View {
    @EnvironmentObject private var session: AppSession
    @ObservedObject private var resumeStore = ResumeStore.shared
    let entry: ResumeEntry
    let browsing: [WebDAVItem]
    /// Browse folder stack — merged with bookmarks inside `PCloudSearchService` (same as Browse search).
    let browsePathStack: [String]
    let onSearchByName: (String) -> Void

    @State private var searchItem: WebDAVItem?
    @State private var isSearching = false
    @State private var searchStatusLine = ""
    @State private var resolveError: String?

    var body: some View {
        Group {
            if let item = resumeStore.resolveItem(for: entry, browsing: browsing + (searchItem.map { [$0] } ?? [])) {
                ExportView(item: item)
            } else if isSearching {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Finding \(entry.displayName)…")
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
                    Button("Search in Browse") {
                        onSearchByName(entry.displayName)
                    }
                    Button("Try again") {
                        Task { await resolveViaSearch() }
                    }
                }
            }
        }
        .navigationTitle(entry.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            resumeStore.reconcilePausedWithWorkingSource()
            if resumeStore.resolveItem(for: entry, browsing: browsing) != nil {
                return
            }
            await resolveViaSearch()
        }
    }

    private var notFoundTitle: String {
        entry.pinnedCompleted ? "Source not found yet" : "File not in this folder"
    }

    private var notFoundDescription: String {
        if let resolveError, !resolveError.isEmpty {
            return resolveError
        }
        if entry.pinnedCompleted {
            return """
            Segment media is on disk; searching pCloud (bookmarks + Browse path, same as the search bar) to open Export for the source file. \
            Tap Try again or Search in Browse.
            """
        }
        return """
        Tries the saved folderPath (one-level list), then the same pCloud search as Browse. \
        Open the folder that contains the file or tap Search in Browse.
        """
    }

    private func resolveViaSearch() async {
        guard searchItem == nil else { return }
        SearchDebugLog.ensureReady()
        isSearching = true
        searchStatusLine = "Preparing pCloud search…"
        resolveError = nil
        defer {
            isSearching = false
        }
        let credentials: WebDAVCredentials
        do {
            guard let prepared = try await session.prepareCredentialsForSearch() else {
                SearchDebugLog.log("resume resolve UI: not signed in")
                resolveError = "Sign in to search pCloud for this file."
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
            if let match = try await PCloudSearchService.searchMatchingResumeEntry(
                entry: entry,
                credentials: credentials,
                browsePaths: browsePathStack,
                status: { note in
                    Task { @MainActor in
                        searchStatusLine = note
                    }
                }
            ) {
                searchItem = match
                resumeStore.backfillHrefs(from: [match])
                searchStatusLine = ""
                return
            }
            resolveError = entry.pinnedCompleted
                ? "No matching file in bookmarks or Browse path. Turn on pCloud REST search in Browse or open the source folder."
                : "No matching file found. Try Search in Browse or enable pCloud REST search."
        } catch is CancellationError {
            SearchDebugLog.log("resume resolve UI: cancelled")
        } catch {
            SearchDebugLog.log("resume resolve UI: \(error.localizedDescription)")
            resolveError = error.localizedDescription
        }
    }
}
