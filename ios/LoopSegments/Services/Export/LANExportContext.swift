import Foundation

/// Last pCloud file used as context for LAN-page export / PC random triggers.
enum LANExportContext {
    private static let hrefKey = "lan_export_reference_href"
    private static let nameKey = "lan_export_reference_name"

    static func saveReference(_ item: WebDAVItem) {
        UserDefaults.standard.set(item.href, forKey: hrefKey)
        UserDefaults.standard.set(item.name, forKey: nameKey)
    }

    static func loadReference() -> WebDAVItem? {
        guard let href = UserDefaults.standard.string(forKey: hrefKey),
              !href.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let name = UserDefaults.standard.string(forKey: nameKey),
              !name.isEmpty else {
            return nil
        }
        return WebDAVItem(href: href, name: name, isDirectory: false, contentLength: nil)
    }

    @MainActor
    static func referenceOrActive(from session: AppSession) -> WebDAVItem? {
        if let active = session.activeExportDisplayItem { return active }
        return loadReference()
    }
}

/// Export source filename for the HTTP LAN index (`status.json` + top-of-page line).
enum LANExportSourceDisplay {
    static let runningKey = "lan_export_source_running"
    private static let phaseKey = "lan_export_source_phase"
    private static let activeNameKey = "lan_export_source_active_name"
    private static let lastFinishedNameKey = "lan_export_source_last_finished_name"
    private static let lastFinishedAtKey = "lan_export_source_last_finished_at"

    static func setRunning(_ displayName: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: runningKey)
        defaults.set("running", forKey: phaseKey)
        defaults.set(trimmed, forKey: activeNameKey)
    }

    static func setPaused(_ displayName: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: runningKey)
        defaults.set("paused", forKey: phaseKey)
        defaults.set(trimmed, forKey: activeNameKey)
    }

    static func setFinished(_ displayName: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: runningKey)
        defaults.set("finished", forKey: phaseKey)
        defaults.set(trimmed, forKey: activeNameKey)
        defaults.set(trimmed, forKey: lastFinishedNameKey)
        defaults.set(Date(), forKey: lastFinishedAtKey)
    }

    static func clearActive() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: runningKey)
        if let last = defaults.string(forKey: lastFinishedNameKey), !last.isEmpty {
            defaults.set("finished", forKey: phaseKey)
            defaults.set(last, forKey: activeNameKey)
        } else {
            defaults.set("idle", forKey: phaseKey)
            defaults.removeObject(forKey: activeNameKey)
        }
    }

    static func label(for phase: String) -> String {
        switch phase {
        case "running": return "Exporting"
        case "paused": return "Paused export"
        case "finished": return "Last export"
        default: return "Export source"
        }
    }

    static func resolve() -> (phase: String, displayName: String)? {
        let defaults = UserDefaults.standard
        // Authoritative running flag — set by AppSession.startExport before coordinator work begins.
        if defaults.bool(forKey: runningKey),
           let name = defaults.string(forKey: activeNameKey),
           !name.isEmpty {
            return ("running", name)
        }
        let phase = defaults.string(forKey: phaseKey) ?? "idle"
        if phase == "paused",
           let name = defaults.string(forKey: activeNameKey),
           !name.isEmpty {
            return ("paused", name)
        }
        // exportInProgress without a running export session = user-paused / checkpointed.
        if let paused = ResumeStore.mostRecentPausedExport() {
            return ("paused", paused.displayName)
        }
        if phase == "finished",
           let name = defaults.string(forKey: activeNameKey),
           !name.isEmpty {
            return ("finished", name)
        }
        if let last = defaults.string(forKey: lastFinishedNameKey), !last.isEmpty {
            return ("finished", last)
        }
        if let ref = LANExportContext.loadReference() {
            return ("finished", ref.name)
        }
        return nil
    }

    static func statusPayload() -> [String: Any]? {
        guard let resolved = resolve() else { return nil }
        return [
            "phase": resolved.phase,
            "displayName": resolved.displayName,
            "label": label(for: resolved.phase),
        ]
    }

    static func formattedLine() -> (label: String, name: String)? {
        guard let resolved = resolve() else { return nil }
        return (label(for: resolved.phase), resolved.displayName)
    }
}
