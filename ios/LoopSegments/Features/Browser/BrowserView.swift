import SwiftUI

struct BrowserView: View {
    @EnvironmentObject private var session: AppSession
    @State private var pathStack: [String] = ["/"]
    @State private var items: [WebDAVItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var listToken = 0

    private var currentPath: String { pathStack.last ?? "/" }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && items.isEmpty {
                    ProgressView("Loading…")
                } else {
                    List {
                        if pathStack.count > 1 {
                            Button("↑ Up") { goUp() }
                        }
                        ForEach(items) { item in
                            if item.isDirectory {
                                Button {
                                    enter(item)
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
            .navigationTitle(pathTitle)
            .navigationSubtitle(navigationSubtitle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign out") { session.signOut() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") { Task { await reload() } }
                }
            }
            .task(id: listToken) {
                await reload()
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

    private var pathTitle: String {
        currentPath == "/" ? "pCloud" : (currentPath as NSString).lastPathComponent
    }

    private var navigationSubtitle: String {
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
}
