import SwiftUI

struct BrowserView: View {
    @EnvironmentObject private var session: AppSession
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
                        if isSearchActive, !searchModeNote.isEmpty {
                            Text(searchModeNote)
                                .font(.caption)
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
                                    Label(item.name, systemImage: "film")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationSubtitleIfAvailable(navigationSubtitle)
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

    private func performSearch(query: String) async {
        guard let credentials = session.credentials else { return }
        isSearching = true
        searchModeNote = "Searching folders (WebDAV), then pCloud index…"
        defer { isSearching = false }
        do {
            let result = try await PCloudSearchService.search(
                query: query,
                credentials: credentials,
                browsePaths: pathStack
            )
            guard !Task.isCancelled else { return }
            guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            searchResults = result.items
            searchModeNote = result.statusNote
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
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
