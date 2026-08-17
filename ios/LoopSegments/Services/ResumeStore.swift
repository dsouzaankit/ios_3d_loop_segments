import Combine
import Foundation

struct ResumeEntry: Codable, Identifiable, Hashable {
    var fileKey: String
    var displayName: String
    var href: String?
    /// Parent WebDAV folder (listing path) — one-level PROPFIND on resume before a full walk.
    var folderPath: String? = nil
    var lastSeekMs: Int64
    /// Source duration from last export probe (ms); caps mistaken end-of-file resume points.
    var sourceDurationMs: Int64?
    var updatedAt: Date
    /// True while export was interrupted or app left mid-run (cleared on successful finish or Stop).
    var exportInProgress: Bool = false
    /// Latest media position during an in-progress or interrupted export.
    var checkpointMediaMs: Int64?
    /// Shown in Browse after a finished export when `_working.mp4` + segments exist on disk (like a bookmark to reopen Export / LAN).
    var pinnedCompleted: Bool = false
    /// Saved `folderPath` no longer contains this file (moved/renamed on pCloud). Re-queue from the PC companion.
    var sourceUnavailable: Bool? = nil

    var id: String { fileKey }

    var isSourceUnavailable: Bool { sourceUnavailable == true }

    /// Prefer stored name; fall back to href leaf so Paused never shows a blank row.
    var resolvedDisplayName: String {
        ResumeDisplayName.resolve(itemName: displayName, href: href)
    }

    /// Enough identity to open Export (name and/or href).
    var hasResumableIdentity: Bool {
        !resolvedDisplayName.isEmpty
            || !(href?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

enum ResumeDisplayName {
    static func resolve(itemName: String, href: String?) -> String {
        let trimmed = itemName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let href, !href.isEmpty {
            let fromHref = WebDAVURLBuilder.displayName(fromHref: href)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !fromHref.isEmpty { return fromHref }
        }
        return ""
    }
}

struct ResumeStatus {
    let savedSeekMs: Int64
    let checkpointMs: Int64?
    let isPaused: Bool
    let updatedAt: Date?
    let sourceDurationMs: Int64?

    var effectiveMs: Int64 {
        ResumeSeek.effectiveMs(
            lastSeekMs: savedSeekMs,
            checkpointMediaMs: checkpointMs,
            sourceDurationMs: sourceDurationMs
        )
    }

    var hasResumePoint: Bool {
        isPaused || effectiveMs > 0
    }
}

/// Shared clamp for resume/checkpoint seeks (LAN button + Paused tab + save path).
enum ResumeSeek {
    /// Longer than this is almost always corrupt (e.g. file bytes written as media ms).
    static let maxPlausibleMs: Int64 = 3 * 60 * 60 * 1000

    static func effectiveMs(
        lastSeekMs: Int64,
        checkpointMediaMs: Int64?,
        sourceDurationMs: Int64?
    ) -> Int64 {
        clampMs(max(0, max(lastSeekMs, checkpointMediaMs ?? 0)), sourceDurationMs: sourceDurationMs)
    }

    static func clampMs(_ rawMs: Int64, sourceDurationMs: Int64?) -> Int64 {
        var ms = max(0, rawMs)
        let trustedDuration: Int64? = {
            guard let cap = sourceDurationMs, cap > 500, cap <= maxPlausibleMs else { return nil }
            return cap
        }()
        if let cap = trustedDuration {
            ms = min(ms, max(0, cap - 250))
        } else if ms > maxPlausibleMs {
            // No trusted duration — drop absurd seeks (often file bytes stored as media ms).
            ms = 0
        }
        return ms
    }
}

extension ResumeEntry {
    /// Seek used for Paused UI + LAN Resume (duration-capped, sanity-clamped).
    var effectiveResumeSeekMs: Int64 {
        ResumeSeek.effectiveMs(
            lastSeekMs: lastSeekMs,
            checkpointMediaMs: checkpointMediaMs,
            sourceDurationMs: sourceDurationMs
        )
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
    /// Max `exportInProgress` rows retained (includes the live exporting file). Oldest cleared when exceeded.
    /// While a run is active the Paused tab hides that file, so the list typically shows at most `maxPausedExports - 1`.
    static let maxPausedExports = 10
    @Published private(set) var revision = 0

    fileprivate static let entriesKey = "resume_entries"
    private let defaults = UserDefaults.standard
    private var entriesCache: [ResumeEntry]?

    /// In-memory snapshot (one UserDefaults decode per revision).
    func snapshotEntries() -> [ResumeEntry] {
        load()
    }

    func seekMs(for item: WebDAVItem) -> Int64 {
        let entries = load()
        return entries.first { $0.fileKey == item.fileKey }?.lastSeekMs ?? 0
    }

    func saveSeekMs(_ ms: Int64, for item: WebDAVItem) {
        upsert(item: item) { entry in
            entry.lastSeekMs = ResumeSeek.clampMs(ms, sourceDurationMs: entry.sourceDurationMs)
            entry.updatedAt = Date()
        }
    }

    func beginExport(for item: WebDAVItem, seekMs: Int64, sourceDurationMs: Int64? = nil) {
        // Keep other paused rows — handoff from a running export must stay resumable.
        clearPinnedCompletedExports()
        upsert(item: item) { entry in
            entry.exportInProgress = true
            let cappedSeek = ResumeSeek.clampMs(seekMs, sourceDurationMs: sourceDurationMs ?? entry.sourceDurationMs)
            entry.lastSeekMs = cappedSeek
            entry.checkpointMediaMs = cappedSeek
            if let sourceDurationMs, sourceDurationMs > 0 {
                entry.sourceDurationMs = min(sourceDurationMs, ResumeSeek.maxPlausibleMs)
            }
            entry.sourceUnavailable = nil
            entry.updatedAt = Date()
        }
    }

    /// Moves every paused row (except an optional live export) onto the pending FIFO as fresh jobs.
    /// Drops checkpoints: clears in-progress flags / seek, removes `parked/` for those keys.
    /// Does not remove Queued items already present — new rows are appended (oldest paused first).
    @discardableResult
    func moveAllPausedExportsToPendingQueue(exceptFileKey: String? = nil) -> Int {
        let paused = interruptedEntries(excludingFileKey: exceptFileKey)
            .filter { !$0.isSourceUnavailable }
        guard !paused.isEmpty else { return 0 }

        // Paused list is newest-first; append oldest-first so FIFO drains chronologically.
        let oldestFirst = Array(paused.reversed())
        let queueItems: [PendingExportItem] = oldestFirst.map { entry in
            PendingExportItem(
                folderPath: entry.folderPath,
                displayName: entry.resolvedDisplayName,
                seekMs: nil
            )
        }
        PendingExportQueue.shared.enqueue(queueItems, mode: .append)
        PendingExportQueue.shared.requestPauseHoldRelease()

        let keys = Set(paused.map(\.fileKey))
        var entries = load()
        var changed = false
        for index in entries.indices where keys.contains(entries[index].fileKey) {
            guard entries[index].exportInProgress else { continue }
            entries[index].exportInProgress = false
            entries[index].checkpointMediaMs = nil
            entries[index].lastSeekMs = 0
            entries[index].updatedAt = Date()
            changed = true
        }
        if changed { persist(entries) }
        for key in keys {
            _ = ExportParkedMedia.removePark(forFileKey: key)
        }

        ExportRuntimeLog.mirror("Moved \(queueItems.count) paused export(s) → Queued (checkpoints dropped)")
        return queueItems.count
    }

    /// Clears paused / in-progress resume rows (e.g. Clear media).
    /// Removes those entries entirely (not just flags) so Paused cannot resume a wiped export.
    /// Optional `exceptFileKey` keeps one in-progress row and only clears flags on the others.
    func clearPausedExports(exceptFileKey: String? = nil) {
        var entries = load()
        var changed = false
        var droppedKeys: [String] = []
        if exceptFileKey == nil {
            droppedKeys = entries.filter(\.exportInProgress).map(\.fileKey)
            let before = entries.count
            entries.removeAll { $0.exportInProgress }
            changed = entries.count != before || !droppedKeys.isEmpty
        } else {
            for index in entries.indices where entries[index].exportInProgress {
                if entries[index].fileKey == exceptFileKey { continue }
                droppedKeys.append(entries[index].fileKey)
                entries[index].exportInProgress = false
                entries[index].checkpointMediaMs = nil
                entries[index].lastSeekMs = 0
                entries[index].updatedAt = Date()
                changed = true
            }
        }
        if changed { persist(entries) }
        for key in droppedKeys {
            _ = ExportParkedMedia.removePark(forFileKey: key)
        }
        if exceptFileKey == nil {
            _ = ExportParkedMedia.removeAll()
        } else if let exceptFileKey {
            var keep = Set(entries.filter(\.exportInProgress).map(\.fileKey))
            keep.insert(exceptFileKey)
            ExportParkedMedia.pruneOrphans(keepingFileKeys: keep)
        }
    }

    /// Href backfill only — do not clear other paused rows (multi-pause handoff keeps them for the Paused tab).
    func reconcilePausedWithWorkingSource() {
        backfillHrefsFromSparseManifest()
    }

    func dismissPausedExport(_ entry: ResumeEntry) {
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.fileKey == entry.fileKey }) else { return }
        guard entries[index].exportInProgress else { return }
        entries[index].exportInProgress = false
        entries[index].checkpointMediaMs = nil
        entries[index].updatedAt = Date()
        persist(entries)
        _ = ExportParkedMedia.removePark(forFileKey: entry.fileKey)
    }

    static let pCloudSourceUnavailableMessage =
        "Redo search and re-export using web companion"

    /// Folder one-level list missed this name — do not resume or FIFO-replay the stale path.
    func markPCloudSourceUnavailable(
        displayName: String,
        href: String? = nil,
        folderPath: String? = nil
    ) {
        SearchLocationCache.removeStaleFile(name: displayName, href: href)
        let needle = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hrefNeedle = href?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var entries = load()
        var changed = false
        for index in entries.indices {
            guard entries[index].exportInProgress else { continue }
            let nameL = entries[index].resolvedDisplayName.lowercased()
            let hrefMatch = !hrefNeedle.isEmpty && entries[index].href == hrefNeedle
            let nameMatch = !needle.isEmpty && (
                nameL == needle
                    || (nameL as NSString).deletingPathExtension == (needle as NSString).deletingPathExtension
            )
            guard hrefMatch || nameMatch else { continue }
            entries[index].sourceUnavailable = true
            entries[index].updatedAt = Date()
            changed = true
        }
        if changed {
            persist(entries)
            SearchDebugLog.log(
                "Paused source unavailable: \"\(displayName)\" folder=\(folderPath ?? "—") — \(Self.pCloudSourceUnavailableMessage)"
            )
            ExportRuntimeLog.mirror("Skipped \(displayName) — \(Self.pCloudSourceUnavailableMessage)")
            return
        }

        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let folder = folderPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = "unavailable:\(folder.lowercased())/\(name.lowercased())"
        if let index = entries.firstIndex(where: { $0.fileKey == key }) {
            entries[index].sourceUnavailable = true
            entries[index].exportInProgress = true
            entries[index].displayName = name
            if !folder.isEmpty { entries[index].folderPath = folder }
            if let href, !href.isEmpty { entries[index].href = href }
            entries[index].updatedAt = Date()
        } else {
            entries.append(
                ResumeEntry(
                    fileKey: key,
                    displayName: name,
                    href: href,
                    folderPath: folder.isEmpty ? nil : folder,
                    lastSeekMs: 0,
                    updatedAt: Date(),
                    exportInProgress: true,
                    sourceUnavailable: true
                )
            )
        }
        persist(entries)
        SearchDebugLog.log(
            "Paused source unavailable (queued skip): \"\(name)\" folder=\(folder.isEmpty ? "—" : folder) — \(Self.pCloudSourceUnavailableMessage)"
        )
        ExportRuntimeLog.mirror("Skipped \(name) — \(Self.pCloudSourceUnavailableMessage)")
    }

    func setSourceDurationMs(_ ms: Int64, for item: WebDAVItem) {
        guard ms > 0 else { return }
        let capped = min(ms, ResumeSeek.maxPlausibleMs)
        upsert(item: item) { entry in
            entry.sourceDurationMs = capped
        }
    }

    func saveCheckpoint(mediaMs: Int64, for item: WebDAVItem) {
        upsert(item: item) { entry in
            entry.exportInProgress = true
            entry.checkpointMediaMs = ResumeSeek.clampMs(mediaMs, sourceDurationMs: entry.sourceDurationMs)
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
        resumeStatus(for: item, in: load())
    }

    func resumeStatus(for item: WebDAVItem, in entries: [ResumeEntry]) -> ResumeStatus {
        guard let entry = entries.first(where: { $0.fileKey == item.fileKey }) else {
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

    func interruptedEntries(excludingFileKey activeFileKey: String? = nil) -> [ResumeEntry] {
        load()
            .filter { entry in
                entry.exportInProgress
                    && entry.fileKey != activeFileKey
                    && entry.hasResumableIdentity
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// At most one completed pin (newest) for Browse.
    func pinnedCompletedEntries() -> [ResumeEntry] {
        pruneExtraCompletedPinsIfNeeded()
        return Array(
            load()
                .filter(\.pinnedCompleted)
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(1)
        )
    }

    /// Pins the item in Browse when an export finishes and export media exists (root, `archive/`, or `loop/`). Clears other pins.
    func pinCompletedExportIfMediaOnDisk(for item: WebDAVItem) {
        guard Self.hasCompletedExportMediaOnDisk() else { return }
        var entries = load()
        for i in entries.indices {
            entries[i].pinnedCompleted = entries[i].fileKey == item.fileKey
            if entries[i].fileKey == item.fileKey {
                entries[i].updatedAt = Date()
            }
        }
        if let index = entries.firstIndex(where: { $0.fileKey == item.fileKey }) {
            entries[index].displayName = item.name
            entries[index].href = item.href
            if let parent = AlternateExportFilePicker.parentFolderPath(for: item) {
                entries[index].folderPath = parent
            }
        } else {
            var entry = ResumeEntry(fileKey: item.fileKey, displayName: item.name, href: item.href, lastSeekMs: 0, updatedAt: Date())
            entry.pinnedCompleted = true
            entry.folderPath = AlternateExportFilePicker.parentFolderPath(for: item)
            entries.append(entry)
        }
        persist(entries)
    }

    private func pruneExtraCompletedPinsIfNeeded() {
        var entries = load()
        let pinned = entries
            .enumerated()
            .filter { $0.element.pinnedCompleted }
            .sorted { $0.element.updatedAt > $1.element.updatedAt }
        guard pinned.count > 1 else { return }
        for pair in pinned.dropFirst() {
            entries[pair.offset].pinnedCompleted = false
        }
        persist(entries)
    }

    private static func hasCompletedExportMediaOnDisk() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: ExportPaths.workingSourceURL.path) { return true }
        if ExportPaths.vanillaDownloadCopyExistsOnDisk() { return true }
        if fm.fileExists(atPath: ExportPaths.workingTranscodedURL.path) { return true }
        if !ExportMediaArchive.collectRetentionStampSuffixes().isEmpty { return true }
        for index in 0 ..< ExportPaths.segmentFileCount {
            if fm.fileExists(atPath: ExportPaths.segmentURL(index: index).path) {
                return true
            }
        }
        return false
    }

    func dismissPinnedCompleted(_ entry: ResumeEntry) {
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.fileKey == entry.fileKey }) else { return }
        guard entries[index].pinnedCompleted else { return }
        entries[index].pinnedCompleted = false
        entries[index].updatedAt = Date()
        persist(entries)
    }

    func clearPinnedCompletedExports() {
        var entries = load()
        var changed = false
        for i in entries.indices where entries[i].pinnedCompleted {
            entries[i].pinnedCompleted = false
            entries[i].updatedAt = Date()
            changed = true
        }
        if changed { persist(entries) }
    }

    func clearResume(for item: WebDAVItem) {
        var entries = load()
        entries.removeAll { $0.fileKey == item.fileKey }
        persist(entries)
    }

    func webDAVItem(for entry: ResumeEntry) -> WebDAVItem? {
        guard let href = entry.href?.trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty else {
            return nil
        }
        let name = entry.resolvedDisplayName
        guard !name.isEmpty else { return nil }
        return WebDAVItem(href: href, name: name, isDirectory: false, contentLength: nil)
    }

    /// Prefer current folder listing (handles rename); then sparse manifest; avoid stale `href` alone.
    func resolveItem(for entry: ResumeEntry, browsing: [WebDAVItem]) -> WebDAVItem? {
        let videos = browsing.filter(\.isVideo)
        if let item = WebDAVRenameReconcile.matchResumeEntry(entry, in: videos) {
            backfillHrefIfNeeded(entry: entry, item: item)
            return item
        }
        let paused = load().filter(\.exportInProgress)
        if let href = WorkingSourceSparseCatalog.hrefForResumeEntry(
            entry,
            singlePausedExport: paused.count == 1
        ) {
            let name = entry.resolvedDisplayName
            guard !name.isEmpty else { return nil }
            let item = WebDAVItem(
                href: href,
                name: name,
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
            if let parent = WebDAVRenameReconcile.parentBrowsePath(forFileHref: href),
               entries[index].folderPath != parent {
                entries[index].folderPath = parent
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
        let parent = AlternateExportFilePicker.parentFolderPath(for: item)
        guard entry.href != item.href
            || entry.fileKey != item.fileKey
            || entry.folderPath != parent else { return }
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.fileKey == entry.fileKey || $0.id == entry.id }) else {
            return
        }
        entries[index].href = item.href
        entries[index].fileKey = item.fileKey
        entries[index].displayName = item.name
        if let parent {
            entries[index].folderPath = parent
        }
        persist(entries)
    }

    /// Update resume rows and export manifests when pCloud renamed/moved a file (`fileKey` changes with `href`).
    func reconcileWithBrowseListing(_ browsing: [WebDAVItem]) {
        let videos = browsing.filter(\.isVideo)
        guard !videos.isEmpty else { return }

        var entries = load()
        var changed = false
        for index in entries.indices {
            guard let match = WebDAVRenameReconcile.matchResumeEntry(entries[index], in: videos) else {
                continue
            }
            if entries[index].fileKey == match.fileKey,
               entries[index].href == match.href,
               entries[index].displayName == match.name,
               entries[index].folderPath == AlternateExportFilePicker.parentFolderPath(for: match) {
                continue
            }
            entries[index].fileKey = match.fileKey
            entries[index].href = match.href
            entries[index].displayName = match.name
            if let parent = AlternateExportFilePicker.parentFolderPath(for: match) {
                entries[index].folderPath = parent
            }
            entries[index].updatedAt = Date()
            changed = true
        }
        if changed { persist(entries) }

        VanillaDownloadResumeCatalog.reconcileManifestIfNeeded(with: videos)
        WorkingSourceSparseCatalog.reconcileManifestIfNeeded(with: videos)
    }

    /// Attach `href` when the paused file is visible in the folder being browsed.
    func backfillHrefs(from browsing: [WebDAVItem]) {
        reconcileWithBrowseListing(browsing)
    }

    /// Persist an explicit listing folder (e.g. REST `folderPath` after a successful one-level resolve).
    func setFolderPath(_ folderPath: String?, for item: WebDAVItem) {
        let trimmed = folderPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        let normalized = WebDAVURLBuilder.directoryListingPath(trimmed)
        upsert(item: item) { entry in
            entry.folderPath = normalized
        }
    }

    private func persist(_ entries: [ResumeEntry]) {
        var trimmed = entries
        trimPausedQueueOverflow(&trimmed)
        invalidateEntriesCache()
        if let data = try? JSONEncoder().encode(trimmed) {
            defaults.set(data, forKey: Self.entriesKey)
        }
        entriesCache = trimmed
        revision += 1
    }

    /// Keep at most `maxPausedExports` in-progress rows; clear oldest first.
    private func trimPausedQueueOverflow(_ entries: inout [ResumeEntry]) {
        let inProgress = entries.indices.filter { entries[$0].exportInProgress }
        guard inProgress.count > Self.maxPausedExports else { return }
        let dropOrder = inProgress.sorted { a, b in
            let aSkip = entries[a].isSourceUnavailable
            let bSkip = entries[b].isSourceUnavailable
            if aSkip != bSkip { return aSkip && !bSkip }
            return entries[a].updatedAt < entries[b].updatedAt
        }
        let drop = dropOrder.prefix(inProgress.count - Self.maxPausedExports)
        for index in drop {
            let key = entries[index].fileKey
            entries[index].exportInProgress = false
            entries[index].checkpointMediaMs = nil
            entries[index].updatedAt = Date()
            _ = ExportParkedMedia.removePark(forFileKey: key)
        }
    }

    private func upsert(item: WebDAVItem, mutate: (inout ResumeEntry) -> Void) {
        var entries = load()
        let resolvedName = ResumeDisplayName.resolve(itemName: item.name, href: item.href)
        var entry: ResumeEntry
        if let index = entries.firstIndex(where: { $0.fileKey == item.fileKey }) {
            entry = entries[index]
        } else {
            entry = ResumeEntry(
                fileKey: item.fileKey,
                displayName: resolvedName,
                href: item.href,
                lastSeekMs: 0,
                updatedAt: Date()
            )
        }
        if !resolvedName.isEmpty {
            entry.displayName = resolvedName
        }
        entry.href = item.href
        if let parent = AlternateExportFilePicker.parentFolderPath(for: item) {
            entry.folderPath = parent
        }
        mutate(&entry)
        if let index = entries.firstIndex(where: { $0.fileKey == item.fileKey }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        persist(entries)
    }

    private func load() -> [ResumeEntry] {
        if let entriesCache {
            return entriesCache
        }
        guard let data = defaults.data(forKey: Self.entriesKey),
              var entries = try? JSONDecoder().decode([ResumeEntry].self, from: data) else {
            entriesCache = []
            return []
        }
        var needsSave = backfillMissingFolderPaths(&entries)
        let pausedBefore = entries.filter(\.exportInProgress).count
        trimPausedQueueOverflow(&entries)
        if entries.filter(\.exportInProgress).count != pausedBefore {
            needsSave = true
        }
        if needsSave, let encoded = try? JSONEncoder().encode(entries) {
            defaults.set(encoded, forKey: Self.entriesKey)
        }
        entriesCache = entries
        return entries
    }

    /// Older pauses only had `href` — derive listing folder once.
    private func backfillMissingFolderPaths(_ entries: inout [ResumeEntry]) -> Bool {
        var changed = false
        for index in entries.indices {
            guard entries[index].folderPath == nil,
                  let href = entries[index].href,
                  let parent = WebDAVRenameReconcile.parentBrowsePath(forFileHref: href) else {
                continue
            }
            entries[index].folderPath = parent
            changed = true
        }
        return changed
    }

    private func invalidateEntriesCache() {
        entriesCache = nil
    }
}

extension ResumeStore {
    nonisolated static func mostRecentPausedExport() -> ResumeEntry? {
        pausedExportsForLAN(excludingFileKey: nil, limit: 1).first
    }

    /// Same queue as the phone Paused tab (exportInProgress + resumable identity).
    nonisolated static func pausedExportsForLAN(
        excludingFileKey activeFileKey: String? = nil,
        limit: Int = 16
    ) -> [ResumeEntry] {
        guard let data = UserDefaults.standard.data(forKey: entriesKey),
              let entries = try? JSONDecoder().decode([ResumeEntry].self, from: data) else {
            return []
        }
        return Array(
            entries
                .filter { entry in
                    entry.exportInProgress
                        && entry.fileKey != activeFileKey
                        && entry.hasResumableIdentity
                }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(max(0, limit))
        )
    }

    nonisolated static func isExportInProgress(forFileKey fileKey: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: ResumeStore.entriesKey),
              let entries = try? JSONDecoder().decode([ResumeEntry].self, from: data) else {
            return false
        }
        return entries.first(where: { $0.fileKey == fileKey })?.exportInProgress == true
    }

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
        let effectiveMs = ResumeSeek.effectiveMs(
            lastSeekMs: savedMs,
            checkpointMediaMs: checkpointMs,
            sourceDurationMs: entry.sourceDurationMs
        )
        let durationSeconds: Double
        if let cap = entry.sourceDurationMs, cap > 0 {
            durationSeconds = Double(min(cap, ResumeSeek.maxPlausibleMs)) / 1000.0
        } else {
            durationSeconds = 0
        }
        let playbackStartSeconds = Double(effectiveMs) / 1000.0
        let exportCursorSeconds = Double(effectiveMs) / 1000.0
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
