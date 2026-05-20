import Combine
import Foundation

struct ResumeEntry: Codable, Identifiable, Hashable {
    var fileKey: String
    var displayName: String
    var href: String?
    var lastSeekMs: Int64
    /// Source duration from last export probe (ms); caps mistaken end-of-file resume points.
    var sourceDurationMs: Int64?
    var updatedAt: Date
    /// True while export was interrupted or app left mid-run (cleared on successful finish or Stop).
    var exportInProgress: Bool = false
    /// Latest media position during an in-progress or interrupted export.
    var checkpointMediaMs: Int64?

    var id: String { fileKey }
}

struct ResumeStatus {
    let savedSeekMs: Int64
    let checkpointMs: Int64?
    let isPaused: Bool
    let updatedAt: Date?
    let sourceDurationMs: Int64?

    var effectiveMs: Int64 {
        let checkpoint = checkpointMs ?? 0
        var ms = max(savedSeekMs, checkpoint)
        if let cap = sourceDurationMs, cap > 500 {
            ms = min(ms, max(0, cap - 250))
        }
        return ms
    }

    var hasResumePoint: Bool {
        isPaused || effectiveMs > 0
    }
}

enum ResumeTimeFormat {
    static func formatMs(_ ms: Int64) -> String {
        ExportTimelineLog.wallClock(seconds: Double(max(0, ms)) / 1000.0)
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

@MainActor
final class ResumeStore: ObservableObject {
    static let shared = ResumeStore()
    @Published private(set) var revision = 0

    fileprivate static let entriesKey = "resume_entries"
    private let defaults = UserDefaults.standard

    func seekMs(for item: WebDAVItem) -> Int64 {
        let entries = load()
        return entries.first { $0.fileKey == item.fileKey }?.lastSeekMs ?? 0
    }

    func saveSeekMs(_ ms: Int64, for item: WebDAVItem) {
        upsert(item: item) { entry in
            entry.lastSeekMs = max(0, ms)
            entry.updatedAt = Date()
        }
    }

    func beginExport(for item: WebDAVItem, seekMs: Int64, sourceDurationMs: Int64? = nil) {
        clearPausedExports(exceptFileKey: item.fileKey)
        upsert(item: item) { entry in
            entry.exportInProgress = true
            entry.checkpointMediaMs = max(0, seekMs)
            if let sourceDurationMs, sourceDurationMs > 0 {
                entry.sourceDurationMs = sourceDurationMs
            }
            entry.updatedAt = Date()
        }
    }

    /// Only one export runs at a time; starting another file should not leave stale rows in Paused exports.
    func clearPausedExports(exceptFileKey: String? = nil) {
        var entries = load()
        var changed = false
        for index in entries.indices where entries[index].exportInProgress {
            if let exceptFileKey, entries[index].fileKey == exceptFileKey { continue }
            entries[index].exportInProgress = false
            entries[index].checkpointMediaMs = nil
            entries[index].updatedAt = Date()
            changed = true
        }
        if changed { persist(entries) }
    }

    /// `_working.sparse.json` is for one source file — other paused rows are stale.
    func reconcilePausedWithWorkingSource() {
        guard let manifest = WorkingSourceSparseCatalog.readManifest() else { return }
        var entries = load()
        var changed = false
        for index in entries.indices where entries[index].exportInProgress {
            if entries[index].fileKey == manifest.fileKey { continue }
            entries[index].exportInProgress = false
            entries[index].checkpointMediaMs = nil
            entries[index].updatedAt = Date()
            changed = true
        }
        if changed { persist(entries) }
    }

    func dismissPausedExport(_ entry: ResumeEntry) {
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.fileKey == entry.fileKey }) else { return }
        guard entries[index].exportInProgress else { return }
        entries[index].exportInProgress = false
        entries[index].checkpointMediaMs = nil
        entries[index].updatedAt = Date()
        persist(entries)
    }

    func setSourceDurationMs(_ ms: Int64, for item: WebDAVItem) {
        guard ms > 0 else { return }
        upsert(item: item) { entry in
            entry.sourceDurationMs = ms
        }
    }

    func saveCheckpoint(mediaMs: Int64, for item: WebDAVItem) {
        upsert(item: item) { entry in
            entry.exportInProgress = true
            var ms = max(0, mediaMs)
            if let cap = entry.sourceDurationMs, cap > 500 {
                ms = min(ms, max(0, cap - 250))
            }
            entry.checkpointMediaMs = ms
            entry.updatedAt = Date()
        }
    }

    func finishExport(for item: WebDAVItem) {
        upsert(item: item) { entry in
            entry.exportInProgress = false
            entry.checkpointMediaMs = nil
            entry.updatedAt = Date()
        }
    }

    func exportWasInterrupted(for item: WebDAVItem) -> Bool {
        load().first { $0.fileKey == item.fileKey }?.exportInProgress == true
    }

    func checkpointMediaMs(for item: WebDAVItem) -> Int64? {
        load().first { $0.fileKey == item.fileKey }?.checkpointMediaMs
    }

    func resumeStatus(for item: WebDAVItem) -> ResumeStatus {
        guard let entry = load().first(where: { $0.fileKey == item.fileKey }) else {
            return ResumeStatus(
                savedSeekMs: 0,
                checkpointMs: nil,
                isPaused: false,
                updatedAt: nil,
                sourceDurationMs: nil
            )
        }
        return ResumeStatus(
            savedSeekMs: entry.lastSeekMs,
            checkpointMs: entry.checkpointMediaMs,
            isPaused: entry.exportInProgress,
            updatedAt: entry.updatedAt,
            sourceDurationMs: entry.sourceDurationMs
        )
    }

    func interruptedEntries() -> [ResumeEntry] {
        load()
            .filter(\.exportInProgress)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func clearResume(for item: WebDAVItem) {
        var entries = load()
        entries.removeAll { $0.fileKey == item.fileKey }
        persist(entries)
    }

    func webDAVItem(for entry: ResumeEntry) -> WebDAVItem? {
        guard let href = entry.href, !href.isEmpty else { return nil }
        return WebDAVItem(href: href, name: entry.displayName, isDirectory: false, contentLength: nil)
    }

    /// Prefer stored href; otherwise match the current browser listing by `fileKey`.
    func resolveItem(for entry: ResumeEntry, browsing: [WebDAVItem]) -> WebDAVItem? {
        if let item = webDAVItem(for: entry) { return item }
        if let item = browsing.first(where: { $0.fileKey == entry.fileKey && $0.isVideo }) {
            return item
        }
        let paused = load().filter(\.exportInProgress)
        if let href = WorkingSourceSparseCatalog.hrefForResumeEntry(
            entry,
            singlePausedExport: paused.count == 1
        ) {
            let item = WebDAVItem(
                href: href,
                name: entry.displayName,
                isDirectory: false,
                contentLength: nil
            )
            backfillHrefIfNeeded(entry: entry, item: item)
            return item
        }
        return nil
    }

    /// Restore `href` on paused rows from `_working.sparse.json` (older pauses often lack href).
    func backfillHrefsFromSparseManifest() {
        guard let manifest = WorkingSourceSparseCatalog.readManifest() else { return }
        let href = manifest.href?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !href.isEmpty else { return }

        var entries = load()
        var changed = false
        for index in entries.indices where entries[index].exportInProgress {
            guard entries[index].fileKey == manifest.fileKey else { continue }

            let item = WebDAVItem(
                href: href,
                name: entries[index].displayName,
                isDirectory: false,
                contentLength: nil
            )
            if entries[index].href != href {
                entries[index].href = href
                changed = true
            }
            if entries[index].fileKey != item.fileKey {
                entries[index].fileKey = item.fileKey
                changed = true
            }
        }
        if changed { persist(entries) }
    }

    private func backfillHrefIfNeeded(entry: ResumeEntry, item: WebDAVItem) {
        guard entry.href != item.href || entry.fileKey != item.fileKey else { return }
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.fileKey == entry.fileKey || $0.id == entry.id }) else {
            return
        }
        entries[index].href = item.href
        entries[index].fileKey = item.fileKey
        entries[index].displayName = item.name
        persist(entries)
    }

    /// Attach `href` when the paused file is visible in the folder being browsed.
    func backfillHrefs(from browsing: [WebDAVItem]) {
        var entries = load()
        var changed = false
        for item in browsing where item.isVideo {
            guard let index = entries.firstIndex(where: { $0.fileKey == item.fileKey }) else { continue }
            guard entries[index].exportInProgress else { continue }
            if entries[index].href != item.href {
                entries[index].href = item.href
                entries[index].displayName = item.name
                changed = true
            }
        }
        if changed { persist(entries) }
    }

    private func persist(_ entries: [ResumeEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.entriesKey)
        }
        revision += 1
    }

    private func upsert(item: WebDAVItem, mutate: (inout ResumeEntry) -> Void) {
        var entries = load()
        var entry: ResumeEntry
        if let index = entries.firstIndex(where: { $0.fileKey == item.fileKey }) {
            entry = entries[index]
        } else {
            entry = ResumeEntry(
                fileKey: item.fileKey,
                displayName: item.name,
                href: item.href,
                lastSeekMs: 0,
                updatedAt: Date()
            )
        }
        entry.displayName = item.name
        entry.href = item.href
        mutate(&entry)
        if let index = entries.firstIndex(where: { $0.fileKey == item.fileKey }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        persist(entries)
    }

    private func load() -> [ResumeEntry] {
        guard let data = defaults.data(forKey: Self.entriesKey),
              let entries = try? JSONDecoder().decode([ResumeEntry].self, from: data) else {
            return []
        }
        return entries
    }
}

extension ResumeStore {
    /// LAN / sparse manifest hints (safe off main actor — reads UserDefaults only).
    struct LANPlaybackHints: Sendable {
        let fileKey: String
        let href: String?
        let playbackStartSeconds: Double
        let exportCursorSeconds: Double
        let durationSeconds: Double
    }

    nonisolated static func lanPlaybackHints(fileKey: String?, href: String?) -> LANPlaybackHints? {
        guard let data = UserDefaults.standard.data(forKey: ResumeStore.entriesKey),
              let entries = try? JSONDecoder().decode([ResumeEntry].self, from: data),
              !entries.isEmpty else {
            return nil
        }

        let entry: ResumeEntry?
        if let fileKey, !fileKey.isEmpty,
           let match = entries.first(where: { $0.fileKey == fileKey }) {
            entry = match
        } else if let href, !href.isEmpty,
                  let match = entries.first(where: { $0.href == href }) {
            entry = match
        } else {
            let paused = entries.filter(\.exportInProgress)
            if paused.count == 1 {
                entry = paused[0]
            } else {
                entry = paused.max(by: { $0.updatedAt < $1.updatedAt })
            }
        }
        guard let entry else { return nil }

        let savedMs = entry.lastSeekMs
        let checkpointMs = entry.checkpointMediaMs ?? 0
        var effectiveMs = max(savedMs, checkpointMs)
        if let cap = entry.sourceDurationMs, cap > 500 {
            effectiveMs = min(effectiveMs, max(0, cap - 250))
        }
        let durationSeconds: Double
        if let cap = entry.sourceDurationMs, cap > 0 {
            durationSeconds = Double(cap) / 1000.0
        } else {
            durationSeconds = 0
        }
        let playbackStartSeconds = Double(effectiveMs) / 1000.0
        let exportCursorSeconds = Double(max(effectiveMs, checkpointMs)) / 1000.0
        return LANPlaybackHints(
            fileKey: entry.fileKey,
            href: entry.href,
            playbackStartSeconds: playbackStartSeconds,
            exportCursorSeconds: exportCursorSeconds,
            durationSeconds: durationSeconds
        )
    }

}

enum SeekPreset: Int, CaseIterable, Identifiable {
    case zero = 0
    case ten = 1
    case fifteen = 2
    case thirty = 3
    case fortyFive = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .zero: return "0 min"
        case .ten: return "10 min"
        case .fifteen: return "15 min"
        case .thirty: return "30 min"
        case .fortyFive: return "45 min"
        }
    }

    var seekMs: Int64 {
        switch self {
        case .zero: return 0
        case .ten: return 10 * 60 * 1000
        case .fifteen: return 15 * 60 * 1000
        case .thirty: return 30 * 60 * 1000
        case .fortyFive: return 45 * 60 * 1000
        }
    }
}
