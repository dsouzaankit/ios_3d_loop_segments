import Foundation

struct LANExportTrigger: Codable {
    enum Command: String, Codable {
        case startExport = "start_export"
        case startExportRandom = "start_export_random"
        case resumeExport = "resume_export"
        case pauseExport = "pause_export"
        case stopExport = "stop_export"
    }

    enum RandomPool: String, Codable {
        case sameFolder = "same_folder"
        case bookmarks
    }

    var version: Int?
    var command: Command
    var href: String?
    var displayName: String?
    var seekMs: Int64?
    /// Idempotency token — same `id` is not processed twice.
    var id: String?
    var pool: RandomPool?
    /// pCloud folder listing path for `start_export_random` (same_folder pool).
    var folderPath: String?
}

struct LANExportTriggerAck: Codable {
    var receivedAt: String
    var command: String
    var status: String
    var message: String
    var triggerId: String?
}

enum LANExportTriggerControl {
    static let triggerRelativePath = "\(ExportPaths.mediaExportFolderName)/scripts/export_trigger.json"
    static let ackRelativePath = "\(ExportPaths.mediaExportFolderName)/scripts/export_trigger.ack.json"
    private static let enabledKey = "lanExportTriggerEnabled"
    private static let lastHandledIdKey = "lanExportTriggerLastHandledId"

    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var triggerURL: URL? {
        ExportPaths.urlForLANWritableMedia(relativePath: triggerRelativePath)
    }

    static var ackURL: URL? {
        ExportPaths.urlForLANWritableMedia(relativePath: ackRelativePath)
    }

    static func readAckSummary() -> String? {
        guard let url = ackURL,
              let data = try? Data(contentsOf: url),
              let ack = try? JSONDecoder().decode(LANExportTriggerAck.self, from: data) else {
            return nil
        }
        return "\(ack.status): \(ack.message)"
    }

    @MainActor
    static func pollAndConsume(
        credentials: WebDAVCredentials?,
        currentItem: WebDAVItem,
        isExportRunning: Bool,
        prepareForFreshStart: @escaping () async -> Void,
        onStartExport: @escaping (WebDAVItem, Int64) -> Void,
        onPause: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) async -> String? {
        guard isEnabled else { return nil }
        guard ExportAutoLockCoordinator.appIsActive else { return nil }
        guard let url = triggerURL, FileManager.default.fileExists(atPath: url.path) else { return nil }

        guard let data = try? Data(contentsOf: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }

        let trigger: LANExportTrigger
        do {
            trigger = try JSONDecoder().decode(LANExportTrigger.self, from: data)
        } catch {
            writeAck(command: "parse_error", status: "rejected", message: error.localizedDescription, triggerId: nil)
            return "Trigger rejected — invalid JSON"
        }

        if let triggerId = trigger.id?.trimmingCharacters(in: .whitespacesAndNewlines), !triggerId.isEmpty {
            let last = UserDefaults.standard.string(forKey: lastHandledIdKey)
            if last == triggerId {
                writeAck(
                    command: trigger.command.rawValue,
                    status: "ignored",
                    message: "Duplicate trigger id",
                    triggerId: triggerId
                )
                return "Ignored duplicate trigger"
            }
            UserDefaults.standard.set(triggerId, forKey: lastHandledIdKey)
        }

        switch trigger.command {
        case .startExport:
            guard let item = webDAVItem(from: trigger) else {
                writeAck(
                    command: trigger.command.rawValue,
                    status: "rejected",
                    message: "start_export requires href and displayName",
                    triggerId: trigger.id
                )
                return "Trigger rejected — missing href/name"
            }
            if isExportRunning {
                onStop()
            }
            await prepareForFreshStart()
            let seek = max(0, trigger.seekMs ?? 0)
            writeAck(
                command: trigger.command.rawValue,
                status: "accepted",
                message: "Starting \(item.name) at \(ResumeTimeFormat.formatMs(seek))",
                triggerId: trigger.id
            )
            onStartExport(item, seek)
            return "LAN trigger — export \(item.name)"

        case .startExportRandom:
            guard let credentials else {
                writeAck(
                    command: trigger.command.rawValue,
                    status: "rejected",
                    message: "Not signed in to pCloud",
                    triggerId: trigger.id
                )
                return "Not signed in"
            }
            if isExportRunning {
                onStop()
            }
            await prepareForFreshStart()
            let pool = mapPool(trigger.pool)
            do {
                let picked: WebDAVItem
                if let folderRaw = trigger.folderPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !folderRaw.isEmpty {
                    let folder = WebDAVURLBuilder.directoryListingPath(folderRaw)
                    picked = try await AlternateExportFilePicker.pickRandom(
                        excluding: nil,
                        folderPath: folder,
                        credentials: credentials
                    )
                } else if pool == .sameFolder, currentItem.isDirectory {
                    let folder = WebDAVURLBuilder.directoryListingPath(currentItem.href)
                    picked = try await AlternateExportFilePicker.pickRandom(
                        excluding: nil,
                        folderPath: folder,
                        credentials: credentials
                    )
                } else {
                    picked = try await AlternateExportFilePicker.pickRandom(
                        excluding: currentItem.isDirectory ? nil : currentItem.fileKey,
                        source: pool,
                        currentItem: currentItem,
                        credentials: credentials
                    )
                }
                writeAck(
                    command: trigger.command.rawValue,
                    status: "accepted",
                    message: "Starting random: \(picked.name)",
                    triggerId: trigger.id
                )
                onStartExport(picked, max(0, trigger.seekMs ?? 0))
                return "LAN trigger — random \(picked.name)"
            } catch {
                writeAck(
                    command: trigger.command.rawValue,
                    status: "rejected",
                    message: error.localizedDescription,
                    triggerId: trigger.id
                )
                return error.localizedDescription
            }

        case .resumeExport:
            if isExportRunning {
                writeAck(
                    command: trigger.command.rawValue,
                    status: "rejected",
                    message: "Export already running",
                    triggerId: trigger.id
                )
                return "Export already running"
            }
            guard let entry = ResumeStore.mostRecentPausedExport() else {
                writeAck(
                    command: trigger.command.rawValue,
                    status: "rejected",
                    message: "No paused export",
                    triggerId: trigger.id
                )
                return "No paused export"
            }
            guard let item = webDAVItem(from: entry) else {
                writeAck(
                    command: trigger.command.rawValue,
                    status: "rejected",
                    message: "Paused export missing href",
                    triggerId: trigger.id
                )
                return "Paused export missing href"
            }
            var seekMs = max(entry.lastSeekMs, entry.checkpointMediaMs ?? 0)
            if let cap = entry.sourceDurationMs, cap > 500 {
                seekMs = min(seekMs, max(0, cap - 250))
            }
            writeAck(
                command: trigger.command.rawValue,
                status: "accepted",
                message: "Resuming \(item.name) at \(ResumeTimeFormat.formatMs(seekMs))",
                triggerId: trigger.id
            )
            onStartExport(item, seekMs)
            return "LAN trigger — resume \(item.name)"

        case .pauseExport:
            guard isExportRunning else {
                writeAck(
                    command: trigger.command.rawValue,
                    status: "rejected",
                    message: "No export running",
                    triggerId: trigger.id
                )
                return "Nothing to pause"
            }
            writeAck(
                command: trigger.command.rawValue,
                status: "accepted",
                message: "Pause requested",
                triggerId: trigger.id
            )
            onPause()
            return "LAN trigger — paused"

        case .stopExport:
            let hasPausedExport = ResumeStore.mostRecentPausedExport() != nil
            guard isExportRunning || hasPausedExport else {
                writeAck(
                    command: trigger.command.rawValue,
                    status: "rejected",
                    message: "No export running",
                    triggerId: trigger.id
                )
                return "Nothing to stop"
            }
            writeAck(
                command: trigger.command.rawValue,
                status: "accepted",
                message: "Stop requested",
                triggerId: trigger.id
            )
            onStop()
            return "LAN trigger — stopped"
        }
    }

    private static func mapPool(_ pool: LANExportTrigger.RandomPool?) -> AlternateExportFileSource {
        switch pool {
        case .bookmarks: return .bookmarks
        case .sameFolder, .none: return .sameFolder
        }
    }

    private static func webDAVItem(from trigger: LANExportTrigger) -> WebDAVItem? {
        guard let href = trigger.href?.trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty else {
            return nil
        }
        let name = trigger.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String
        if let name, !name.isEmpty {
            resolvedName = name
        } else {
            resolvedName = WebDAVURLBuilder.displayName(fromHref: href)
        }
        guard !resolvedName.isEmpty else { return nil }
        return WebDAVItem(href: href, name: resolvedName, isDirectory: false, contentLength: nil)
    }

    private static func webDAVItem(from entry: ResumeEntry) -> WebDAVItem? {
        guard let href = entry.href?.trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty else {
            return nil
        }
        let name = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return WebDAVItem(href: href, name: name, isDirectory: false, contentLength: nil)
    }

    private static func writeAck(command: String, status: String, message: String, triggerId: String?) {
        guard let url = ackURL else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ack = LANExportTriggerAck(
            receivedAt: ISO8601DateFormatter().string(from: Date()),
            command: command,
            status: status,
            message: message,
            triggerId: triggerId
        )
        guard let data = try? JSONEncoder().encode(ack) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
