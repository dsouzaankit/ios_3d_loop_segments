import SwiftUI

struct BrowserView: View {
    @EnvironmentObject private var session: AppSession
    @ObservedObject private var resumeStore = ResumeStore.shared
    @ObservedObject private var folderBookmarkStore = FolderBookmarkStore.shared
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
    @State private var restAPISearchEnabled = PCloudSearchSettings.restAPISearchEnabled
    @State private var selectedPinnedEntry: ResumeEntry?
    @State private var pinnedSidebarEntries: [ResumeEntry] = []
    @State private var folderBookmarkEntries: [FolderBookmark] = []
    @State private var resumeByFileKey: [String: ResumeStatus] = [:]
    @State private var didSyncResumeManifest = false

    private var pathStack: [String] {
        get { session.browserPathStack }
        nonmutating set { session.browserPathStack = newValue }
    }

    private var currentPath: String { pathStack.last ?? "/" }
    private var currentFolderDisplayName: String {
        if currentPath == "/" { return "Root" }
        let trimmed = currentPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (trimmed as NSString).lastPathComponent
    }
    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && !isSearchActive && (displayedItems.isEmpty || pathStack.count > 1) {
                    ProgressView("Loading…")
                } else {
                    List {
                        if isSearchActive, isSearching {
                            HStack(alignment: .top, spacing: 8) {
                                ProgressView()
                                Text(searchModeNote.isEmpty ? "Searching pCloud…" : searchModeNote)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                                    .fixedSize(horizontal: false, vertical: true)
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
                        if !isSearchActive, !folderBookmarkEntries.isEmpty {
                            Section {
                                ForEach(folderBookmarkEntries) { bookmark in
                                    Button {
                                        openBookmark(bookmark)
                                    } label: {
                                        HStack(alignment: .center) {
                                            Label(bookmark.displayName, systemImage: "folder.fill")
                                            Spacer(minLength: 4)
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.hapticPlain)
                                    .swipeActions(edge: .trailing) {
                                        Button("Remove", role: .destructive) {
                                            folderBookmarkStore.remove(bookmark)
                                        }
                                    }
                                }
                            } header: {
                                Text("Bookmarks")
                            } footer: {
                                Text("Saved folder shortcuts. Use the bookmark button in the toolbar while browsing a folder.")
                                    .font(.footnote)
                            }
                        }
                        if !isSearchActive, !pinnedSidebarEntries.isEmpty {
                            Section {
                                ForEach(pinnedSidebarEntries) { entry in
                                    Button {
                                        selectedPinnedEntry = entry
                                    } label: {
                                        HStack(alignment: .center) {
                                            pinnedCompletedRow(entry: entry)
                                            Spacer(minLength: 4)
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.hapticPlain)
                                    .swipeActions(edge: .trailing) {
                                        Button("Remove", role: .destructive) {
                                            resumeStore.dismissPinnedCompleted(entry)
                                        }
                                    }
                                }
                            } header: {
                                Text("Last finished export")
                            } footer: {
                                Text(
                                    "Only the latest finished export is pinned. Paused mid-run files are on the Paused tab. Media under `\(ExportPaths.mediaExportFolderName)/`."
                                )
                                    .font(.footnote)
                            }
                        }
                        if isSearchActive, !searchModeNote.isEmpty, !isSearching {
                            Text(searchModeNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if isSearchActive {
                            Toggle("pCloud REST search (account-wide)", isOn: $restAPISearchEnabled)
                                .font(.footnote)
                                .onChange(of: restAPISearchEnabled) { _, enabled in
                                    PCloudSearchSettings.restAPISearchEnabled = enabled
                                }
                            Text(searchDebugStatus)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Search trace: LAN → \(ExportPaths.pathRelativeToExports(ExportPaths.searchDebugLogURL))")
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
                                .buttonStyle(.hapticPlain)
                            } else if item.isVideo {
                                NavigationLink(value: item) {
                                    videoRowLabel(for: item)
                                }
                                .buttonStyle(.hapticPlain)
                            }
                        }
                    }
                    .id(currentPath)
                }
            }
            .navigationTitle(navigationTitle)
            .navigationSubtitleIfAvailable(navigationSubtitle)
            .safeAreaInset(edge: .top, spacing: 0) {
                if session.isExportRunning, let item = session.activeExportDisplayItem {
                    NavigationLink(value: item) {
                        exportActivityBanner(for: item)
                    }
                    .buttonStyle(.hapticPlain)
                }
            }
            .navigationDestination(for: WebDAVItem.self) { item in
                ExportView(item: item)
            }
            .navigationDestination(item: $selectedPinnedEntry) { entry in
                PausedExportDestinationView(
                    entry: entry,
                    browsing: items,
                    browsePathStack: pathStack,
                    onSearchByName: { name in
                        searchText = name
                        searchToken += 1
                    }
                )
            }
            .searchable(text: $searchText, prompt: "Search pCloud")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign out") {
                        AppHaptics.tap(.light)
                        session.signOut()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !isSearchActive, currentPath != "/" {
                        Button {
                            AppHaptics.tap(.light)
                            folderBookmarkStore.toggleBookmark(
                                listingPath: currentPath,
                                displayName: currentFolderDisplayName
                            )
                        } label: {
                            Image(
                                systemName: folderBookmarkStore.isBookmarked(listingPath: currentPath)
                                    ? "bookmark.fill"
                                    : "bookmark"
                            )
                        }
                        .accessibilityLabel(
                            folderBookmarkStore.isBookmarked(listingPath: currentPath)
                                ? "Remove folder bookmark"
                                : "Bookmark this folder"
                        )
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") {
                        AppHaptics.tap(.light)
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
                refreshResumeSidebar()
                refreshFolderBookmarks()
                applyPendingBrowseSearchIfNeeded()
                if !didSyncResumeManifest {
                    didSyncResumeManifest = true
                    resumeStore.reconcilePausedWithWorkingSource()
                }
            }
            .onChange(of: resumeStore.revision) { _, _ in
                refreshResumeSidebar()
            }
            .onChange(of: session.isExportRunning) { _, _ in
                refreshResumeSidebar()
            }
            .onChange(of: session.isExportSessionActive) { _, _ in
                refreshResumeSidebar()
            }
            .onChange(of: session.activeExportItem?.fileKey) { _, _ in
                refreshResumeSidebar()
            }
            .onChange(of: session.pendingBrowseSearch) { _, _ in
                applyPendingBrowseSearchIfNeeded()
            }
            .onChange(of: session.selectedMainTab) { _, tab in
                if tab == .browse {
                    applyPendingBrowseSearchIfNeeded()
                }
            }
            .onChange(of: folderBookmarkStore.revision) { _, _ in
                refreshFolderBookmarks()
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

    @ViewBuilder
    private func videoRowLabel(for item: WebDAVItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(item.name, systemImage: "film")
            Spacer(minLength: 8)
            resumeBadge(for: item)
        }
    }

    @ViewBuilder
    private func pinnedCompletedRow(entry: ResumeEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.displayName)
                .lineLimit(2)
            Text("Media on disk (\(ExportPaths.mediaExportFolderName)/) · \(ResumeTimeFormat.relative(entry.updatedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshResumeSidebar() {
        pinnedSidebarEntries = resumeStore.pinnedCompletedEntries()
    }

    private func applyPendingBrowseSearchIfNeeded() {
        guard let pending = session.pendingBrowseSearch else { return }
        session.pendingBrowseSearch = nil
        let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchText = trimmed
        searchToken += 1
    }

    private func refreshFolderBookmarks() {
        folderBookmarkEntries = folderBookmarkStore.bookmarks()
    }

    private func openBookmark(_ bookmark: FolderBookmark) {
        searchText = ""
        searchResults = []
        isSearching = false
        pathStack = pathStack(forFolderListingPath: bookmark.listingPath)
        items = []
        resumeByFileKey = [:]
        isLoading = true
        listToken += 1
    }

    private func refreshResumeBadges(for loaded: [WebDAVItem], entries: [ResumeEntry]) {
        var cache: [String: ResumeStatus] = [:]
        for item in loaded where item.isVideo {
            cache[item.fileKey] = resumeStore.resumeStatus(for: item, in: entries)
        }
        resumeByFileKey = cache
    }

    @ViewBuilder
    private func resumeBadge(for item: WebDAVItem) -> some View {
        let resume = resumeByFileKey[item.fileKey]
            ?? ResumeStatus(
                savedSeekMs: 0,
                checkpointMs: nil,
                isPaused: false,
                updatedAt: nil,
                sourceDurationMs: nil
            )
        if session.isExportActive(for: item) {
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
        var stack = pathStack
        stack.append(next)
        pathStack = stack
        items = []
        resumeByFileKey = [:]
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
        resumeByFileKey = [:]
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
        var stack = pathStack
        stack.removeLast()
        pathStack = stack
        items = []
        resumeByFileKey = [:]
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
            let resumeEntries = resumeStore.snapshotEntries()
            items = loaded
            refreshResumeBadges(for: loaded, entries: resumeEntries)
            resumeStore.reconcileWithBrowseListing(loaded)
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
        // Let the search service publish the first status line (e.g. root-excluded scope note).
        searchModeNote = "Searching…"
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
                },
                onPartialResults: { items, note in
                    Task { @MainActor in
                        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                            return
                        }
                        searchResults = items
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
