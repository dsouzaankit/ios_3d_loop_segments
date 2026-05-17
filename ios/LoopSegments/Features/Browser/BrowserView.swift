import SwiftUI

struct BrowserView: View {
    @EnvironmentObject private var session: AppSession
    @State private var pathStack: [String] = ["/"]
    @State private var items: [WebDAVItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

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
                                Button(item.name) { enter(item) }
                            } else if item.isVideo {
                                NavigationLink(item.name) {
                                    ExportView(item: item)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(pathTitle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign out") { session.signOut() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") { Task { await reload() } }
                }
            }
            .task(id: currentPath) {
                await reload()
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var pathTitle: String {
        currentPath == "/" ? "pCloud" : (currentPath as NSString).lastPathComponent
    }

    private func enter(_ item: WebDAVItem) {
        pathStack.append(item.href.hasSuffix("/") ? item.href : item.href + "/")
    }

    private func goUp() {
        guard pathStack.count > 1 else { return }
        pathStack.removeLast()
    }

    private func reload() async {
        guard let credentials = session.credentials else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = WebDAVClient(credentials: credentials)
            items = try await client.list(path: currentPath)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
