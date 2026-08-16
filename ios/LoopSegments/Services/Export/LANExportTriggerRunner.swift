import Foundation

/// Polls `export_trigger.json` while the app is foreground, exporting, or Keep Alive is playing (LAN page PUTs triggers).
/// A LAN POST also posts `lanExportTriggerDidQueue` so a sitting trigger is consumed even if the 2s loop was stopped
/// (LAN HTTP can stay up via ExportView/coordinator `ensureRunning` after RootView cancelled the poller).
@MainActor
enum LANExportTriggerRunner {
    private static var task: Task<Void, Never>?
    private static weak var sessionRef: AppSession?
    private static var kickObserverInstalled = false

    static func setAppActive(_ active: Bool, session: AppSession) {
        sessionRef = session
        installKickObserver()
        ExportAutoLockCoordinator.setAppActive(active)
        let shouldRun = active && ExportLANServer.isEnabled && LANExportTriggerControl.isEnabled
        if !shouldRun {
            task?.cancel()
            task = nil
            return
        }
        startLoopIfNeeded(session: session)
    }

    private static func installKickObserver() {
        guard !kickObserverInstalled else { return }
        kickObserverInstalled = true
        NotificationCenter.default.addObserver(
            forName: .lanExportTriggerDidQueue,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await consumeQueuedTrigger()
            }
        }
    }

    /// Restart the poller if needed and consume `export_trigger.json` immediately (LAN REST POST).
    static func consumeQueuedTrigger() async {
        guard let session = sessionRef else { return }
        guard ExportLANServer.isEnabled, LANExportTriggerControl.isEnabled else { return }
        ExportAutoLockCoordinator.setAppActive(true)
        startLoopIfNeeded(session: session)
        await tick(session: session)
    }

    private static func startLoopIfNeeded(session: AppSession) {
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
        let note = await LANExportTriggerControl.pollAndConsume(
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
        // Do not drain in the same tick that just scheduled startExport — flags may still be idle
        // and would pop+overwrite the next queue item before the first run begins.
        let startedExport: Bool = {
            guard let note else { return false }
            return note.hasPrefix("LAN trigger — export")
                || note.hasPrefix("LAN trigger — resume")
                || note.hasPrefix("LAN trigger — random")
                || note.hasPrefix("LAN trigger — URL")
        }()
        if !startedExport {
            // Includes resolve failures ("Trigger rejected — …") so the next pending item can start.
            PendingExportQueue.shared.drainIfIdle(session: session)
        }
    }
}
