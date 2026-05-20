import Combine
import Foundation

struct ResumeEntry: Codable, Identifiable {
    var fileKey: String
    var displayName: String
    var href: String?
    var lastSeekMs: Int64
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

    var effectiveMs: Int64 {
        let checkpoint = checkpointMs ?? 0
        return max(savedSeekMs, checkpoint)
    }

    var hasResumePoint: Bool {
        isPaused || effectiveMs > 0
    }
}

enum ResumeTimeFormat {
    static func formatMs(_ ms: Int64) -> String {
        let totalSec = max(0, ms / 1000)
        let min = totalSec / 60
        let sec = totalSec % 60
        return String(format: "%d:%02d", min, sec)
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

    private let key = "resume_entries"
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

    func beginExport(for item: WebDAVItem, seekMs: Int64) {
        upsert(item: item) { entry in
            entry.exportInProgress = true
            entry.checkpointMediaMs = max(0, seekMs)
            entry.updatedAt = Date()
        }
    }

    func saveCheckpoint(mediaMs: Int64, for item: WebDAVItem) {
        upsert(item: item) { entry in
            entry.exportInProgress = true
            entry.checkpointMediaMs = max(0, mediaMs)
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
            return ResumeStatus(savedSeekMs: 0, checkpointMs: nil, isPaused: false, updatedAt: nil)
        }
        return ResumeStatus(
            savedSeekMs: entry.lastSeekMs,
            checkpointMs: entry.checkpointMediaMs,
            isPaused: entry.exportInProgress,
            updatedAt: entry.updatedAt
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

    private func persist(_ entries: [ResumeEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
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
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([ResumeEntry].self, from: data) else {
            return []
        }
        return entries
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
