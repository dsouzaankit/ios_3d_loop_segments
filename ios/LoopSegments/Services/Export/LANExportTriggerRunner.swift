import Foundation

/// Polls `export_trigger.json` while the app is foreground, exporting, or Keep Alive is playing (LAN page PUTs triggers).
@MainActor
enum LANExportTriggerRunner {
    private static var task: Task<Void, Never>?

    static func setAppActive(_ active: Bool, session: AppSession) {
        ExportAutoLockCoordinator.setAppActive(active)
        let shouldRun = active && ExportLANServer.isEnabled && LANExportTriggerControl.isEnabled
        if !shouldRun {
            task?.cancel()
            task = nil
            return
        }
        // Do not cancel/restart an already-running poller — `isExportSessionActive` flips when
        // LAN-triggered startExport begins, and restarting here can drop the start Task.
        if task != nil { return }
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
            pauseRunningForResolve: { await session.pauseRunningExportForResolve() },
            onStartExport: { item, seek in
                LANExportContext.saveReference(item)
                session.runExportUITask {
                    do {
                        try await session.startExport(item: item, seekMs: seek)
                    } catch {
                        SearchDebugLog.log("LAN HTTP trigger export failed: \(error.localizedDescription)")
                        ExportRuntimeLog.mirror("LAN export failed: \(error.localizedDescription)")
                    }
                }
            },
            onPause: { session.pauseExport() },
            onStop: { session.cancelExport() },
            onClearMedia: { session.clearExportMedia(referenceItem: reference) },
            onTrimMedia: { session.trimExportMediaArchives() }
        )
    }
}
