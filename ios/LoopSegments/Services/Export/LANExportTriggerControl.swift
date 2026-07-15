import Foundation

struct LANExportTrigger: Codable {
    enum Command: String, Codable {
        case startExport = "start_export"
        case startExportRandom = "start_export_random"
        case resumeExport = "resume_export"
        case pauseExport = "pause_export"
        case stopExport = "stop_export"
        case clearMedia = "clear_media"
        case trimMedia = "trim_media"
        case downloadURL = "download_url"
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
    /// HTTP(S) URL for `download_url`.
    var url: String?
    /// Display name / basename for the export (same as browse Export display name).
    var saveName: String?
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

    /// Writes `export_trigger.json` for LAN REST / scripts (polled ~2s while app is active).
    @discardableResult
    static func queueTrigger(_ trigger: LANExportTrigger) -> Bool {
        guard let url = triggerURL else { return false }
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(trigger)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// REST helper: queue `download_url` (same as browse **Export from URL**).
    static func queueDownloadURLExport(
        urlString: String,
        saveName: String?,
        triggerId: String?
    ) -> (httpStatus: Int, payload: [String: Any]) {
        let rawURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let remoteURL = URL(string: rawURL),
              let scheme = remoteURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return (
                400,
                [
                    "status": "rejected",
                    "command": LANExportTrigger.Command.downloadURL.rawValue,
                    "message": "url must be a valid http(s) URL",
                ]
            )
        }
        let requestedName = saveName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = remoteURL.lastPathComponent.isEmpty ? "download" : remoteURL.lastPathComponent
        guard let name = URLMediaDownload.sanitizeSaveFileName(
            requestedName.isEmpty ? fallback : requestedName,
            sourceURL: remoteURL
        ) else {
            return (
                400,
                [
                    "status": "rejected",
                    "command": LANExportTrigger.Command.downloadURL.rawValue,
                    "message": "saveName is invalid",
                ]
            )
        }
        let trimmedId = triggerId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = trimmedId.isEmpty ? UUID().uuidString : trimmedId
        let trigger = LANExportTrigger(
            version: 1,
            command: .downloadURL,
            href: nil,
            displayName: nil,
            seekMs: nil,
            id: id,
            pool: nil,
            folderPath: nil,
            url: remoteURL.absoluteString,
            saveName: name
        )
        guard queueTrigger(trigger) else {
            return (
                500,
                [
                    "status": "error",
                    "command": LANExportTrigger.Command.downloadURL.rawValue,
                    "message": "Could not write export_trigger.json",
                    "triggerId": id,
                ]
            )
        }
        return (
            202,
            [
                "status": "queued",
                "command": LANExportTrigger.Command.downloadURL.rawValue,
                "message": "Export from URL queued — keep Loop Segments open (foreground, exporting, or Keep Alive)",
                "triggerId": id,
                "url": remoteURL.absoluteString,
                "saveName": name,
                "ack": "/\(ackRelativePath)",
            ]
        )
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
        isExportCoordinatorBusy: Bool,
        prepareForFreshStart: @escaping () async -> Void,
        onStartExport: @escaping (WebDAVItem, Int64) -> Void,
        onPause: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onClearMedia: @escaping () -> Int,
        onTrimMedia: @escaping () -> Int
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
            if let paused = ResumeStore.mostRecentPausedExport(),
               paused.fileKey == item.fileKey,
               let pausedItem = webDAVItem(from: paused) {
                var seekMs = max(paused.lastSeekMs, paused.checkpointMediaMs ?? 0)
                if let cap = paused.sourceDurationMs, cap > 500 {
                    seekMs = min(seekMs, max(0, cap - 250))
                }
                writeAck(
                    command: trigger.command.rawValue,
                    status: "accepted",
                    message: "Resuming paused \(pausedItem.name) at \(ResumeTimeFormat.formatMs(seekMs))",
                    triggerId: trigger.id
                )
                onStartExport(pausedItem, seekMs)
                return "LAN trigger — resume paused \(pausedItem.name)"
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
            guard isExportRunning || hasPausedExport || ExportMediaArchive.hasActiveExportMediaOnDisk() else {
                writeAck(
                    command: trigger.command.rawValue,
                    status: "rejected",
                    message: "No export to stop",
                    triggerId: trigger.id
                )
                return "Nothing to stop"
            }
            writeAck(
                command: trigger.command.rawValue,
                status: "accepted",
                message: "Stop requested — loop/ removed, working copies archived",
                triggerId: trigger.id
            )
            onStop()
            return "LAN trigger — stopped"

        case .clearMedia:
            guard !isExportRunning, !isExportCoordinatorBusy else {
                writeAck(
                    command: trigger.command.rawValue,
                    status: "rejected",
                    message: "Export running — stop first",
                    triggerId: trigger.id
                )
                return "Clear media rejected — export running"
            }
            let cleared = onClearMedia()
            writeAck(
                command: trigger.command.rawValue,
                status: "accepted",
                message: cleared > 0
                    ? "Cleared \(cleared) media file(s) (active + archive/ + downloads/)"
                    : "No media files to clear",
                triggerId: trigger.id
            )
            return cleared > 0 ? "LAN trigger — cleared \(cleared) file(s)" : "LAN trigger — no media to clear"

        case .trimMedia:
            guard !isExportRunning, !isExportCoordinatorBusy else {
                writeAck(
                    command: trigger.command.rawValue,
                    status: "rejected",
                    message: "Export running — stop first",
                    triggerId: trigger.id
                )
                return "Trim media rejected — export running"
            }
            let trimmed = onTrimMedia()
            writeAck(
                command: trigger.command.rawValue,
                status: "accepted",
                message: trimmed > 0
                    ? "Trimmed archive/ — removed \(trimmed) file(s) (kept last \(ExportMediaArchive.manualKeepCount) batches)"
                    : "Nothing to trim (at or below \(ExportMediaArchive.manualKeepCount) batches)",
                triggerId: trigger.id
            )
            return trimmed > 0 ? "LAN trigger — trimmed \(trimmed) file(s)" : "LAN trigger — nothing to trim"

        case .downloadURL:
            let rawURL = trigger.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let remoteURL = URL(string: rawURL),
                  let scheme = remoteURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                writeAck(
                    command: trigger.command.rawValue,
                    status: "rejected",
                    message: "download_url requires a valid http(s) url",
                    triggerId: trigger.id
                )
                return "Trigger rejected — invalid url"
            }
            let requestedName = trigger.saveName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let saveName = URLMediaDownload.sanitizeSaveFileName(
                requestedName.isEmpty ? (remoteURL.lastPathComponent.isEmpty ? "download" : remoteURL.lastPathComponent) : requestedName,
                sourceURL: remoteURL
            ) else {
                writeAck(
                    command: trigger.command.rawValue,
                    status: "rejected",
                    message: "download_url requires a valid saveName",
                    triggerId: trigger.id
                )
                return "Trigger rejected — invalid saveName"
            }
            if isExportRunning {
                onStop()
            }
            await prepareForFreshStart()
            let item = WebDAVItem(
                href: remoteURL.absoluteString,
                name: saveName,
                isDirectory: false,
                contentLength: nil
            )
            writeAck(
                command: trigger.command.rawValue,
                status: "accepted",
                message: "Starting export \(saveName) from URL (vanilla → segments)",
                triggerId: trigger.id
            )
            onStartExport(item, 0)
            return "LAN trigger — URL export \(saveName)"
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
