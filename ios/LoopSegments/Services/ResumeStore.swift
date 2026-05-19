import Foundation

struct ResumeEntry: Codable {
    var fileKey: String
    var displayName: String
    var lastSeekMs: Int64
    var updatedAt: Date
    /// True while export was interrupted or app left mid-run (cleared on successful finish or Stop).
    var exportInProgress: Bool = false
    /// Latest media position during an in-progress or interrupted export.
    var checkpointMediaMs: Int64?
}

final class ResumeStore {
    static let shared = ResumeStore()
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

    private func upsert(item: WebDAVItem, mutate: (inout ResumeEntry) -> Void) {
        var entries = load()
        var entry: ResumeEntry
        if let index = entries.firstIndex(where: { $0.fileKey == item.fileKey }) {
            entry = entries[index]
        } else {
            entry = ResumeEntry(
                fileKey: item.fileKey,
                displayName: item.name,
                lastSeekMs: 0,
                updatedAt: Date()
            )
        }
        entry.displayName = item.name
        mutate(&entry)
        if let index = entries.firstIndex(where: { $0.fileKey == item.fileKey }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
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
