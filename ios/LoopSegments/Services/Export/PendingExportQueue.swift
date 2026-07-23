import Foundation

/// Not-yet-started companion / LAN export jobs (FIFO). Separate from Paused (`ResumeStore`).
struct PendingExportItem: Codable, Identifiable, Equatable {
    var id: String
    var folderPath: String?
    var displayName: String
    var seekMs: Int64?

    init(id: String = UUID().uuidString, folderPath: String?, displayName: String, seekMs: Int64? = nil) {
        self.id = id.isEmpty ? UUID().uuidString : id
        self.folderPath = folderPath
        self.displayName = displayName
        self.seekMs = seekMs
    }
}

enum PendingExportEnqueueMode: String, Codable {
    case append
    case prepend
    case replace
}

@MainActor
final class PendingExportQueue: ObservableObject {
    static let shared = PendingExportQueue()

    static let maxItems = 50
    /// Readable off the main actor (LAN `status.json`).
    nonisolated static let relativePath = "pcld_ios_media/scripts/export_pending_queue.json"

    @Published private(set) var items: [PendingExportItem] = []
    @Published private(set) var revision: Int = 0

    private init() {
        loadFromDisk()
    }

    var count: Int { items.count }

    func snapshot() -> [PendingExportItem] { items }

    @discardableResult
    func enqueue(_ newItems: [PendingExportItem], mode: PendingExportEnqueueMode) -> [PendingExportItem] {
        let cleaned = newItems
            .map { item -> PendingExportItem in
                var copy = item
                let name = copy.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                copy.displayName = name
                if let folder = copy.folderPath?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty {
                    copy.folderPath = WebDAVURLBuilder.directoryListingPath(folder)
                } else {
                    copy.folderPath = nil
                }
                if copy.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    copy.id = UUID().uuidString
                }
                return copy
            }
            .filter { !$0.displayName.isEmpty }

        switch mode {
        case .replace:
            items = Array(cleaned.prefix(Self.maxItems))
        case .append:
            items.append(contentsOf: cleaned)
            if items.count > Self.maxItems {
                items = Array(items.suffix(Self.maxItems))
            }
        case .prepend:
            items = cleaned + items
            if items.count > Self.maxItems {
                items = Array(items.prefix(Self.maxItems))
            }
        }
        persist()
        return cleaned
    }

    @discardableResult
    func popFront() -> PendingExportItem? {
        guard !items.isEmpty else { return nil }
        let first = items.removeFirst()
        persist()
        return first
    }

    func remove(id: String) {
        let before = items.count
        items.removeAll { $0.id == id }
        if items.count != before { persist() }
    }

    @discardableResult
    func removeReturningChanged(id: String) -> Bool {
        let before = items.count
        items.removeAll { $0.id == id }
        let changed = items.count != before
        if changed { persist() }
        return changed
    }

    func clear() {
        guard !items.isEmpty else { return }
        items = []
        persist()
    }

    /// REST manage: `action=remove` (needs `id`) or `action=clear`.
    static func manageFromREST(action: String, id: String?) -> (httpStatus: Int, payload: [String: Any]) {
        let act = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch act {
        case "clear":
            let before = shared.count
            shared.clear()
            return (
                200,
                [
                    "status": "ok",
                    "action": "clear",
                    "removed": before,
                    "pendingCount": shared.count,
                    "message": before == 0 ? "Queue already empty" : "Cleared \(before) queued item(s)",
                ]
            )
        case "remove":
            let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else {
                return (
                    400,
                    [
                        "status": "rejected",
                        "action": "remove",
                        "message": "id required",
                    ]
                )
            }
            let changed = shared.removeReturningChanged(id: trimmed)
            return (
                changed ? 200 : 404,
                [
                    "status": changed ? "ok" : "not_found",
                    "action": "remove",
                    "id": trimmed,
                    "pendingCount": shared.count,
                    "message": changed ? "Removed from queue" : "No queued item with that id",
                ]
            )
        default:
            return (
                400,
                [
                    "status": "rejected",
                    "message": "Unknown action — use remove (with id) or clear",
                ]
            )
        }
    }

    /// Start next pending job when idle. Skips while user/auto Pause is held or an export is active.
    /// Soft-paused checkpoints (Paused tab) must NOT block drain — only `userRequestedExportPause`.
    func drainIfIdle(session: AppSession) {
        guard !session.isExportRunning, !session.isExportCoordinatorBusy else { return }
        guard !session.userRequestedExportPause else { return }
        // Avoid overwriting an unconsumed trigger (e.g. startFirst just wrote one).
        if LANExportTriggerControl.hasPendingTriggerFile { return }
        guard let next = popFront() else { return }
        let folder = next.folderPath ?? ""
        let queued = LANExportTriggerControl.queueStartExportFromFolder(
            folderPath: folder,
            displayName: next.displayName,
            seekMs: next.seekMs,
            triggerId: next.id
        )
        SearchDebugLog.log(
            "Pending queue drain → \(next.displayName) status=\(queued.httpStatus)"
        )
        ExportRuntimeLog.mirror("Pending queue: starting \(next.displayName)")
    }

    /// REST: enqueue items; optionally start the first immediately (soft-pauses a running export).
    static func queueFromREST(
        items: [PendingExportItem],
        mode: PendingExportEnqueueMode,
        startFirst: Bool,
        sessionIsBusy: Bool
    ) -> (httpStatus: Int, payload: [String: Any]) {
        guard !items.isEmpty else {
            return (
                400,
                [
                    "status": "rejected",
                    "message": "items[] required — each needs displayName (or saveName)",
                ]
            )
        }
        let accepted = shared.enqueue(items, mode: mode)
        guard !accepted.isEmpty else {
            return (
                400,
                [
                    "status": "rejected",
                    "message": "No valid items (displayName required)",
                ]
            )
        }

        var payload: [String: Any] = [
            "status": "queued",
            "mode": mode.rawValue,
            "accepted": accepted.count,
            "pendingCount": shared.count,
            "pending": shared.items.prefix(20).map { item -> [String: Any] in
                var row: [String: Any] = [
                    "id": item.id,
                    "displayName": item.displayName,
                ]
                if let folder = item.folderPath { row["folderPath"] = folder }
                if let seek = item.seekMs { row["seekMs"] = seek }
                return row
            },
            "message": "Pending export queue updated",
        ]

        if startFirst {
            // Pop front and write export_trigger so Runner starts it (soft-pauses if busy).
            if let first = shared.popFront() {
                let folder = first.folderPath ?? ""
                let started = LANExportTriggerControl.queueStartExportFromFolder(
                    folderPath: folder,
                    displayName: first.displayName,
                    seekMs: first.seekMs,
                    triggerId: first.id
                )
                payload["started"] = started.payload
                payload["pendingCount"] = shared.count
                payload["message"] = sessionIsBusy
                    ? "Prepended queue; starting first item (soft-pauses current export)"
                    : "Queue accepted; starting first item"
                return (202, payload)
            }
        }

        return (202, payload)
    }

    private func persist() {
        revision += 1
        guard let url = ExportPaths.urlForLANWritableMedia(relativePath: Self.relativePath) else { return }
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(items)
            try data.write(to: url, options: .atomic)
        } catch {
            SearchDebugLog.log("PendingExportQueue persist failed: \(error.localizedDescription)")
        }
    }

    private func loadFromDisk() {
        guard let url = ExportPaths.urlForLANWritableMedia(relativePath: Self.relativePath),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([PendingExportItem].self, from: data) else {
            items = []
            return
        }
        items = Array(decoded.prefix(Self.maxItems))
    }
}
