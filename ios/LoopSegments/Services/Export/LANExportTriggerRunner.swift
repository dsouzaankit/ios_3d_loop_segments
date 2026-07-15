import Foundation

/// Polls `export_trigger.json` while the app is foreground, exporting, or Keep Alive is playing (LAN page PUTs triggers).
@MainActor
enum LANExportTriggerRunner {
    private static var task: Task<Void, Never>?

    static func setAppActive(_ active: Bool, session: AppSession) {
        task?.cancel()
        task = nil
        ExportAutoLockCoordinator.setAppActive(active)
        guard active, ExportLANServer.isEnabled, LANExportTriggerControl.isEnabled else { return }
        task = Task {
            while !Task.isCancelled {
                await tick(session: session)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private static func tick(session: AppSession) async {
        let reference = LANExportContext.referenceOrActive(from: session)
            ?? WebDAVItem(href: "/", name: "Root", isDirectory: true, contentLength: nil)
        _ = await LANExportTriggerControl.pollAndConsume(
            credentials: session.credentials,
            currentItem: reference,
            isExportRunning: session.isExportRunning,
            isExportCoordinatorBusy: session.isExportCoordinatorBusy,
            prepareForFreshStart: { await session.prepareForLANFreshExport() },
            onStartExport: { item, seek in
                LANExportContext.saveReference(item)
                Task {
                    do {
                        try await session.startExport(item: item, seekMs: seek)
                    } catch {
                        SearchDebugLog.log("LAN HTTP trigger export failed: \(error.localizedDescription)")
                    }
                }
            },
            onPause: { session.pauseExport() },
            onStop: { session.cancelExport() },
            onClearMedia: { session.clearExportMedia(referenceItem: reference) },
            onTrimMedia: { session.trimExportMediaArchives() },
            onDownloadURL: { url, saveName in
                Task {
                    do {
                        try await session.startURLDownload(remoteURL: url, saveName: saveName)
                    } catch {
                        SearchDebugLog.log("LAN URL download failed: \(error.localizedDescription)")
                        ExportRuntimeLog.mirror("URL download failed: \(error.localizedDescription)")
                    }
                }
            },
            isURLDownloadRunning: session.isURLDownloadRunning
        )
    }
}
