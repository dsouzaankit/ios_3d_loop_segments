import SwiftUI

struct BrowserView: View {
    @EnvironmentObject private var session: AppSession
    @ObservedObject private var resumeStore = ResumeStore.shared
    @State private var pathStack: [String] = ["/"]
    @State private var items: [WebDAVItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var listToken = 0

    @State private var searchText = ""
    @State private var searchResults: [WebDAVItem] = []
    @State private var isSearching = false
    @State private var searchToken = 0
    @State private var searchModeNote = ""
    @State private var searchDebugStatus = ""
    @State private var selectedPausedEntry: ResumeEntry?

    private var currentPath: String { pathStack.last ?? "/" }
    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && !isSearchActive && displayedItems.isEmpty {
                    ProgressView("Loading…")
                } else {
                    List {
                        if isSearchActive, isSearching {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Searching pCloud…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !isSearchActive, #unavailable(iOS 26.0), currentPath != "/" {
                            Section {
                                Text(currentPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !isSearchActive, pathStack.count > 1 {
                            Button("↑ Up") { goUp() }
                        }
                        if !isSearchActive, !resumeStore.interruptedEntries().isEmpty {
                            Section("Paused exports") {
                                ForEach(resumeStore.interruptedEntries()) { entry in
                                    Button {
                                        selectedPausedEntry = entry
                                    } label: {
                                        HStack(alignment: .center) {
                                            pausedExportRow(entry: entry)
                                            Spacer(minLength: 4)
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if isSearchActive, !searchModeNote.isEmpty {
                            Text(searchModeNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if isSearchActive {
                            Text(searchDebugStatus)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Files app → On My iPhone → Loop Segments → Exports → search_debug.txt")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if isSearchActive, searchResults.isEmpty, !isSearching {
                            ContentUnavailableView(
                                "No results",
                                systemImage: "magnifyingglass",
                                description: Text(
                                    searchModeNote.isEmpty
                                        ? "Try another name or path fragment."
                                        : searchModeNote
                                )
                            )
                        }
                        ForEach(displayedItems) { item in
                            if item.isDirectory {
                                Button {
                                    if isSearchActive {
                                        openFolderFromSearch(item)
                                    } else {
                                        enter(item)
                                    }
                                } label: {
                                    Label(item.name, systemImage: "folder")
                                }
                            } else if item.isVideo {
                                NavigationLink {
                                    ExportView(item: item)
                                } label: {
                                    videoRowLabel(for: item)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationSubtitleIfAvailable(navigationSubtitle)
            .navigationDestination(item: $selectedPausedEntry) { entry in
                PausedExportDestinationView(
                    entry: entry,
                    browsing: items,
                    onSearchByName: { name in
                        searchText = name
                        searchToken += 1
                    }
                )
            }
            .searchable(text: $searchText, prompt: "Search pCloud")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign out") { session.signOut() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") {
                        if isSearchActive {
                            searchToken += 1
                        } else {
                            Task { await reload() }
                        }
                    }
                }
            }
            .onAppear {
                SearchDebugLog.ensureReady()
                searchDebugStatus = SearchDebugLog.statusLine()
                resumeStore.backfillHrefsFromSparseManifest()
            }
            .task(id: listToken) {
                guard !isSearchActive else { return }
                await reload()
            }
            .task(id: searchToken) {
                await runSearchDebounced()
            }
            .onChange(of: searchText) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    searchResults = []
                    searchModeNote = ""
                    isSearching = false
                    return
                }
                isSearching = true
                searchToken += 1
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var displayedItems: [WebDAVItem] {
        isSearchActive ? searchResults : items
    }

    @ViewBuilder
    private func videoRowLabel(for item: WebDAVItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(item.name, systemImage: "film")
            Spacer(minLength: 8)
            resumeBadge(for: item)
        }
    }

    @ViewBuilder
    private func pausedExportRow(entry: ResumeEntry) -> some View {
        let ms = max(entry.lastSeekMs, entry.checkpointMediaMs ?? 0)
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.displayName)
                .lineLimit(2)
            Text("Paused at \(ResumeTimeFormat.formatMs(ms)) · \(ResumeTimeFormat.relative(entry.updatedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resumeBadge(for item: WebDAVItem) -> some View {
        let resume = resumeStore.resumeStatus(for: item)
        if session.isExportRunning, session.activeExportItem?.fileKey == item.fileKey {
            Text("Exporting")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
        } else if resume.isPaused {
            Text("Paused \(ResumeTimeFormat.formatMs(resume.effectiveMs))")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
        } else if resume.savedSeekMs > 0 {
            Text("Resume \(ResumeTimeFormat.formatMs(resume.savedSeekMs))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var navigationTitle: String {
        if isSearchActive { return "Search" }
        return currentPath == "/" ? "pCloud" : (currentPath as NSString).lastPathComponent
    }

    private var navigationSubtitle: String {
        if isSearchActive {
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return q.isEmpty ? "pCloud" : "“\(q)”"
        }
        if currentPath == "/" { return "/" }
        return currentPath
    }

    private func enter(_ item: WebDAVItem) {
        guard item.isDirectory else { return }
        let next = WebDAVURLBuilder.directoryListingPath(item.href)
        guard !WebDAVURLBuilder.pathsEqual(next, currentPath) else { return }
        pathStack.append(next)
        items = []
        isLoading = true
        listToken += 1
    }

    private func openFolderFromSearch(_ item: WebDAVItem) {
        guard item.isDirectory else { return }
        searchText = ""
        searchResults = []
        isSearching = false
        pathStack = pathStack(forFolderListingPath: item.href)
        items = []
        isLoading = true
        listToken += 1
    }

    private func pathStack(forFolderListingPath listingPath: String) -> [String] {
        let dir = WebDAVURLBuilder.directoryListingPath(listingPath)
        guard dir != "/" else { return ["/"] }
        var stack = ["/"]
        let trimmed = dir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var accumulated = ""
        for part in trimmed.split(separator: "/") {
            accumulated += "/\(part)"
            stack.append(WebDAVURLBuilder.directoryListingPath(accumulated))
        }
        return stack
    }

    private func goUp() {
        guard pathStack.count > 1 else { return }
        pathStack.removeLast()
        items = []
        isLoading = true
        listToken += 1
    }

    private func reload() async {
        guard let credentials = session.credentials else { return }
        let path = currentPath
        isLoading = true
        defer { isLoading = false }
        do {
            let client = WebDAVClient(credentials: credentials)
            let loaded = try await client.list(path: path)
            guard !Task.isCancelled, WebDAVURLBuilder.pathsEqual(path, currentPath) else { return }
            items = loaded
            resumeStore.backfillHrefs(from: loaded)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            guard WebDAVURLBuilder.pathsEqual(path, currentPath) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func runSearchDebounced() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            isSearching = false
            return
        }
        let tokenAtStart = searchToken
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled, searchToken == tokenAtStart else { return }
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
        await performSearch(query: query)
    }

    private func refreshSearchDebugStatus() {
        searchDebugStatus = SearchDebugLog.statusLine()
    }

    private func performSearch(query: String) async {
        SearchDebugLog.ensureReady()
        isSearching = true
        searchModeNote = "Preparing pCloud search…"
        defer {
            isSearching = false
            refreshSearchDebugStatus()
        }
        let credentials: WebDAVCredentials
        do {
            guard let prepared = try await session.prepareCredentialsForSearch() else {
                SearchDebugLog.log("UI: search skipped — not signed in")
                refreshSearchDebugStatus()
                return
            }
            credentials = prepared
        } catch is CancellationError {
            SearchDebugLog.log("UI: search cancelled during login")
            return
        } catch {
            errorMessage = error.localizedDescription
            SearchDebugLog.log("UI: search prepare failed — \(error.localizedDescription)")
            return
        }
        SearchDebugLog.log("UI: search started for \"\(query)\"")
        refreshSearchDebugStatus()
        searchModeNote = "pCloud web search…"
        do {
            let result = try await PCloudSearchService.search(
                query: query,
                credentials: credentials,
                browsePaths: pathStack,
                status: { note in
                    Task { @MainActor in
                        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                            return
                        }
                        searchModeNote = note
                    }
                }
            )
            guard !Task.isCancelled else { return }
            guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            searchResults = result.items
            searchModeNote = result.statusNote
            SearchDebugLog.log("UI: \(result.items.count) result(s) — \(result.statusNote)")
            refreshSearchDebugStatus()
        } catch is CancellationError {
            SearchDebugLog.log("UI: search cancelled")
            return
        } catch {
            guard !Task.isCancelled else { return }
            guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            SearchDebugLog.log("UI error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }
}

private struct PausedExportDestinationView: View {
    @EnvironmentObject private var session: AppSession
    @ObservedObject private var resumeStore = ResumeStore.shared
    let entry: ResumeEntry
    let browsing: [WebDAVItem]
    let onSearchByName: (String) -> Void

    @State private var searchItem: WebDAVItem?
    @State private var isSearching = false

    var body: some View {
        Group {
            if let item = resumeStore.resolveItem(for: entry, browsing: browsing + (searchItem.map { [$0] } ?? [])) {
                ExportView(item: item)
            } else if isSearching {
                ProgressView("Finding \(entry.displayName)…")
            } else {
                ContentUnavailableView {
                    Label("File not in this folder", systemImage: "film")
                } description: {
                    Text(
                        "Search pCloud for “\(entry.displayName)” or open the folder that contains it, then tap the paused export again."
                    )
                } actions: {
                    Button("Search pCloud") {
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
            resumeStore.backfillHrefsFromSparseManifest()
            if resumeStore.resolveItem(for: entry, browsing: browsing) != nil {
                return
            }
            await resolveViaSearch()
        }
    }

    private func resolveViaSearch() async {
        guard searchItem == nil else { return }
        isSearching = true
        defer { isSearching = false }
        guard let credentials = try? await session.prepareCredentialsForSearch() else { return }
        let queries = searchQueries(for: entry)
        for query in queries {
            do {
                let result = try await PCloudSearchService.search(
                    query: query,
                    credentials: credentials,
                    browsePaths: ["/"],
                    status: nil
                )
                if let match = pickSearchMatch(in: result.items, for: entry) {
                    searchItem = match
                    resumeStore.backfillHrefs(from: [match])
                    return
                }
            } catch {}
        }
    }

    private func searchQueries(for entry: ResumeEntry) -> [String] {
        var queries: [String] = []
        let name = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            queries.append(name)
            let base = (name as NSString).deletingPathExtension
            if base != name, !base.isEmpty {
                queries.append(base)
            }
        }
        return queries
    }

    private func pickSearchMatch(in items: [WebDAVItem], for entry: ResumeEntry) -> WebDAVItem? {
        if let keyMatch = items.first(where: { $0.fileKey == entry.fileKey && $0.isVideo }) {
            return keyMatch
        }
        let target = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let videos = items.filter(\.isVideo)
        if let exact = videos.first(where: {
            $0.name.compare(target, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return exact
        }
        let targetBase = (target as NSString).deletingPathExtension
        return videos.first(where: {
            ($0.name as NSString).deletingPathExtension.compare(
                targetBase,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        })
    }
}

private extension View {
    @ViewBuilder
    func navigationSubtitleIfAvailable(_ subtitle: String) -> some View {
        if #available(iOS 26.0, *) {
            navigationSubtitle(subtitle)
        } else {
            self
        }
    }
}
