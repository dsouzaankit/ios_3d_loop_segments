import SwiftUI

struct ExportSwitchTarget: Hashable, Identifiable {
    let item: WebDAVItem
    let autoStart: Bool
    var seekMs: Int64 = 0

    var id: String { "\(item.fileKey)-\(autoStart)-\(seekMs)" }
}

struct AlternateExportFileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    let currentItem: WebDAVItem
    let source: AlternateExportFileSource
    let onPick: (WebDAVItem) -> Void

    @State private var videos: [WebDAVItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading videos…")
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Could not list videos", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    }
                } else if videos.isEmpty {
                    ContentUnavailableView(
                        "No videos",
                        systemImage: "film",
                        description: Text("Nothing to export in this pool.")
                    )
                } else {
                    List(videos) { video in
                        Button {
                            onPick(video)
                            dismiss()
                        } label: {
                            HStack {
                                Text(video.name)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                if video.fileKey == currentItem.fileKey {
                                    Text("current")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(video.fileKey == currentItem.fileKey)
                    }
                }
            }
            .navigationTitle("Choose file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: source) {
                await loadVideos()
            }
        }
    }

    private func loadVideos() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        guard let credentials = session.credentials else {
            errorMessage = ExportError.notSignedIn.errorDescription
            return
        }
        do {
            videos = try await AlternateExportFilePicker.collectCandidates(
                source: source,
                currentItem: currentItem,
                credentials: credentials
            )
        } catch {
            errorMessage = error.localizedDescription
            videos = []
        }
    }
}
