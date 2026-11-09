import Darwin
import Foundation
import Network
import UIKit

/// HTML and JS for the LAN pages (`/`, `/browse`) and the `/xr` loader.
/// The `/xr` player itself lives in `Resources/xr-*.{html,js}`.
extension ExportLANServer {
    static func htmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Media/archive anchor during export: real `href` (copy link, middle-click) + new tab so the LAN page stays open.
    static func lanMediaClickAnchor(relativePath: String, innerHTML: String, extraClass: String = "") -> String {
        let pathAttr = htmlEscape(relativePath)
        let cls = extraClass.isEmpty ? "lan-media-link" : "lan-media-link \(extraClass)"
        return "<a href=\"\(pathAttr)\" class=\"\(cls)\" target=\"_blank\" rel=\"noopener noreferrer\">\(innerHTML)</a>"
    }

    static func lanMediaListUsesClickOnly(relativePath: String) -> Bool {
        ExportPlaybackState.shared.isLANExportActive
            && ExportPaths.isLANBrowsableMediaRelativePath(relativePath)
    }

    /// Playback list link — direct `href` when idle; new-tab `href` during export. Separate browser `#t=` when seek &gt; 0.
    static func lanIndexPlaybackLinks(relativePath name: String, resumeStartSec: Int) -> String {
        let escaped = htmlEscape(name)
        if lanMediaListUsesClickOnly(relativePath: name) {
            let primary = lanMediaClickAnchor(relativePath: name, innerHTML: escaped)
            guard resumeStartSec > 0 else { return primary }
            let resumePath = "\(name)#t=\(resumeStartSec)"
            let resumeLabel = htmlEscape("browser #t=\(formatLANClock(resumeStartSec))")
            return """
                \(primary) · \(lanMediaClickAnchor(relativePath: resumePath, innerHTML: resumeLabel, extraClass: "lan-browser-resume"))
                """
        }
        let primary = "<a href=\"\(escaped)\">\(escaped)</a>"
        guard resumeStartSec > 0 else { return primary }
        return """
            \(primary) · <a href="\(escaped)#t=\(resumeStartSec)" class="lan-browser-resume">browser #t=\(formatLANClock(resumeStartSec))</a>
            """
    }

    static func htmlDashboardStatsBlock() -> String {
        let dashboard = ExportPlaybackState.shared.lanDashboardLines()
        guard !dashboard.isEmpty else { return "" }
        let statsEscaped = dashboard.map { "<li>\(htmlEscape($0))</li>" }.joined()
        return """
        <ul id="lan-dashboard-stats">\(statsEscaped)</ul>
        """
    }

    static func htmlExportSourceLineBlock() -> String {
        let resolved = LANExportSourceDisplay.resolve()
        let hidden = resolved == nil ? " style=\"display:none\"" : ""
        let label = htmlEscape(resolved.map { LANExportSourceDisplay.label(for: $0.phase) } ?? "Export source")
        let name = htmlEscape(resolved?.displayName ?? "")
        let phase = resolved?.phase ?? ""
        let showResume = phase == "paused"
        let actionsHidden = showResume ? "" : " style=\"display:none\""
        let phaseClass = phase == "running" ? " is-active" : (phase == "paused" ? " is-paused" : "")
        return """
        <div id="lan-export-source-wrap" class="export-source-line\(phaseClass)"\(hidden)>
          <div class="export-source-main">
            <strong id="lan-export-source-label">\(label):</strong>
            <span id="lan-export-source-name">\(name)</span>
          </div>
          <div class="export-source-actions" id="lan-export-source-actions"\(actionsHidden)>
            <button type="button" id="export-resume">Start export</button>
          </div>
        </div>
        """
    }

    static func htmlPlaybackStatusLine(_ line: String) -> String {
        """
        <p><strong id="lan-playback-line">\(htmlEscape(line))</strong></p>
        """
    }

    /// Poll `status.json` for export source + LAN playback stats; lists on `status_lists.json`.
    /// `monitorOnly` — skip pCloud bookmark fetch on list poll. `deferAutoPoll` — `/browse` during export.
    static func htmlLANLiveRefreshScript(
        monitorOnly: Bool = false,
        deferAutoPoll: Bool = false
    ) -> String {
        let bookmarkPoll = monitorOnly
            ? ""
            : """
            if (typeof window.refreshLANBookmarks === "function") {
              window.refreshLANBookmarks().catch(function () {});
            }
            """
        let autoPollStart = deferAutoPoll
            ? ""
            : """
            poll();
            setTimeout(pollLists, 5000);
            setInterval(poll, pollMs);
            setInterval(pollLists, listPollMs);
            """
        return """
        <script>
        (function () {
          var pollMs = \(lanStatusPollMs);
          var listPollMs = \(lanStatusListsPollMs);
          function esc(s) {
            return String(s)
              .replace(/&/g, "&amp;")
              .replace(/</g, "&lt;")
              .replace(/"/g, "&quot;");
          }
          function setMediaMaintenanceEnabled(enabled) {
            // Trim/Clear only — LAN speed test stays available during export (cellular WAN vs Wi‑Fi LAN).
            ["export-trim-media", "export-clear-media"].forEach(function (id) {
              var btn = document.getElementById(id);
              if (btn) btn.disabled = !enabled;
            });
          }
          function applyExportSource(src) {
            if (window._exportSourcePending) return;
            var wrap = document.getElementById("lan-export-source-wrap");
            if (!wrap) return;
            if (!src || !src.displayName) {
              wrap.style.display = "none";
              setMediaMaintenanceEnabled(true);
              return;
            }
            wrap.style.display = "";
            wrap.className = "export-source-line"
              + (src.phase === "running" ? " is-active" : src.phase === "paused" ? " is-paused" : "");
            var label = document.getElementById("lan-export-source-label");
            var name = document.getElementById("lan-export-source-name");
            if (label) label.textContent = (src.label || "Export source") + ":";
            if (name) name.textContent = src.displayName;
            var actions = document.getElementById("lan-export-source-actions");
            if (actions) actions.style.display = src.phase === "paused" ? "" : "none";
            setMediaMaintenanceEnabled(src.phase !== "running");
          }
          window.updateExportSourceLine = function (phase, displayName) {
            var labels = { running: "Exporting", paused: "Paused export", finished: "Last export" };
            applyExportSource({ phase: phase, displayName: displayName, label: labels[phase] || "Export source" });
          };
          function applyLive(live) {
            if (!live) return;
            var stats = document.getElementById("lan-dashboard-stats");
            if (stats && live.dashboardLines && live.dashboardLines.length) {
              stats.innerHTML = live.dashboardLines.map(function (l) {
                return "<li>" + esc(l) + "</li>";
              }).join("");
            }
            var line = document.getElementById("lan-playback-line");
            if (line && live.playableStatusLine) {
              line.textContent = live.playableStatusLine;
            }
          }
          function applyPlaybackSection(j) {
            if (!j) return;
            if (typeof j.playbackStatusHTML === "string") {
              var status = document.getElementById("lan-playback-status");
              if (status) status.innerHTML = j.playbackStatusHTML;
            }
            if (typeof j.playbackListHTML === "string") {
              var files = document.getElementById("lan-playback-files");
              if (files) files.innerHTML = j.playbackListHTML;
            }
            if (typeof j.exportLogsListHTML === "string") {
              var logs = document.getElementById("lan-export-logs");
              if (logs) logs.innerHTML = j.exportLogsListHTML;
            }
          }
          window.refreshLANPlayback = function () {
            return fetch("status.json", { cache: "no-store" })
              .then(function (r) { return r.json(); })
              .then(function (j) { applyPlaybackSection(j); return j; });
          };
          function applyLists(j) {
            if (!j) return;
            if (typeof j.playbackListHTML === "string") {
              var files = document.getElementById("lan-playback-files");
              if (files) files.innerHTML = j.playbackListHTML;
            }
            if (typeof j.exportLogsListHTML === "string") {
              var logs = document.getElementById("lan-export-logs");
              if (logs) logs.innerHTML = j.exportLogsListHTML;
            }
            if (typeof window.refreshLANLoopPlaylist === "function") {
              window.refreshLANLoopPlaylist(j.files);
            }
          }
          function pollLists() {
            fetch("status_lists.json", { cache: "no-store" })
              .then(function (r) { return r.json(); })
              .then(applyLists)
              .catch(function () {});
          }
          function poll() {
            \(bookmarkPoll)
            fetch("status.json", { cache: "no-store" })
              .then(function (r) { return r.json(); })
              .then(function (j) {
                applyExportSource(j.exportSource);
                applyLive(j.lanLive);
                applyPendingQueue(j.pendingExportQueue);
                applyPausedExports(j.pausedExports);
                if (typeof j.playbackStatusHTML === "string") {
                  var status = document.getElementById("lan-playback-status");
                  if (status) status.innerHTML = j.playbackStatusHTML;
                }
              })
              .catch(function () {});
          }
          \(htmlPendingQueueClientHelpersJS())
          wirePendingQueue();
          \(autoPollStart)
        })();
        </script>
        """
    }

    static func refreshLANMetricsBeforeStatusResponse() {
        let now = Date()
        if let last = lastLANMetricsRefresh,
           now.timeIntervalSince(last) < lanMetricsRefreshMinInterval {
            return
        }
        lastLANMetricsRefresh = now
        // Never block the LAN connection queue on sparse/_working probes (can stall HTTP for all clients).
        DispatchQueue.global(qos: .utility).async {
            if ExportPlaybackState.shared.usesVanillaDownloadForLAN() {
                return
            }
            if ExportPlaybackState.shared.usesPCloudTranscodedWorkingForLAN() {
                let url = ExportPaths.workingTranscodedURL
                guard FileManager.default.fileExists(atPath: url.path),
                      let sizeNum = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
                    return
                }
                ExportPlaybackState.shared.updateTranscodedWorkingFileBytes(sizeNum.int64Value)
                return
            }
            if FileManager.default.fileExists(atPath: ExportPaths.workingSourceURL.path) {
                WorkingSourceSparseCatalog.refreshPlaybackState(for: ExportPaths.workingSourceURL)
            }
        }
    }

    static func playbackStatusHTMLBlock() -> String {
        let usesVanilla = ExportPlaybackState.shared.usesVanillaDownloadForLAN()
        if usesVanilla {
            let rel = ExportPlaybackState.shared.vanillaLANRelativePath()
            let line = ExportPlaybackState.shared.lanPlayableStatusLine()
            let startSec = ExportPlaybackState.shared.frozenPlaybackStartSecondsInt
            let seekNote = startSec > 0
                ? "<p><em>Export seek <code>\(formatLANClock(startSec))</code> — use the plain file link for WebDAV/PotPlayer; use <strong>browser #t=</strong> on the index for Quest-style resume (do not copy the <code>#t=</code> URL into other players). Download grows from 0:00.</em></p>"
                : ""
            return """
            \(htmlPlaybackStatusLine(line))
            \(htmlDashboardStatsBlock())
            <p><em>Vanilla download — <code>\(rel)</code> (full file, original extension; not sparse <code>_working.mp4</code>).</em></p>
            \(seekNote)
            <p>Prefer <code>loop/op_00.mp4</code> when segments exist.</p>
            """
        }
        if ExportPlaybackState.shared.usesPCloudTranscodedWorkingForLAN()
            || FileManager.default.fileExists(atPath: ExportPaths.workingTranscodedURL.path) {
            let line = ExportPlaybackState.shared.lanPlayableStatusLine()
            return """
            \(htmlPlaybackStatusLine(line))
            \(htmlDashboardStatsBlock())
            <p><em>pCloud HLS transcode — <code>pcld_ios_media/_working_pcloud_transcode.mp4</code> grows with export (real MP4, not the original WMV/MKV file).</em></p>
            <p>Prefer <code>loop/op_00.mp4</code> while export runs.</p>
            """
        }
        if FileManager.default.fileExists(atPath: ExportPaths.workingSourceURL.path) {
            let line = ExportPlaybackState.shared.lanPlayableStatusLine()
            let startSec = ExportPlaybackState.shared.playbackStartSeconds
            let startedReadable = ExportPlaybackState.shared.timelineSecondsIsReadable(startSec)
            let startedNote = startedReadable
                ? ""
                : "<p><em>Started position is not dense on disk yet (need ~45s preroll before <code>\(formatLANClock(startSec))</code> for decode) — run export again from that seek on a new build, use <code>loop/op_00.mp4</code>, or VLC on <code>_working.mp4</code>.</em></p>"
            return """
            \(htmlPlaybackStatusLine(line))
            \(htmlDashboardStatsBlock())
            <p><code>LAN playable till</code> = furthest contiguous dense bytes from playback start. Below Mbps cutoff: prefetch to EOF, no <code>op_*.mp4</code>. At/above cutoff: <code>op_*.mp4</code> plus minimal <code>_working</code> prefetch when LAN server is on.</p>
            \(startedNote)
            """
        }
        return ""
    }

    static func playbackMediaFileListHTML() -> String {
        var items: [String] = []
        let entries = listExportFilesForPlaybackIndex()
        let limit = ExportPaths.lanPlaybackArchiveIndexLimit + 12
        let capped = entries.count > limit
        for entry in entries.prefix(limit) {
            let name = entry.name
            // Covered by the Paused section (one row per clip + optional play link).
            if name.hasPrefix(parkedPlaybackPrefix) { continue }
            var sizeNote = ""
            if entry.size > 0 {
                sizeNote = " (\(entry.size / 1024) KB)"
            }
            let escaped = htmlEscape(name)
            var note = ""
            var deleteButton = ""
            if name.hasPrefix("\(ExportPaths.mediaExportFolderName)/_vanilla_download.")
                || name == ExportPaths.pathRelativeToExports(ExportPaths.vanillaFastStartURL) {
                let startSec = ExportPlaybackState.shared.frozenPlaybackStartSecondsInt
                let vanillaNote = name.contains("_vanilla_faststart")
                    ? " — leftover faststart sidecar (older builds; not written anymore)"
                    : " — full vanilla WebDAV download (original extension)"
                let seekNote = startSec > 0
                    ? " — export seek \(formatLANClock(startSec)) (download from 0:00)"
                    : ""
                items.append(
                    "<li>\(lanIndexPlaybackLinks(relativePath: name, resumeStartSec: startSec))\(sizeNote)\(vanillaNote)\(seekNote)</li>"
                )
                continue
            }
            if name == ExportPaths.pathRelativeToExports(ExportPaths.workingTranscodedURL) {
                let cursorSec = Int(ExportPlaybackState.shared.exportCursorSeconds.rounded(.down))
                let link = lanMediaListUsesClickOnly(relativePath: name)
                    ? lanMediaClickAnchor(relativePath: name, innerHTML: escaped)
                    : "<a href=\"\(escaped)\">\(escaped)</a>"
                items.append(
                    "<li>\(link)\(sizeNote)" +
                        " — pCloud transcode (grows through ~\(formatLANClock(cursorSec)); not original file)</li>"
                )
                continue
            }
            if name == ExportPaths.pathRelativeToExports(ExportPaths.workingSourceURL) {
                let startSec = ExportPlaybackState.shared.frozenPlaybackStartSecondsInt
                let tillSec = Int(
                    ExportPlaybackState.shared.maxBrowserPlayableTimelineSeconds().rounded(.down)
                )
                let startNote = startSec > 0
                    ? " — resume from \(formatLANClock(startSec)); LAN dense through ~\(formatLANClock(tillSec))"
                    : " — sparse partial copy; LAN dense through ~\(formatLANClock(tillSec))"
                items.append(
                    "<li>\(lanIndexPlaybackLinks(relativePath: name, resumeStartSec: startSec))\(sizeNote)\(startNote)</li>"
                )
                continue
            } else if name.hasSuffix(".mp4"),
                      name.contains("\(ExportPaths.mediaExportFolderName)/\(ExportPaths.segmentLoopFolderName)/") {
                note = " — ~60s segment in loop/ (Range supported)"
            } else if name.hasPrefix(archivePlaybackPrefix) {
                note = " — retained export (archive/)"
                deleteButton = " <button type=\"button\" class=\"lan-archive-delete\" data-path=\"\(escaped)\">Delete</button>"
            } else if name.hasSuffix(".mp4") {
                note = " — sparse in-progress source (seek in player to export start)"
            }
            if lanMediaListUsesClickOnly(relativePath: name) {
                items.append(
                    "<li>\(lanMediaClickAnchor(relativePath: name, innerHTML: escaped))\(sizeNote)\(note)\(deleteButton)</li>"
                )
            } else {
            items.append("<li><a href=\"\(escaped)\">\(escaped)</a>\(sizeNote)\(note)\(deleteButton)</li>")
            }
        }
        if capped {
            items.append(
                "<li><em>… \(entries.count - limit) more file(s) on phone — use WebDAV/rclone for full tree.</em></li>"
            )
        }
        if ExportPlaybackState.shared.isLANExportActive {
            items.append(
                "<li><em>Media/archive links use real URLs and open in a new tab during export (LAN page stays open). Large browser GETs without Range are blocked during export. WebDAV unchanged.</em></li>"
            )
        }
        return items.isEmpty
            ? "<li><em>No export files yet — start export on the phone.</em></li>"
            : items.joined()
    }

    /// Same paused queue as the phone Paused tab (not only on-disk `parked/` folders).
    static func htmlPausedExportListItems() -> [String] {
        let excludeKey = ExportPlaybackState.shared.isLANExportActive
            ? ExportRetentionSourceCatalog.read()?.fileKey
            : nil
        let paused = ResumeStore.pausedExportsForLAN(excludingFileKey: excludeKey, limit: 16)
        guard !paused.isEmpty else { return [] }
        return paused.map { entry in
            let title = entry.resolvedDisplayName.isEmpty ? "Paused export" : entry.resolvedDisplayName
            let label = htmlEscape(title)
            let play: String
            if let rel = ExportParkedMedia.primaryPlaybackRelativePath(forFileKey: entry.fileKey) {
                let linkLabel = htmlEscape(ExportParkedMedia.lanPlaybackLabel(forRelativePath: rel))
                play = lanMediaClickAnchor(relativePath: rel, innerHTML: linkLabel)
            } else if let rootRel = rootPlaybackRelativePathMatchingPaused(fileKey: entry.fileKey) {
                play = lanMediaClickAnchor(relativePath: rootRel, innerHTML: label)
            } else {
                // No on-disk media yet — filename only (Resume button has seek).
                play = "<span>\(label)</span>"
            }
            let resumeControl: String
            if entry.isSourceUnavailable {
                resumeControl = " <span class=\"muted\">\(htmlEscape(ResumeStore.pCloudSourceUnavailableMessage))</span>"
            } else {
                resumeControl = htmlResumeExportButton(for: entry)
            }
            return "<li>\(play)\(resumeControl)</li>"
        }
    }

    /// Soft-paused clip still on root (not yet parked under `parked/`).
    static func rootPlaybackRelativePathMatchingPaused(fileKey: String) -> String? {
        guard let manifest = ExportRetentionSourceCatalog.read(),
              manifest.fileKey == fileKey else {
            return nil
        }
        if ExportPaths.vanillaPrimaryMediaExistsOnDisk() {
            let item = WebDAVItem(
                href: "",
                name: manifest.sourceFileName,
                isDirectory: false,
                contentLength: nil
            )
            let url = ExportPaths.vanillaPrimaryLocalURL(for: item)
            if FileManager.default.fileExists(atPath: url.path) {
                return ExportPaths.pathRelativeToExports(url)
            }
        }
        if FileManager.default.fileExists(atPath: ExportPaths.workingTranscodedURL.path) {
            return ExportPaths.pathRelativeToExports(ExportPaths.workingTranscodedURL)
        }
        if FileManager.default.fileExists(atPath: ExportPaths.workingSourceURL.path) {
            return ExportPaths.pathRelativeToExports(ExportPaths.workingSourceURL)
        }
        return nil
    }

    /// Resume/Export control beside a parked partial (same trigger path as Browse Export).
    static func htmlParkedResumeExportButton(relativePath: String) -> String {
        guard let meta = ExportParkedMedia.lanResumeTrigger(forRelativePath: relativePath) else {
            return ""
        }
        return htmlResumeExportButton(
            displayName: meta.displayName,
            href: meta.href,
            folderPath: meta.folderPath,
            seekMs: meta.seekMs ?? 0
        )
    }

    static func htmlResumeExportButton(for entry: ResumeEntry) -> String {
        htmlResumeExportButton(
            displayName: entry.resolvedDisplayName,
            href: entry.href,
            folderPath: entry.folderPath,
            seekMs: entry.effectiveResumeSeekMs
        )
    }

    static func htmlResumeExportButton(
        displayName: String,
        href: String?,
        folderPath: String?,
        seekMs: Int64
    ) -> String {
        let name = htmlEscape(displayName)
        let hrefEsc = htmlEscape(href ?? "")
        let folder = htmlEscape(folderPath ?? "")
        let seek = ResumeSeek.clampMs(seekMs, sourceDurationMs: nil)
        let label = seek > 0
            ? "Resume export (\(formatLANClock(Int(seek / 1000))))"
            : "Resume export"
        return " <button type=\"button\" class=\"export-parked\" data-name=\"\(name)\" data-href=\"\(hrefEsc)\" data-folder-path=\"\(folder)\" data-seek-ms=\"\(seek)\">\(htmlEscape(label))</button>"
    }

    static func htmlPendingQueueListItems(from items: [[String: Any]]) -> String {
        guard !items.isEmpty else {
            return #"<li class="muted"><em>No queued exports</em></li>"#
        }
        return items.map { row in
            let id = htmlEscape("\(row["id"] ?? "")")
            let name = htmlEscape("\(row["displayName"] ?? "")")
            var meta = ""
            if let folder = row["folderPath"] as? String, !folder.isEmpty {
                meta = " <span class=\"muted\">\(htmlEscape(folder))</span>"
            }
            return """
            <li data-id="\(id)"><span class="pending-name">\(name)</span>\(meta) \
            <button type="button" class="pending-remove" data-id="\(id)">Remove</button></li>
            """
        }.joined()
    }

    /// Queued (not-started) FIFO — same as phone Paused tab Queued section.
    static func htmlPendingQueueSection() -> String {
        let queue = pendingExportQueueStatusPayload()
        let count = queue["count"] as? Int ?? 0
        let items = queue["items"] as? [[String: Any]] ?? []
        let actionsHidden = count == 0 ? " style=\"display:none\"" : ""
        // Collapsed by default (`<details>` without `open`); count stays visible on the summary.
        return """
        <details id="lan-pending-queue-wrap" class="lan-pending-queue">
          <summary id="lan-pending-queue-heading">Queued exports (\(count))</summary>
          <p class="muted">Not started yet. Auto-starts when idle after finish/Stop. User Pause holds the queue.</p>
          <p id="lan-pending-queue-actions"\(actionsHidden)>
            <button type="button" id="lan-pending-clear">Clear queue</button>
          </p>
          <ul id="lan-pending-queue">
          \(htmlPendingQueueListItems(from: items))
          </ul>
        </details>
        """
    }

    /// Paused checkpoints — same rows as phone Paused tab (not pending FIFO).
    static func htmlPausedExportsSection() -> String {
        let excludeKey = ExportPlaybackState.shared.isLANExportActive
            ? ExportRetentionSourceCatalog.read()?.fileKey
            : nil
        let paused = ResumeStore.pausedExportsForLAN(excludingFileKey: excludeKey, limit: 16)
        let count = paused.count
        let actionsHidden = count == 0 ? " style=\"display:none\"" : ""
        let listHTML: String = {
            let rows = htmlPausedExportListItems()
            if rows.isEmpty {
                return #"<li class="muted"><em>No paused exports</em></li>"#
            }
            return rows.joined()
        }()
        return """
        <details id="lan-paused-wrap" class="lan-paused-exports">
          <summary id="lan-paused-heading">Paused exports (\(count))</summary>
          <p class="muted">Checkpoints from soft-pause / Pause. Unavailable rows (missing from saved pCloud folder) have no Resume — redo search / re-export from companion, or Copy name / Search in Browse on the phone. Move to queued appends available rows onto FIFO as fresh jobs (drops checkpoints / parked media; skips unavailable). Clear removes parked media; live export is kept.</p>
          <p id="lan-paused-actions"\(actionsHidden)>
            <button type="button" id="lan-paused-queue-all">Move to queued</button>
            <button type="button" id="lan-paused-clear">Clear paused</button>
          </p>
          <ul id="lan-paused-list">
          \(listHTML)
          </ul>
        </details>
        """
    }

    static func pausedExportsStatusPayload() -> [String: Any] {
        let excludeKey = ExportPlaybackState.shared.isLANExportActive
            ? ExportRetentionSourceCatalog.read()?.fileKey
            : nil
        let paused = ResumeStore.pausedExportsForLAN(excludingFileKey: excludeKey, limit: 16)
        let rows = htmlPausedExportListItems()
        let listHTML = rows.isEmpty
            ? #"<li class="muted"><em>No paused exports</em></li>"#
            : rows.joined()
        return [
            "count": paused.count,
            "listHTML": listHTML,
        ]
    }

    /// JS helpers for queue list + Remove/Clear and paused Clear / Move to queued (Basic auth).
    static func htmlPendingQueueClientHelpersJS() -> String {
        let user = lanWebDAVUsername
        let pass = lanWebDAVPassword
        return """
          var QUEUE_AUTH = "Basic " + btoa("\(user):\(pass)");
          function applyPendingQueue(q) {
            var ul = document.getElementById("lan-pending-queue");
            var heading = document.getElementById("lan-pending-queue-heading");
            var actions = document.getElementById("lan-pending-queue-actions");
            if (!ul) return;
            var items = (q && q.items) ? q.items : [];
            var count = (q && typeof q.count === "number") ? q.count : items.length;
            if (heading) heading.textContent = "Queued exports (" + count + ")";
            if (actions) actions.style.display = count ? "" : "none";
            if (!items.length) {
              ul.innerHTML = '<li class="muted"><em>No queued exports</em></li>';
              return;
            }
            ul.innerHTML = items.map(function (it) {
              var id = esc(it.id || "");
              var name = esc(it.displayName || "");
              var folder = it.folderPath ? (' <span class="muted">' + esc(it.folderPath) + '</span>') : "";
              return '<li data-id="' + id + '"><span class="pending-name">' + name + '</span>' + folder
                + ' <button type="button" class="pending-remove" data-id="' + id + '">Remove</button></li>';
            }).join("");
          }
          function applyPausedExports(p) {
            var ul = document.getElementById("lan-paused-list");
            var heading = document.getElementById("lan-paused-heading");
            var actions = document.getElementById("lan-paused-actions");
            if (!ul) return;
            var count = (p && typeof p.count === "number") ? p.count : 0;
            if (heading) heading.textContent = "Paused exports (" + count + ")";
            if (actions) actions.style.display = count ? "" : "none";
            if (p && typeof p.listHTML === "string") {
              ul.innerHTML = p.listHTML;
              return;
            }
            ul.innerHTML = '<li class="muted"><em>No paused exports</em></li>';
          }
          function postQueueAction(body) {
            return fetch("export_queue.json", {
              method: "POST",
              headers: { "Authorization": QUEUE_AUTH, "Content-Type": "application/json" },
              body: JSON.stringify(body),
              cache: "no-store"
            }).then(function (r) {
              return r.json().then(function (j) { return { ok: r.ok, j: j }; }).catch(function () {
                return { ok: r.ok, j: null };
              });
            });
          }
          function postPausedAction(body) {
            return fetch("paused_exports.json", {
              method: "POST",
              headers: { "Authorization": QUEUE_AUTH, "Content-Type": "application/json" },
              body: JSON.stringify(body),
              cache: "no-store"
            }).then(function (r) {
              return r.json().then(function (j) { return { ok: r.ok, j: j }; }).catch(function () {
                return { ok: r.ok, j: null };
              });
            });
          }
          function wirePendingQueue() {
            var ul = document.getElementById("lan-pending-queue");
            if (ul && !ul.getAttribute("data-ls-wired")) {
              ul.setAttribute("data-ls-wired", "1");
              ul.addEventListener("click", function (ev) {
                var t = ev.target;
                var btn = (t && t.closest) ? t.closest(".pending-remove") : null;
                if (!btn && t && t.classList && t.classList.contains("pending-remove")) btn = t;
                if (!btn) return;
                var id = btn.getAttribute("data-id") || "";
                if (!id) return;
                btn.disabled = true;
                postQueueAction({ action: "remove", id: id })
                  .then(function (res) {
                    if (res.j && res.j.pendingExportQueue) applyPendingQueue(res.j.pendingExportQueue);
                  })
                  .catch(function () {})
                  .finally(function () { btn.disabled = false; });
              });
            }
            var clearBtn = document.getElementById("lan-pending-clear");
            if (clearBtn && !clearBtn.getAttribute("data-ls-wired")) {
              clearBtn.setAttribute("data-ls-wired", "1");
              clearBtn.addEventListener("click", function () {
                if (!window.confirm("Clear all queued exports?")) return;
                clearBtn.disabled = true;
                postQueueAction({ action: "clear" })
                  .then(function (res) {
                    if (res.j && res.j.pendingExportQueue) applyPendingQueue(res.j.pendingExportQueue);
                    else applyPendingQueue({ count: 0, items: [] });
                  })
                  .catch(function () {})
                  .finally(function () { clearBtn.disabled = false; });
              });
            }
            var clearPaused = document.getElementById("lan-paused-clear");
            if (clearPaused && !clearPaused.getAttribute("data-ls-wired")) {
              clearPaused.setAttribute("data-ls-wired", "1");
              clearPaused.addEventListener("click", function () {
                if (!window.confirm("Clear all paused exports? Parked media is removed. Live export is kept.")) return;
                clearPaused.disabled = true;
                postPausedAction({ action: "clear" })
                  .then(function (res) {
                    if (res.j && res.j.pausedExports) applyPausedExports(res.j.pausedExports);
                    else applyPausedExports({ count: 0, listHTML: '<li class="muted"><em>No paused exports</em></li>' });
                    if (window.refreshLANPlayback) {
                      try { window.refreshLANPlayback(); } catch (e) {}
                    }
                  })
                  .catch(function () {})
                  .finally(function () { clearPaused.disabled = false; });
              });
            }
            var queueAllPaused = document.getElementById("lan-paused-queue-all");
            if (queueAllPaused && !queueAllPaused.getAttribute("data-ls-wired")) {
              queueAllPaused.setAttribute("data-ls-wired", "1");
              queueAllPaused.addEventListener("click", function () {
                queueAllPaused.disabled = true;
                postPausedAction({ action: "queue_all" })
                  .then(function (res) {
                    if (res.j && res.j.pausedExports) applyPausedExports(res.j.pausedExports);
                    else applyPausedExports({ count: 0, listHTML: '<li class="muted"><em>No paused exports</em></li>' });
                    if (res.j && res.j.pendingExportQueue) applyPendingQueue(res.j.pendingExportQueue);
                    if (window.refreshLANPlayback) {
                      try { window.refreshLANPlayback(); } catch (e) {}
                    }
                  })
                  .catch(function () {})
                  .finally(function () { queueAllPaused.disabled = false; });
              });
            }
          }
          // Per-file Delete on archive/ rows. Delegated, because the file list is re-rendered on refresh.
          if (!window.__lanArchiveDeleteBound) {
            window.__lanArchiveDeleteBound = true;
            document.addEventListener("click", function (e) {
              var btn = e.target && e.target.closest ? e.target.closest("button.lan-archive-delete") : null;
              if (!btn) return;
              e.preventDefault();
              var path = btn.getAttribute("data-path") || "";
              if (path.indexOf("/archive/") < 0) return;
              var name = path.split("/").pop();
              if (!confirm("Permanently delete " + name + " from the phone? This cannot be undone.")) return;
              btn.disabled = true;
              btn.textContent = "Deleting…";
              var url = "/" + path.split("/").map(encodeURIComponent).join("/");
              fetch(url, { method: "DELETE", headers: { "Authorization": QUEUE_AUTH } })
                .then(function (r) {
                  // 404 = already gone. Either way the row should go.
                  if (r.status === 204 || r.status === 200 || r.status === 404) {
                    var li = btn.closest("li");
                    if (li && li.parentNode) li.parentNode.removeChild(li);
                    return;
                  }
                  throw new Error("HTTP " + r.status);
                })
                .catch(function (err) {
                  btn.disabled = false;
                  btn.textContent = "Delete";
                  alert("Could not delete " + name + ": " + err.message);
                });
            });
          }
        """
    }

    static func htmlLANExportLogListItems(relativePaths: [String]) -> String {
        relativePaths.map { rel in
            let escaped = htmlEscape(rel)
            return "<li><a href=\"\(escaped)\">\(escaped)</a></li>"
        }.joined()
    }

    /// During export: live log plus auxiliary traces (e.g. `search_debug.txt`) without scanning history.
    static func htmlLANMinimalExportLogLinks() -> String {
        var paths = [ExportPaths.pathRelativeToExports(ExportPaths.latestLogTextURL)]
        for aux in ExportPaths.listLANAuxiliaryLogRelativePaths() where !paths.contains(aux) {
            paths.append(aux)
        }
        return htmlLANExportLogListItems(relativePaths: paths)
    }

    static func htmlMonitorQuickLogLinks() -> String {
        var links = [
            #"<a href="export_latest.txt">export_latest.txt</a>"#,
            #"<a href="status.json">status.json</a>"#,
            #"<a href="wifi_www_probe.json">wifi_www_probe.json</a>"#,
            #"<a href="lan_throughput.json">lan_throughput.json</a>"#,
            #"<a href="xr_tunnel.json">xr_tunnel.json</a>"#,
            #"<a href="xr_debug.json">xr_debug.json</a>"#,
            "<a href=\"\(LANExportTriggerControl.ackRelativePath)\">export_trigger.ack.json</a>",
            #"<a href="export_from_folder.json">export_from_folder.json</a>"#,
            #"<a href="export_queue.json">export_queue.json</a>"#,
            #"<a href="paused_exports.json">paused_exports.json</a>"#,
            "<a href=\"\(PendingExportQueue.relativePath)\">export_pending_queue.json</a>",
        ]
        if FileManager.default.fileExists(atPath: ExportPaths.searchDebugLogURL.path) {
            links.append(#"<a href="search_debug.txt">search_debug.txt</a>"#)
        }
        if FileManager.default.fileExists(atPath: ExportPaths.searchCacheSnapshotURL.path) {
            links.append(#"<a href="search_cache.json">search_cache.json</a>"#)
        }
        return links.joined(separator: " · ")
    }

    static func exportLogsFileListHTML() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var items: [String] = []
        for entry in listExportLogEntriesForLANIndex() {
            let escaped = htmlEscape(entry.name)
            var meta = ""
            if entry.size > 0 {
                meta += " (\(entry.size / 1024) KB)"
            }
            if let modified = entry.modified {
                meta += " — \(htmlEscape(formatter.string(from: modified)))"
            }
            items.append("<li><a href=\"\(escaped)\">\(escaped)</a>\(meta)</li>")
        }
        return items.isEmpty
            ? "<li><em>No export logs yet.</em></li>"
            : items.joined()
    }

    static func htmlPlaybackStatusShell() -> String {
        """
        <p><strong id="lan-playback-line">LAN playback</strong></p>
        <ul id="lan-dashboard-stats"></ul>
        """
    }

    /// Playback line + dashboard for first paint during export (manual refresh updates thereafter).
    static func htmlPlaybackStatusLiveShell() -> String {
        let line = ExportPlaybackState.shared.lanPlayableStatusLine()
        return """
        \(htmlPlaybackStatusLine(line))
        \(htmlDashboardStatsBlock())
        """
    }

    static func htmlExportSourceLineShell() -> String {
        """
        <div id="lan-export-source-wrap" class="export-source-line" style="display:none">
          <div class="export-source-main">
            <strong id="lan-export-source-label">Export source:</strong>
            <span id="lan-export-source-name"></span>
          </div>
          <div class="export-source-actions" id="lan-export-source-actions" style="display:none">
            <button type="button" id="export-resume">Start export</button>
          </div>
        </div>
        """
    }

    static func htmlMonitorStaticPlaybackLinks() -> String {
        var items: [String] = []
        let fm = FileManager.default
        for index in 0 ..< ExportPaths.segmentFileCount {
            let url = ExportPaths.segmentURL(index: index)
            guard fm.fileExists(atPath: url.path) else { continue }
            let rel = ExportPaths.pathRelativeToExports(url)
            let esc = htmlEscape(rel)
            let link = lanMediaListUsesClickOnly(relativePath: rel)
                ? lanMediaClickAnchor(relativePath: rel, innerHTML: esc)
                : "<a href=\"\(esc)\">\(esc)</a>"
            items.append("<li>\(link)</li>")
        }
        if fm.fileExists(atPath: ExportPaths.workingTranscodedURL.path) {
            let rel = ExportPaths.pathRelativeToExports(ExportPaths.workingTranscodedURL)
            let esc = htmlEscape(rel)
            let link = lanMediaListUsesClickOnly(relativePath: rel)
                ? lanMediaClickAnchor(relativePath: rel, innerHTML: esc)
                : "<a href=\"\(esc)\">\(esc)</a>"
            items.append("<li>\(link) (growing transcode)</li>")
        }
        if fm.fileExists(atPath: ExportPaths.workingSourceURL.path) {
            let rel = ExportPaths.pathRelativeToExports(ExportPaths.workingSourceURL)
            let esc = htmlEscape(rel)
            let link = lanMediaListUsesClickOnly(relativePath: rel)
                ? lanMediaClickAnchor(relativePath: rel, innerHTML: esc)
                : "<a href=\"\(esc)\">\(esc)</a>"
            items.append("<li>\(link) (sparse)</li>")
        }
        if ExportPlaybackState.shared.isLANExportActive {
            for rel in ExportPaths.listLANPlaybackIndexRelativePaths(
                maxArchiveEntries: ExportPaths.lanPlaybackArchiveIndexLimitDuringExport
            ) where rel.contains("/archive/") {
                let esc = htmlEscape(rel)
                items.append(
                    "<li>\(lanMediaClickAnchor(relativePath: rel, innerHTML: esc)) (archive)</li>"
                )
            }
        }
        return items.isEmpty
            ? "<li><em>No media files yet.</em></li>"
            : items.joined()
    }

    /// Browser Range download → POST `/lan_throughput.json` (same sidecars as Measure HTTP leg).
    /// Pass `buttonId` to auto-bind (monitor `/`); `/browse` calls `bindLANSpeedTestButton` from the export panel.
    static func htmlLANSpeedTestScript(
        resultElementId: String? = nil,
        buttonId: String? = nil
    ) -> String {
        let minBytes = LANThroughputSidecar.minCandidateBytes
        let maxBytes = LANThroughputSidecar.maxTransferBytes
        let user = lanWebDAVUsername
        let pass = lanWebDAVPassword
        let resultIdJS = resultElementId.map { "\"\($0)\"" } ?? "null"
        let buttonIdJS = buttonId.map { "\"\($0)\"" } ?? "null"
        return """
        <script>
        (function () {
          var MIN_BYTES = \(minBytes);
          var MAX_BYTES = \(maxBytes);
          /// 10×64 MB ≈ one ~640 MB dense VR window; median damps Wi‑Fi noise.
          var RUN_COUNT = 10;
          var MIN_OK_RUNS = 5;
          var DEFAULT_AUTH = "Basic " + btoa("\(user):\(pass)");
          function isMediaName(name) {
            return /\\.(mp4|m4v|mov|mkv|webm)$/i.test(String(name || ""));
          }
          function isArchivePath(name) {
            var n = String(name || "").replace(/\\\\/g, "/");
            return n.indexOf("/archive/") >= 0 || n.indexOf("archive/") === 0;
          }
          function pickSpeedTestFile(files) {
            var list = Array.isArray(files) ? files : [];
            var eligible = list.filter(function (f) {
              var bytes = Number(f && f.bytes) || 0;
              return isMediaName(f && f.name) && bytes >= MIN_BYTES;
            });
            var archive = eligible.filter(function (f) { return isArchivePath(f.name); });
            var pool = archive.length ? archive : eligible;
            if (!pool.length) return null;
            return pool[Math.floor(Math.random() * pool.length)];
          }
          function medianMbps(samples) {
            var vals = samples.map(function (s) { return s.mbps; }).sort(function (a, b) { return a - b; });
            var mid = Math.floor(vals.length / 2);
            if (vals.length % 2) return vals[mid];
            return (vals[mid - 1] + vals[mid]) / 2;
          }
          function pickMedianSample(samples) {
            var med = medianMbps(samples);
            var best = samples[0];
            var bestDiff = Math.abs(samples[0].mbps - med);
            for (var i = 1; i < samples.length; i++) {
              var d = Math.abs(samples[i].mbps - med);
              if (d < bestDiff) {
                best = samples[i];
                bestDiff = d;
              }
            }
            return { median: med, sample: best };
          }
          function reportLANSpeed(msg, isErr, opts) {
            opts = opts || {};
            if (typeof opts.setStatus === "function") {
              opts.setStatus(msg, !!isErr);
            }
            var rid = opts.resultElementId;
            if (rid) {
              var el = document.getElementById(rid);
              if (el) {
                el.textContent = msg;
                if (window.__lanStatusColor) {
                  el.style.color = window.__lanStatusColor(!!isErr);
                } else {
                  el.style.color = isErr ? "#b00020" : "";
                }
              }
            }
          }
          async function oneRangeTransfer(url, rangeEnd) {
            var t0 = (typeof performance !== "undefined" && performance.now) ? performance.now() : Date.now();
            var resp = await fetch(url, {
              headers: { "Range": "bytes=0-" + rangeEnd },
              cache: "no-store"
            });
            if (!(resp.ok || resp.status === 206)) {
              throw new Error("Range GET HTTP " + resp.status);
            }
            var transferred = 0;
            if (resp.body && typeof resp.body.getReader === "function") {
              var reader = resp.body.getReader();
              while (true) {
                var chunk = await reader.read();
                if (chunk.done) break;
                transferred += chunk.value ? chunk.value.byteLength : 0;
              }
            } else {
              var buf = await resp.arrayBuffer();
              transferred = buf.byteLength;
              buf = null;
            }
            var t1 = (typeof performance !== "undefined" && performance.now) ? performance.now() : Date.now();
            var elapsed = Math.max((t1 - t0) / 1000, 0.001);
            if (transferred < 1024 * 1024) {
              throw new Error("Transfer too small (" + transferred + " bytes)");
            }
            return {
              mbps: (transferred * 8) / (elapsed * 1e6),
              transferredBytes: transferred,
              elapsedSeconds: elapsed
            };
          }
          async function runLANSpeedTest(opts) {
            opts = opts || {};
            var auth = opts.authHeader || DEFAULT_AUTH;
            var btn = opts.buttonId ? document.getElementById(opts.buttonId) : null;
            if (btn) btn.disabled = true;
            reportLANSpeed("LAN speed test: picking media (≥8 MB)…", false, opts);
            try {
              var listsRes = await fetch("status_lists.json", { cache: "no-store" });
              if (!listsRes.ok) throw new Error("status_lists.json HTTP " + listsRes.status);
              var lists = await listsRes.json();
              var pick = pickSpeedTestFile(lists.files);
              if (!pick) {
                throw new Error("No media file ≥ 8 MB on phone (need archive/ or other playback media).");
              }
              var rel = String(pick.name || "").replace(/^\\/+/, "");
              var url = "/" + rel;
              var fileBytes = Number(pick.bytes) || 0;
              var rangeEnd = Math.min(fileBytes, MAX_BYTES) - 1;
              if (rangeEnd < 0) throw new Error("Selected file has no readable bytes");
              var mbLabel = ((rangeEnd + 1) / (1024 * 1024)).toFixed(1);
              var samples = [];
              var failures = [];
              for (var i = 0; i < RUN_COUNT; i++) {
                reportLANSpeed(
                  "LAN speed test " + (i + 1) + "/" + RUN_COUNT + ": " + mbLabel + " MB from " + rel + "…",
                  false,
                  opts
                );
                try {
                  samples.push(await oneRangeTransfer(url, rangeEnd));
                } catch (runErr) {
                  failures.push((runErr && runErr.message) ? runErr.message : String(runErr));
                }
              }
              if (samples.length < MIN_OK_RUNS) {
                throw new Error(
                  "Need ≥" + MIN_OK_RUNS + " successful transfers (got " + samples.length + ")"
                    + (failures.length ? (": " + failures[0]) : "")
                );
              }
              var picked = pickMedianSample(samples);
              var mbps = picked.median;
              var sample = picked.sample;
              var listStr = samples.map(function (s) { return s.mbps.toFixed(1); }).join(", ");
              reportLANSpeed(
                "Median " + mbps.toFixed(1) + " Mbps of [" + listStr + "] — writing lan_throughput.json…",
                false,
                opts
              );
              var post = await fetch("lan_throughput.json", {
                method: "POST",
                headers: {
                  "Authorization": auth,
                  "Content-Type": "application/json"
                },
                body: JSON.stringify({
                  measuredMbps: mbps,
                  transferredBytes: sample.transferredBytes,
                  elapsedSeconds: sample.elapsedSeconds,
                  sourceUrl: url,
                  sourcePath: rel,
                  note: "LAN page HTTP Range ×" + samples.length
                    + " median (browser). Same sidecars as Measure HTTP leg; no mount / no other-router reboot. Samples Mbps: ["
                    + listStr + "]"
                }),
                cache: "no-store"
              });
              var bodyText = await post.text();
              var j = null;
              try { j = JSON.parse(bodyText); } catch (e) {}
              if (!post.ok) {
                throw new Error((j && (j.error || j.message)) || bodyText || ("POST HTTP " + post.status));
              }
              var rec = j && j.recommendedMaxMediaBitrateMbps != null
                ? j.recommendedMaxMediaBitrateMbps
                : "?";
              var measuredOut = j && j.measuredMbps != null ? j.measuredMbps : mbps.toFixed(2);
              reportLANSpeed(
                "LAN median " + measuredOut + " Mbps [" + listStr + "] → recommend " + rec
                  + " Mbps segment bitrate (HTTP-only; no router reboot)",
                false,
                opts
              );
            } catch (e) {
              reportLANSpeed((e && e.message) ? e.message : String(e), true, opts);
            } finally {
              if (btn && !window._exportSourcePending) btn.disabled = false;
            }
          }
          window.runLANSpeedTest = runLANSpeedTest;
          window.bindLANSpeedTestButton = function (opts) {
            opts = opts || {};
            var id = opts.buttonId;
            if (!id) return;
            var btn = document.getElementById(id);
            if (!btn) return;
            btn.onclick = function () {
              runLANSpeedTest(opts);
            };
          };
          var autoButtonId = \(buttonIdJS);
          var autoResultId = \(resultIdJS);
          if (autoButtonId) {
            window.bindLANSpeedTestButton({
              buttonId: autoButtonId,
              resultElementId: autoResultId,
              authHeader: DEFAULT_AUTH
            });
          }
        })();
        </script>
        """
    }

    static func htmlMonitorManualRefreshScript() -> String {
        """
        <script>
        (function () {
          function esc(s) {
            return String(s)
              .replace(/&/g, "&amp;")
              .replace(/</g, "&lt;")
              .replace(/"/g, "&quot;");
          }
          function setMediaMaintenanceEnabled(enabled) {
            // Trim/Clear only — LAN speed test stays available during export (cellular WAN vs Wi‑Fi LAN).
            ["export-trim-media", "export-clear-media"].forEach(function (id) {
              var btn = document.getElementById(id);
              if (btn) btn.disabled = !enabled;
            });
          }
          function applyExportSource(src) {
            var wrap = document.getElementById("lan-export-source-wrap");
            if (!wrap || !src || !src.displayName) {
              if (wrap) wrap.style.display = "none";
              setMediaMaintenanceEnabled(true);
              return;
            }
            wrap.style.display = "";
            wrap.className = "export-source-line"
              + (src.phase === "running" ? " is-active" : src.phase === "paused" ? " is-paused" : "");
            var label = document.getElementById("lan-export-source-label");
            var name = document.getElementById("lan-export-source-name");
            if (label) label.textContent = (src.label || "Export source") + ":";
            if (name) name.textContent = src.displayName;
            var actions = document.getElementById("lan-export-source-actions");
            if (actions) actions.style.display = src.phase === "paused" ? "" : "none";
            setMediaMaintenanceEnabled(src.phase !== "running");
          }
          function applyLive(live) {
            if (!live) return;
            var line = document.getElementById("lan-playback-line");
            if (line && live.playableStatusLine) line.textContent = live.playableStatusLine;
            var stats = document.getElementById("lan-dashboard-stats");
            if (stats && live.dashboardLines && live.dashboardLines.length) {
              stats.innerHTML = live.dashboardLines.map(function (l) {
                return "<li>" + esc(l) + "</li>";
              }).join("");
            }
          }
          function applyLists(j) {
            if (!j) return;
            if (typeof j.playbackListHTML === "string") {
              var files = document.getElementById("lan-playback-files");
              if (files) files.innerHTML = j.playbackListHTML;
            }
            if (typeof j.exportLogsListHTML === "string") {
              var logs = document.getElementById("lan-export-logs");
              if (logs) logs.innerHTML = j.exportLogsListHTML;
            }
            if (typeof window.refreshLANLoopPlaylist === "function") {
              window.refreshLANLoopPlaylist(j.files);
            }
          }
          function refreshStatus() {
            var btn = document.getElementById("lan-refresh-status");
            if (btn) btn.disabled = true;
            return fetch("status.json", { cache: "no-store" })
              .then(function (r) { return r.json(); })
              .then(function (j) {
                applyExportSource(j.exportSource);
                applyLive(j.lanLive);
                applyPendingQueue(j.pendingExportQueue);
                applyPausedExports(j.pausedExports);
                if (j.wifiWwwProbe) applyWifiWwwProbe(j.wifiWwwProbe);
                if (typeof j.playbackStatusHTML === "string") {
                  var status = document.getElementById("lan-playback-status");
                  if (status) status.innerHTML = j.playbackStatusHTML;
                }
              })
              .catch(function () {})
              .finally(function () { if (btn) btn.disabled = false; });
          }
          function refreshLists() {
            var btn = document.getElementById("lan-refresh-lists");
            if (btn) btn.disabled = true;
            return fetch("status_lists.json", { cache: "no-store" })
              .then(function (r) { return r.json(); })
              .then(applyLists)
              .catch(function () {})
              .finally(function () { if (btn) btn.disabled = false; });
          }
          var statusBtn = document.getElementById("lan-refresh-status");
          var listsBtn = document.getElementById("lan-refresh-lists");
          if (statusBtn) statusBtn.onclick = refreshStatus;
          if (listsBtn) listsBtn.onclick = refreshLists;
          function applyWifiWwwProbe(j) {
            var el = document.getElementById("lan-wifi-www-probe-result");
            if (!el || !j) return;
            if (j.ok === true) {
              el.textContent = "Phone Wi‑Fi → www OK" + (j.durationMs != null ? (" (" + j.durationMs + " ms)") : "")
                + (j.statusCode != null ? (" HTTP " + j.statusCode) : "");
            } else if (j.ok === false) {
              el.textContent = "Phone Wi‑Fi → www FAIL: " + (j.error || ("HTTP " + (j.statusCode || "?")));
            } else {
              el.textContent = "Phone Wi‑Fi → www: not probed yet";
            }
          }
          function runWifiWwwProbe() {
            var btn = document.getElementById("lan-wifi-www-probe");
            var el = document.getElementById("lan-wifi-www-probe-result");
            if (btn) btn.disabled = true;
            if (el) el.textContent = "Probing Phone Wi‑Fi → www (cellular blocked)…";
            var auth = "Basic " + btoa("\(lanWebDAVUsername):\(lanWebDAVPassword)");
            return fetch("wifi_www_probe.json", {
              method: "POST",
              headers: { "Authorization": auth, "Content-Type": "application/json", "Content-Length": "2" },
              body: "{}",
              cache: "no-store"
            })
              .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
              .then(function (res) {
                if (res.j) applyWifiWwwProbe(res.j);
                else if (el) el.textContent = "Probe failed (bad JSON)";
              })
              .catch(function (e) {
                if (el) el.textContent = "Probe request failed: " + (e && e.message ? e.message : e);
              })
              .finally(function () { if (btn) btn.disabled = false; });
          }
          var probeBtn = document.getElementById("lan-wifi-www-probe");
          if (probeBtn) probeBtn.onclick = runWifiWwwProbe;
          var exportWrap = document.getElementById("lan-export-source-wrap");
          if (exportWrap && exportWrap.classList.contains("is-active")) {
            setMediaMaintenanceEnabled(false);
          }
          function uuid() {
            return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function (c) {
              var r = Math.random() * 16 | 0, v = c === "x" ? r : (r & 0x3 | 0x8);
              return v.toString(16);
            });
          }
          function putTrigger(body) {
            return fetch("\(LANExportTriggerControl.triggerRelativePath)", {
              method: "PUT",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify(body),
              cache: "no-store"
            }).then(function (r) {
              if (!r.ok) throw new Error("trigger HTTP " + r.status);
            });
          }
          function queueParkedResume(btn) {
            if (!btn) return;
            var href = (btn.getAttribute("data-href") || "").trim();
            var name = (btn.getAttribute("data-name") || "").trim();
            var folder = (btn.getAttribute("data-folder-path") || "").trim();
            var seekMs = parseInt(btn.getAttribute("data-seek-ms") || "0", 10) || 0;
            var body = { version: 1, command: "start_export", displayName: name, seekMs: seekMs, id: uuid() };
            if (href) body.href = href;
            if (folder) body.folderPath = folder;
            if (!href && !folder && !name) return;
            putTrigger(body).catch(function () {});
          }
          var playbackFiles = document.getElementById("lan-playback-files");
          if (playbackFiles) {
            playbackFiles.onclick = function (ev) {
              var parkedBtn = ev.target.closest ? ev.target.closest(".export-parked") : null;
              if (!parkedBtn && ev.target.classList && ev.target.classList.contains("export-parked")) {
                parkedBtn = ev.target;
              }
              if (parkedBtn) queueParkedResume(parkedBtn);
            };
          }
          var pausedList = document.getElementById("lan-paused-list");
          if (pausedList) {
            pausedList.onclick = function (ev) {
              var parkedBtn = ev.target.closest ? ev.target.closest(".export-parked") : null;
              if (!parkedBtn && ev.target.classList && ev.target.classList.contains("export-parked")) {
                parkedBtn = ev.target;
              }
              if (parkedBtn) queueParkedResume(parkedBtn);
            };
          }
          var resumeBtn = document.getElementById("export-resume");
          if (resumeBtn) {
            resumeBtn.onclick = function () {
              putTrigger({ version: 1, command: "resume_export", id: uuid() }).catch(function () {});
            };
          }
          \(htmlPendingQueueClientHelpersJS())
          wirePendingQueue();
        })();
        </script>
        """
    }

    /// Lightweight monitor at `/` (playback + logs + resume when paused). No embedded pCloud browser.
    /// Shared light/night CSS + Day/Night toggle script for `/` and `/browse`.
    static func htmlLANAppearanceHeadBits() -> String {
        let appNight = AppearanceSettings.isNightModeEnabled
        let htmlClass = appNight ? "night" : ""
        let defaultAttr = appNight ? "1" : "0"
        return """
            <html lang="en" class="\(htmlClass)" data-night-default="\(defaultAttr)"><head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="color-scheme" content="dark light">
            <meta http-equiv="x-dns-prefetch-control" content="off">
            <style>
            :root {
              color-scheme: light dark;
              --bg: #f6f7f9;
              --fg: #1a1a1a;
              --muted: #666;
              --panel-bg: #ffffff;
              --panel-border: #ccc;
              --banner-bg: #e8f4fd;
              --banner-border: #5b9bd5;
              --banner-fg: #0d3a5c;
              --source-bg: #f5f8ff;
              --source-border: #c5d4f0;
              --source-active-bg: #fffbea;
              --source-active-border: #c8a415;
              --source-paused-bg: #fff5f0;
              --source-paused-border: #d08050;
              --scroll-bg: #fafafa;
              --scroll-border: #ddd;
              --pin-bg: #fffbea;
              --pin-border: #c8a415;
              --pin-fg: #c8a415;
              --link: #0b57d0;
              --btn-bg: #efefef;
              --btn-border: #bbb;
              --err: #b00020;
              --ok: #333;
              --input-bg: #fff;
              --input-border: #ccc;
            }
            html.night {
              color-scheme: dark;
              --bg: #121418;
              --fg: #e8eaed;
              --muted: #9aa0a6;
              --panel-bg: #1c1f26;
              --panel-border: #3c4048;
              --banner-bg: #1a3050;
              --banner-border: #3d6fa5;
              --banner-fg: #cfe3f7;
              --source-bg: #1a2438;
              --source-border: #3a4f75;
              --source-active-bg: #3a3218;
              --source-active-border: #c8a415;
              --source-paused-bg: #3a2418;
              --source-paused-border: #d08050;
              --scroll-bg: #181b22;
              --scroll-border: #3c4048;
              --pin-bg: #3a3218;
              --pin-border: #c8a415;
              --pin-fg: #e0c060;
              --link: #8ab4f8;
              --btn-bg: #2a2f38;
              --btn-border: #5f6368;
              --err: #ff8a80;
              --ok: #c8cdd3;
              --input-bg: #0f1115;
              --input-border: #5f6368;
            }
            body { font: -apple-system-body; margin: 1.25rem; line-height: 1.4; background: var(--bg); color: var(--fg); }
            a { color: var(--link); }
            code { font-size: 0.9em; }
            ul { padding-left: 1.25rem; }
            .lan-topbar { display: flex; flex-wrap: wrap; gap: 0.75rem; align-items: center; justify-content: space-between; margin: 0 0 0.75rem; }
            .lan-topbar h1 { margin: 0; font-size: 1.35rem; }
            .export-source-line { margin: 0.75rem 0 1rem; padding: 0.65rem 0.85rem; background: var(--source-bg); border: 1px solid var(--source-border); border-radius: 8px; display: flex; flex-wrap: wrap; gap: 0.65rem; align-items: center; justify-content: space-between; }
            .export-source-line.is-active { background: var(--source-active-bg); border-color: var(--source-active-border); }
            .export-source-line.is-paused { background: var(--source-paused-bg); border-color: var(--source-paused-border); }
            .export-source-main { flex: 1 1 12rem; min-width: 0; }
            .export-source-actions { display: flex; flex-wrap: wrap; gap: 0.5rem; flex-shrink: 0; }
            .export-source-line #lan-export-source-name { word-break: break-all; }
            .export-pending-banner { margin: 0.75rem 0 1rem; padding: 0.75rem 1rem; background: var(--banner-bg); border: 1px solid var(--banner-border); border-radius: 8px; color: var(--banner-fg); }
            .export-pending-banner strong { display: block; margin-bottom: 0.25rem; font-size: 1.05em; }
            .export-pending-banner span { font-size: 0.95em; line-height: 1.45; }
            .panel { border: 1px solid var(--panel-border); border-radius: 8px; padding: 1rem; margin: 1rem 0; background: var(--panel-bg); }
            .row { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; margin: 0.5rem 0; }
            button, .btn { font: inherit; padding: 0.35rem 0.65rem; cursor: pointer; background: var(--btn-bg); color: var(--fg); border: 1px solid var(--btn-border); border-radius: 6px; }
            a.btn { display: inline-block; text-decoration: none; color: var(--fg); }
            .lan-xr-links { display: flex; flex-wrap: wrap; gap: 0.5rem; margin: 0.35rem 0 0.75rem; }
            .lan-tunnel-row {
              display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center;
              margin: 0.35rem 0 0.75rem; max-width: 56rem;
            }
            .lan-tunnel-row label { display: flex; flex-wrap: wrap; gap: 0.4rem; align-items: center; flex: 1 1 16rem; }
            .lan-tunnel-row #lan-tunnel-domain { flex: 1 1 14rem; min-width: 12rem; font-family: ui-monospace, monospace; font-size: 0.9em; }
            .lan-tunnel-row #lan-tunnel-status { flex: 1 1 100%; }
            a.btn[data-lan-tunnel-active="1"] { border-color: #166534; }
            .lan-quest-flags {
              margin: 0.25rem 0 0.85rem; padding: 0.75rem 0.85rem; max-width: 56rem;
              border: 1px solid var(--panel-border); border-radius: 8px; background: var(--panel-bg);
            }
            .lan-quest-flags h3 { margin: 0 0 0.35rem; font-size: 1rem; }
            .lan-quest-flags p { margin: 0.35rem 0; font-size: 0.9em; line-height: 1.4; }
            .lan-quest-flags .lan-flag-row {
              display: flex; flex-wrap: wrap; gap: 0.45rem; align-items: center; margin: 0.45rem 0;
            }
            .lan-quest-flags input[readonly] {
              flex: 1 1 14rem; min-width: 12rem; font-family: ui-monospace, monospace; font-size: 0.85em;
            }
            .lan-quest-flags ol { margin: 0.35rem 0 0; padding-left: 1.25rem; font-size: 0.9em; line-height: 1.45; }
            button:disabled, .btn:disabled { opacity: 0.55; cursor: not-allowed; }
            input[type="text"], input[type="url"], input[type="search"], select, textarea {
              background: var(--input-bg); color: var(--fg); border: 1px solid var(--input-border); border-radius: 6px; padding: 0.35rem 0.5rem;
            }
            .pcloud-folders { display: flex; flex-wrap: wrap; gap: 0.5rem; margin: 0.5rem 0; }
            .pcloud-folders .pcloud-dir { flex: 1 1 9rem; max-width: 14rem; text-align: left; }
            .pcloud-pinned-wrap { margin: 0.25rem 0 0.75rem; }
            .pcloud-pinned-wrap .label { margin-bottom: 0.25rem; font-size: 0.9em; color: var(--muted); }
            .pcloud-pinned .pcloud-dir { border: 1px solid var(--pin-border); background: var(--pin-bg); }
            .folder-item { display: flex; flex: 1 1 9rem; max-width: 14rem; align-items: stretch; }
            .folder-item .pcloud-dir { flex: 1; max-width: none; border-top-right-radius: 0; border-bottom-right-radius: 0; }
            .pin-toggle { border-top-left-radius: 0; border-bottom-left-radius: 0; padding: 0.35rem 0.5rem; min-width: 2rem; }
            .pin-toggle.pinned { color: var(--pin-fg); }
            #pcloud-files { list-style: none; padding-left: 0; margin: 0.5rem 0; }
            #pcloud-files li { margin: 0.35rem 0; display: flex; flex-wrap: wrap; gap: 0.35rem; align-items: baseline; }
            .file-meta { color: var(--muted); font-size: 0.85em; }
            .muted { color: var(--muted); font-size: 0.9em; }
            .lan-playback-section { display: flex; flex-direction: column; }
            .lan-playback-media { order: 1; margin: 0 0 0.25rem; }
            .lan-playback-media ul { margin: 0; padding-left: 1.25rem; }
            .lan-playback-logs-block { order: 2; margin: 0; }
            .lan-playback-subhead { margin: 1rem 0 0.35rem; font-size: 1em; font-weight: 600; }
            .lan-playback-logs-scroll {
              max-height: calc(5 * 1.75lh);
              overflow-x: auto;
              overflow-y: auto;
              -webkit-overflow-scrolling: touch;
              overscroll-behavior: contain;
              margin: 0 0 0.5rem;
              padding: 0.2rem 0.4rem 0.2rem 0;
              border: 1px solid var(--scroll-border);
              border-radius: 6px;
              background: var(--scroll-bg);
            }
            .lan-playback-logs-scroll ul { margin: 0; padding-left: 1.25rem; }
            #lan-export-logs li { word-break: break-all; }
            #trigger-status { min-height: 1.2em; }
            .lan-pending-queue { margin: 0.75rem 0 1rem; }
            .lan-pending-queue > summary,
            .lan-paused-exports > summary {
              cursor: pointer;
              font-size: 1.17em;
              font-weight: 600;
            }
            .lan-pending-queue ul,
            .lan-paused-exports ul { margin: 0.25rem 0 0.5rem; padding-left: 1.25rem; }
            .lan-pending-queue .pending-name,
            .lan-paused-exports .pending-name { font-weight: 600; }
            .lan-pending-queue .pending-remove { margin-left: 0.45rem; }
            #lan-pending-queue-actions,
            #lan-paused-actions { margin: 0.25rem 0 0.35rem; }
            .lan-paused-exports { margin: 0.75rem 0 1rem; }
            .lan-loop-player { margin: 0.75rem 0 1rem; }
            .lan-loop-player video {
              display: block; width: 100%; max-width: 56rem; max-height: 50vh;
              background: #000; border-radius: 6px;
            }
            .lan-loop-player .lan-loop-toolbar {
              display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; margin: 0.5rem 0 0;
            }
            .lan-loop-player #lan-loop-label { font-size: 0.9em; word-break: break-all; }
            </style>
            <script>
            (function () {
              var KEY = "loopsegments-lan-night";
              function readNight() {
                var stored = null;
                try { stored = localStorage.getItem(KEY); } catch (e) {}
                if (stored === null) {
                  return document.documentElement.getAttribute("data-night-default") !== "0";
                }
                return stored === "1";
              }
              var night = readNight();
              function apply() {
                document.documentElement.classList.toggle("night", night);
                var btn = document.getElementById("lan-night-toggle");
                if (btn) btn.textContent = night ? "Day mode" : "Night mode";
              }
              window.__lanSetNight = function (v) {
                night = !!v;
                try { localStorage.setItem(KEY, night ? "1" : "0"); } catch (e) {}
                apply();
              };
              window.__lanToggleNight = function () { window.__lanSetNight(!night); };
              window.__lanStatusColor = function (isErr) {
                return isErr ? getComputedStyle(document.documentElement).getPropertyValue("--err").trim() || "#b00020"
                  : getComputedStyle(document.documentElement).getPropertyValue("--ok").trim() || "#333";
              };
              apply();
              document.addEventListener("DOMContentLoaded", apply);
            })();
            </script>
            """
    }

    static func htmlLANNightModeToggleButton() -> String {
        """
        <button type="button" id="lan-night-toggle" onclick="__lanToggleNight()">Night mode</button>
        """
    }

    /// Quest Browser: chrome://flags insecure-origin helper + this LAN origin to paste.
    static func htmlLANQuestFlagsBlock() -> String {
        let flagHash = "unsafely-treat-insecure-origin-as-secure"
        let flagsUrl = "chrome://flags/#\(flagHash)"
        let flagsEscaped = htmlEscape(flagsUrl)
        return """
        <details class="lan-quest-flags panel" id="lan-quest-flags" style="margin:0.75rem 0 1rem">
          <summary><strong>Quest Browser — LAN HTTP as secure</strong> <span class="muted">(required for Quest WebXR over LAN HTTP)</span></summary>
          <p class="muted" style="margin-top:0.5rem">Quest WebXR needs a secure context. Use this flag so LAN <code>http://</code> counts as secure (no www hop). Skip only if you use the Cloudflare HTTPS tunnel at the bottom instead.</p>
          <div class="lan-flag-row">
            <a class="btn" id="lan-flags-open" href="\(flagsEscaped)" target="_blank" rel="noopener">Open chrome://flags (new tab)</a>
            <button type="button" id="lan-flags-copy-url" title="Copy chrome://flags URL">Copy flags URL</button>
          </div>
          <div class="lan-flag-row">
            <label for="lan-flags-setting">Flag
              <input type="text" id="lan-flags-setting" readonly value="\(htmlEscape(flagHash))" spellcheck="false">
            </label>
            <button type="button" id="lan-flags-copy-setting">Copy flag name</button>
          </div>
          <div class="lan-flag-row">
            <label for="lan-flags-origin">LAN origin (paste into the flag)
              <input type="text" id="lan-flags-origin" readonly value="" spellcheck="false" aria-live="polite">
            </label>
            <button type="button" id="lan-flags-copy-origin">Copy LAN origin</button>
          </div>
          <ol>
            <li>On <strong>Quest Browser</strong>, open the flags link (or type <code>chrome://flags</code> in the address bar).</li>
            <li>Find <strong>Insecure origins treated as secure</strong> (<code>\(htmlEscape(flagHash))</code>).</li>
            <li>Paste the <strong>LAN origin</strong> above (scheme + host + port, e.g. <code>http://10.0.100.10:8765</code>) — exact match.</li>
            <li>Set Enabled → Relaunch → open this LAN page again → <strong>Open XR chroma</strong> over <strong>http://</strong> → <strong>Enter AR</strong>.</li>
          </ol>
          <p id="lan-flags-status" class="muted" role="status"></p>
        </details>
        """
    }

    static func htmlLANQuestFlagsScript() -> String {
        """
        <script>
        (function () {
          var FLAG_URL = "chrome://flags/#unsafely-treat-insecure-origin-as-secure";
          var FLAG_NAME = "unsafely-treat-insecure-origin-as-secure";
          var originInput = document.getElementById("lan-flags-origin");
          var status = document.getElementById("lan-flags-status");
          var openBtn = document.getElementById("lan-flags-open");
          function setStatus(msg) {
            if (status) status.textContent = msg || "";
          }
          function lanOrigin() {
            try {
              return String(location.origin || "");
            } catch (e) {
              return "";
            }
          }
          function fillOrigin() {
            if (!originInput) return;
            originInput.value = lanOrigin();
          }
          function copyText(text, okMsg) {
            text = String(text || "");
            if (!text) {
              setStatus("Nothing to copy");
              return;
            }
            function done() { setStatus(okMsg || ("Copied: " + text)); }
            if (navigator.clipboard && navigator.clipboard.writeText) {
              navigator.clipboard.writeText(text).then(done).catch(function () {
                try {
                  originInput.focus();
                  originInput.select();
                  document.execCommand("copy");
                  done();
                } catch (e) {
                  setStatus("Copy failed — select the field manually");
                }
              });
            } else {
              try {
                var ta = document.createElement("textarea");
                ta.value = text;
                document.body.appendChild(ta);
                ta.select();
                document.execCommand("copy");
                document.body.removeChild(ta);
                done();
              } catch (e) {
                setStatus("Copy failed — select the field manually");
              }
            }
          }
          fillOrigin();
          var copyOrigin = document.getElementById("lan-flags-copy-origin");
          var copySetting = document.getElementById("lan-flags-copy-setting");
          var copyFlags = document.getElementById("lan-flags-copy-url");
          if (copyOrigin) copyOrigin.addEventListener("click", function () {
            fillOrigin();
            copyText(originInput && originInput.value, "Copied LAN origin");
          });
          if (copySetting) copySetting.addEventListener("click", function () {
            copyText(FLAG_NAME, "Copied flag name");
          });
          if (copyFlags) copyFlags.addEventListener("click", function () {
            copyText(FLAG_URL, "Copied chrome://flags URL — paste into Quest address bar if the link is blocked");
          });
          if (openBtn) {
            openBtn.addEventListener("click", function (ev) {
              // Some browsers block chrome:// from http pages; keep href for Quest when allowed.
              setStatus("If the new tab did not open, paste chrome://flags into the Quest address bar");
            });
          }
        })();
        </script>
        """
    }

    /// Optional Cloudflare HTTPS tunnel — keep at page bottom (after playback/logs).
    static func htmlLANCloudflareTunnelBlock() -> String {
        """
        <details class="lan-cf-tunnel-advanced panel" id="lan-cf-tunnel-advanced" style="margin-top:1.5rem">
          <summary><strong>Advanced — Cloudflare HTTPS tunnel</strong> <span class="muted">(optional / slow www hop; prefer Quest flags + LAN HTTP above)</span></summary>
          <p class="muted" style="margin-top:0.5rem">Only if the insecure-origin flag is unavailable. Paste a quick-tunnel host from <code>Start-LoopSegmentsCloudflareTunnel.ps1</code>, then <strong>Update links</strong> so XR buttons open <code>https://…/xr</code> (stored on phone as <code>xr_tunnel.json</code>).</p>
          <p class="lan-tunnel-row">
            <label for="lan-tunnel-domain">Tunnel host
              <input type="text" id="lan-tunnel-domain" placeholder="xxxx.trycloudflare.com or full https://… URL" spellcheck="false" autocomplete="off" inputmode="url" aria-describedby="lan-tunnel-status">
            </label>
            <button type="button" id="lan-tunnel-apply">Update links</button>
            <button type="button" id="lan-tunnel-clear">Clear</button>
            <span id="lan-tunnel-status" class="muted" role="status"></span>
          </p>
        </details>
        \(htmlLANTunnelDomainScript())
        """
    }

    /// Paste Cloudflare quick-tunnel host; rewrite `[data-lan-tunnel-path]` links to `https://host…`.
    /// Persists to phone `xr_tunnel.json` so Quest refresh sees the same host after a PC Update links.
    static func htmlLANTunnelDomainScript() -> String {
        let user = lanWebDAVUsername
        let pass = lanWebDAVPassword
        return """
        <script>
        (function () {
          var ENDPOINT = "xr_tunnel.json";
          var AUTH = "Basic " + btoa("\(user):\(pass)");
          var input = document.getElementById("lan-tunnel-domain");
          var applyBtn = document.getElementById("lan-tunnel-apply");
          var clearBtn = document.getElementById("lan-tunnel-clear");
          var status = document.getElementById("lan-tunnel-status");
          if (!input || !applyBtn) return;

          function setStatus(msg) {
            if (status) status.textContent = msg || "";
          }
          function tunnelLinks() {
            return document.querySelectorAll("a[data-lan-tunnel-path]");
          }
          function parseHost(raw) {
            var s = String(raw || "").trim();
            if (!s) return "";
            s = s.replace(/\\s+/g, "");
            if (!/^https?:\\/\\//i.test(s)) s = "https://" + s;
            try {
              var u = new URL(s);
              if (!u.hostname) return "";
              return u.host;
            } catch (e) {
              return "";
            }
          }
          function applyHost(host) {
            host = String(host || "").trim();
            tunnelLinks().forEach(function (a) {
              var path = a.getAttribute("data-lan-tunnel-path") || "/xr";
              if (path.charAt(0) !== "/") path = "/" + path;
              if (host) {
                a.href = "https://" + host + path;
                a.setAttribute("data-lan-tunnel-active", "1");
                a.setAttribute("title", a.href);
              } else {
                a.href = path;
                a.removeAttribute("data-lan-tunnel-active");
                a.setAttribute("title", path);
              }
            });
            if (host) {
              setStatus("XR links → https://" + host + "/xr… (saved on phone — refresh Quest to pick up)");
            } else {
              setStatus("XR links use this LAN origin (http) — phone tunnel cleared");
            }
          }
          function saveHost(host) {
            setStatus(host ? "Saving tunnel host on phone…" : "Clearing tunnel host on phone…");
            return fetch(ENDPOINT, {
              method: "POST",
              headers: {
                "Authorization": AUTH,
                "Content-Type": "application/json"
              },
              body: JSON.stringify({ host: host || "" }),
              cache: "no-store"
            }).then(function (r) {
              return r.text().then(function (t) {
                var j = null;
                try { j = JSON.parse(t); } catch (e) {}
                if (!r.ok) {
                  throw new Error((j && (j.error || j.message)) || t || ("HTTP " + r.status));
                }
                return j;
              });
            }).then(function (j) {
              var h = parseHost((j && j.host) || host || "");
              input.value = h;
              applyHost(h);
              return h;
            }).catch(function (e) {
              setStatus("Could not save on phone: " + ((e && e.message) ? e.message : String(e)));
            });
          }
          function applyFromInput() {
            var host = parseHost(input.value);
            if (input.value.trim() && !host) {
              setStatus("Could not parse domain — paste xxxx.trycloudflare.com or https://…");
              return;
            }
            input.value = host;
            applyHost(host);
            saveHost(host);
          }
          applyBtn.addEventListener("click", applyFromInput);
          input.addEventListener("keydown", function (ev) {
            if (ev.key === "Enter") {
              ev.preventDefault();
              applyFromInput();
            }
          });
          if (clearBtn) {
            clearBtn.addEventListener("click", function () {
              input.value = "";
              applyHost("");
              saveHost("");
            });
          }
          setStatus("Loading tunnel host from phone…");
          fetch(ENDPOINT, { cache: "no-store" })
            .then(function (r) { return r.json(); })
            .then(function (j) {
              var h = parseHost((j && j.host) || "");
              input.value = h;
              applyHost(h);
            })
            .catch(function () {
              applyHost("");
              setStatus("No tunnel host on phone yet — paste trycloudflare host → Update links");
            });
        })();
        </script>
        """
    }

    /// Toggle + hidden-by-default HTML5 player for `pcld_ios_media/loop/op_*.mp4`.
    static func htmlLANLoopPlayerBlock() -> String {
        let loopPrefix = "\(ExportPaths.mediaExportFolderName)/\(ExportPaths.segmentLoopFolderName)/"
        return """
        <p>
          <button type="button" id="lan-loop-player-toggle">Show loop player</button>
        </p>
        <div id="lan-loop-player" class="lan-loop-player panel" style="display:none" hidden>
          <div class="row" style="margin-top:0">
            <strong>Loop folder player</strong>
            <span class="muted">Cycles <code>\(htmlEscape(loopPrefix))op_*.mp4</code> · rate applies to every segment</span>
          </div>
          <video id="lan-loop-video" controls playsinline preload="metadata"></video>
          <div class="lan-loop-toolbar">
            <button type="button" id="lan-loop-prev" title="Previous segment">Prev</button>
            <button type="button" id="lan-loop-play">Play</button>
            <button type="button" id="lan-loop-next" title="Next segment">Next</button>
            <label>Speed
              <select id="lan-loop-rate" aria-label="Playback speed">
                <option value="0.7">0.7×</option>
                <option value="0.8">0.8×</option>
                <option value="0.9">0.9×</option>
                <option value="1" selected>1×</option>
                <option value="1.1">1.1×</option>
                <option value="1.2">1.2×</option>
                <option value="1.3">1.3×</option>
              </select>
            </label>
            <span id="lan-loop-label" class="muted" role="status">Hidden — tap Show loop player</span>
          </div>
        </div>
        <p class="lan-xr-links">
          <a class="btn" href="/xr#loop" id="lan-xr-chroma-link" data-lan-tunnel-path="/xr#loop">Open XR chroma (loop)</a>
          <a class="btn" href="/xr#working" id="lan-xr-working-link" data-lan-tunnel-path="/xr#working">Open XR chroma (working)</a>
          <a class="btn" href="/xr#archive" id="lan-xr-archive-link" data-lan-tunnel-path="/xr#archive">Open XR chroma (archive)</a>
        </p>
        \(htmlLANQuestFlagsBlock())
        \(htmlLANQuestFlagsScript())
        \(htmlLANLoopPlayerScript(loopPrefix: loopPrefix))
        """
    }

    static func htmlLANLoopPlayerScript(loopPrefix: String) -> String {
        let prefixJS = loopPrefix.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        <script>
        (function () {
          var LOOP_PREFIX = "\(prefixJS)";
          var RATE_KEY = "loopsegments.lan.loopPlayerRate.v1";
          var RATES = [0.7, 0.8, 0.9, 1, 1.1, 1.2, 1.3];
          var playlist = [];
          var index = 0;
          var visible = false;
          var wantPlay = false;
          var video = document.getElementById("lan-loop-video");
          var panel = document.getElementById("lan-loop-player");
          var toggleBtn = document.getElementById("lan-loop-player-toggle");
          var playBtn = document.getElementById("lan-loop-play");
          var prevBtn = document.getElementById("lan-loop-prev");
          var nextBtn = document.getElementById("lan-loop-next");
          var rateSel = document.getElementById("lan-loop-rate");
          var label = document.getElementById("lan-loop-label");
          if (!video || !panel || !toggleBtn) return;

          function setLabel(msg) {
            if (label) label.textContent = msg || "";
          }
          function snapRate(v) {
            var r = Math.round(Number(v) * 10) / 10;
            if (!isFinite(r)) return 1;
            for (var i = 0; i < RATES.length; i++) {
              if (Math.abs(RATES[i] - r) < 0.001) return RATES[i];
            }
            return 1;
          }
          function readRate() {
            var v = 1;
            try {
              var raw = localStorage.getItem(RATE_KEY);
              if (raw != null) v = parseFloat(raw);
            } catch (e) {}
            return snapRate(v);
          }
          function writeRate(v) {
            try { localStorage.setItem(RATE_KEY, String(snapRate(v))); } catch (e) {}
          }
          function applyRate() {
            var v = readRate();
            if (rateSel) rateSel.value = String(v);
            try { video.playbackRate = v; } catch (e) {}
          }
          function isLoopSegmentName(name) {
            var n = String(name || "").replace(/\\\\/g, "/");
            if (n.indexOf(LOOP_PREFIX) !== 0) return false;
            var base = n.slice(LOOP_PREFIX.length);
            if (!base || base.indexOf("/") >= 0) return false;
            if (/staging/i.test(base)) return false;
            return /^op_\\d+\\.(mp4|m4v|mov)$/i.test(base);
          }
          function cacheBust(entry) {
            var q = [];
            if (entry.bytes) q.push("b=" + encodeURIComponent(String(entry.bytes)));
            if (entry.modified) q.push("m=" + encodeURIComponent(String(entry.modified)));
            return q.length ? ("?" + q.join("&")) : "";
          }
          function buildPlaylistFromFiles(files) {
            var list = Array.isArray(files) ? files : [];
            var out = [];
            var seen = {};
            list.forEach(function (f) {
              var name = f && f.name;
              if (!isLoopSegmentName(name)) return;
              if (seen[name]) return;
              seen[name] = true;
              out.push({
                name: name,
                bytes: Number(f.bytes) || 0,
                modified: f.modified || "",
                url: "/" + String(name).replace(/^\\/+/, "") + cacheBust(f)
              });
            });
            out.sort(function (a, b) { return a.name < b.name ? -1 : a.name > b.name ? 1 : 0; });
            if (!out.length) {
              ["op_00.mp4", "op_01.mp4"].forEach(function (base) {
                var name = LOOP_PREFIX + base;
                out.push({ name: name, bytes: 0, modified: "", url: "/" + name });
              });
            }
            return out;
          }
          function stopPull() {
            wantPlay = false;
            try { video.pause(); } catch (e) {}
            try {
              video.removeAttribute("src");
              video.load();
            } catch (e) {}
            if (playBtn) playBtn.textContent = "Play";
          }
          function loadIndex(i, autoplay) {
            if (!playlist.length) {
              setLabel("No loop/op_*.mp4 yet");
              stopPull();
              return;
            }
            index = ((i % playlist.length) + playlist.length) % playlist.length;
            var item = playlist[index];
            wantPlay = !!autoplay;
            video.src = item.url;
            applyRate();
            setLabel((index + 1) + "/" + playlist.length + ": " + item.name);
            if (wantPlay) {
              var p = video.play();
              if (p && typeof p.catch === "function") {
                p.catch(function () { wantPlay = false; if (playBtn) playBtn.textContent = "Play"; });
              }
              if (playBtn) playBtn.textContent = "Pause";
            } else if (playBtn) {
              playBtn.textContent = "Play";
            }
          }
          function refreshPlaylist(files, keepPosition) {
            if (!visible) return;
            var prevName = playlist[index] && playlist[index].name;
            playlist = buildPlaylistFromFiles(files);
            if (!playlist.length) {
              setLabel("No loop/op_*.mp4 yet");
              return;
            }
            var next = 0;
            if (keepPosition && prevName) {
              for (var i = 0; i < playlist.length; i++) {
                if (playlist[i].name === prevName) { next = i; break; }
              }
            }
            var curSrc = video.currentSrc || video.src || "";
            var nextUrl = playlist[next].url;
            var sameFile = prevName && playlist[next] && playlist[next].name === prevName;
            var bustChanged = sameFile && curSrc && curSrc.indexOf(nextUrl) < 0 && nextUrl.indexOf("?") >= 0;
            if (!curSrc || !sameFile || bustChanged) {
              loadIndex(next, wantPlay && !video.paused);
            } else {
              index = next;
              setLabel((index + 1) + "/" + playlist.length + ": " + playlist[index].name);
              applyRate();
            }
          }
          window.refreshLANLoopPlaylist = function (files) {
            refreshPlaylist(files, true);
          };
          function showPlayer() {
            visible = true;
            panel.style.display = "";
            panel.removeAttribute("hidden");
            toggleBtn.textContent = "Hide loop player";
            setLabel("Loading loop playlist…");
            applyRate();
            fetch("status_lists.json", { cache: "no-store" })
              .then(function (r) { return r.json(); })
              .then(function (j) {
                refreshPlaylist(j && j.files, false);
                if (playlist.length) loadIndex(0, false);
              })
              .catch(function () {
                playlist = buildPlaylistFromFiles([]);
                loadIndex(0, false);
              });
          }
          function hidePlayer() {
            visible = false;
            stopPull();
            panel.style.display = "none";
            panel.setAttribute("hidden", "hidden");
            toggleBtn.textContent = "Show loop player";
            setLabel("Hidden — tap Show loop player");
          }
          toggleBtn.onclick = function () {
            if (visible) hidePlayer();
            else showPlayer();
          };
          if (playBtn) {
            playBtn.onclick = function () {
              if (!visible) return;
              if (!playlist.length) {
                setLabel("No loop/op_*.mp4 yet");
                return;
              }
              if (!video.src) {
                loadIndex(index, true);
                return;
              }
              if (video.paused) {
                wantPlay = true;
                var p = video.play();
                if (p && typeof p.catch === "function") p.catch(function () {});
                playBtn.textContent = "Pause";
              } else {
                wantPlay = false;
                video.pause();
                playBtn.textContent = "Play";
              }
            };
          }
          if (prevBtn) {
            prevBtn.onclick = function () {
              if (!visible || !playlist.length) return;
              loadIndex(index - 1, wantPlay || !video.paused);
            };
          }
          if (nextBtn) {
            nextBtn.onclick = function () {
              if (!visible || !playlist.length) return;
              loadIndex(index + 1, wantPlay || !video.paused);
            };
          }
          if (rateSel) {
            rateSel.value = String(readRate());
            rateSel.onchange = function () {
              var v = parseFloat(rateSel.value);
              if (!isFinite(v)) v = 1;
              writeRate(v);
              applyRate();
            };
          }
          video.addEventListener("ended", function () {
            if (!visible || !playlist.length) return;
            loadIndex(index + 1, true);
          });
          video.addEventListener("ratechange", function () {
            // Keep select in sync if browser UI changes rate.
            if (!rateSel) return;
            var v = snapRate(video.playbackRate);
            rateSel.value = String(v);
            writeRate(v);
          });
          video.addEventListener("play", function () {
            wantPlay = true;
            if (playBtn) playBtn.textContent = "Pause";
            applyRate();
          });
          video.addEventListener("pause", function () {
            if (playBtn && video.paused) playBtn.textContent = "Play";
          });
          video.addEventListener("error", function () {
            if (!visible) return;
            var item = playlist[index];
            setLabel("Could not load " + (item && item.name ? item.name : "segment")
              + (playlist.length > 1 ? " — try Next" : " (export segments first)"));
            if (playBtn) playBtn.textContent = "Play";
            wantPlay = false;
          });
        })();
        </script>
        """
    }

    /// Quest Browser WebXR page: 180° SBS + green-screen chroma over loop / media-root / `archive/` media.
    static func sendXRChromaPlayerHTML(_ connection: NWConnection, done: @escaping () -> Void) {
        autoreleasepool {
            let mediaRoot = "\(ExportPaths.mediaExportFolderName)/"
            let loopPrefix = "\(ExportPaths.mediaExportFolderName)/\(ExportPaths.segmentLoopFolderName)/"
            let archivePrefix = "\(ExportPaths.mediaExportFolderName)/archive/"
            let html = xrChromaPlayerHTML(
                mediaRoot: mediaRoot,
                loopPrefix: loopPrefix,
                archivePrefix: archivePrefix
            )
            sendResponse(
                connection: connection,
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: Data(html.utf8),
                done: done
            )
        }
    }

    static func xrChromaPlayerHTML(
        mediaRoot: String,
        loopPrefix: String,
        archivePrefix: String
    ) -> String {
        guard let template = XRPlayerAssets.html else {
            return "<!DOCTYPE html><title>Loop Segments</title><p>The XR player files are missing from this app build.</p>"
        }
        // Values the page needs, as JSON for the bundled xr-app.js. "\/" keeps "</" out of the inline script.
        let config = ["mediaRoot": mediaRoot, "loopPrefix": loopPrefix, "archivePrefix": archivePrefix]
        var configJSON = "{}"
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            configJSON = text.replacingOccurrences(of: "</", with: "<\\/")
        }
        return template
            .replacingOccurrences(of: "{{XR_CONFIG_JSON}}", with: configJSON)
            .replacingOccurrences(of: "{{XR_MEDIA_ROOT_HTML}}", with: htmlEscape(mediaRoot))
            .replacingOccurrences(of: "{{XR_BUILD}}", with: XRPlayerAssets.version)
    }

    /// The /xr page lives in bundled files: xr-player.html (markup + CSS), xr-components.js
    /// (A-Frame components) and xr-app.js (page logic). Edit those, not this file.
    enum XRPlayerAssets {
        static let html = load("xr-player", "html")
        static let componentsJS = load("xr-components", "js")
        static let appJS = load("xr-app", "js")
        /// A-Frame 1.6.0, bundled so /xr works without internet (see aframe-LICENSE.txt).
        static let aframeJS = load("aframe.min", "js")
        /// Script URLs carry the build so the headset fetches fresh files after an app update.
        static let version = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"

        private static func load(_ name: String, _ ext: String) -> String? {
            guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    static func xrPlayerScript(path: String) -> String? {
        switch path {
        case "xr-assets/xr-components.js": return XRPlayerAssets.componentsJS
        case "xr-assets/xr-app.js": return XRPlayerAssets.appJS
        case "xr-assets/aframe.min.js": return XRPlayerAssets.aframeJS
        default: return nil
        }
    }

    static func sendMinimalIndexHTML(_ connection: NWConnection, done: @escaping () -> Void) {
        autoreleasepool {
            let exportActive = ExportPlaybackState.shared.isLANExportActive
            let playbackStatusInitial = exportActive
                ? htmlPlaybackStatusLiveShell()
                : htmlPlaybackStatusShell()
            let html = """
                <!DOCTYPE html>
                \(htmlLANAppearanceHeadBits())
                <title>Loop Segments — LAN monitor</title>
                </head><body>
                <div class="lan-topbar">
                  <h1>Loop Segments — LAN monitor</h1>
                  \(htmlLANNightModeToggleButton())
                </div>
                <p><a href="/browse">Open pCloud browser &amp; export controls</a> · \(htmlMonitorQuickLogLinks())</p>
                <div id="lan-export-pending" class="export-pending-banner" style="display:none" role="status">
                  <strong id="lan-export-pending-title">Processing export request</strong>
                  <span id="lan-export-pending-detail">Keep Loop Segments open in the foreground on the phone.</span>
                </div>
                \(htmlExportSourceLineShell())
                \(htmlPendingQueueSection())
                \(htmlPausedExportsSection())
                <div id="lan-playback-status">\(playbackStatusInitial)</div>
                <p class="muted">No auto-refresh (tap buttons). Use direct log link while export runs.</p>
                <p>
                  <button type="button" id="lan-refresh-status">Refresh status</button>
                  <button type="button" id="lan-refresh-lists">Refresh file list</button>
                  <button type="button" id="lan-wifi-www-probe">Probe Phone Wi‑Fi → www</button>
                  <button type="button" id="lan-speed-test">LAN speed test</button>
                </p>
                <p id="lan-wifi-www-probe-result" class="muted" role="status"></p>
                <p id="lan-speed-test-result" class="muted" role="status"></p>
                \(htmlLANSpeedTestScript(resultElementId: "lan-speed-test-result", buttonId: "lan-speed-test"))
                \(htmlLANLoopPlayerBlock())
                <h2>On phone (playback)</h2>
                <ul id="lan-playback-files">
                \(htmlMonitorStaticPlaybackLinks())
                </ul>
                <h3>Export logs (newest first)</h3>
                <div class="lan-playback-logs-scroll"><ul id="lan-export-logs">
                \(exportActive ? htmlLANMinimalExportLogLinks() : exportLogsFileListHTML())
                </ul></div>
                \(htmlLANCloudflareTunnelBlock())
                \(htmlMonitorManualRefreshScript())
                </body></html>
                """
            sendResponse(
                connection: connection,
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: Data(html.utf8),
                done: done
            )
        }
    }

    /// Full LAN page with pCloud folder browser — use `/browse` during large exports.
    static func sendBrowseIndexHTML(_ connection: NWConnection, done: @escaping () -> Void) {
        let exportActive = ExportPlaybackState.shared.isLANExportActive
        if !exportActive {
        refreshLANMetricsBeforeStatusResponse()
        }
        let playbackStatusBlock = exportActive ? htmlPlaybackStatusLiveShell() : playbackStatusHTMLBlock()
        let mediaList: String
        let logList: String
        if exportActive {
            mediaList = "<li><em>File list deferred during export — tap Refresh file list or use WebDAV.</em></li>"
            logList = htmlLANMinimalExportLogLinks()
        } else {
            mediaList = playbackMediaFileListHTML()
            logList = exportLogsFileListHTML()
        }
        let html = """
            <!DOCTYPE html>
            \(htmlLANAppearanceHeadBits())
            <title>Loop Segments — LAN export</title>
            </head><body>
            <div class="lan-topbar">
              <h1>Loop Segments — LAN export</h1>
              \(htmlLANNightModeToggleButton())
            </div>
            <div id="lan-export-pending" class="export-pending-banner" style="display:none" role="status" aria-live="polite">
              <strong id="lan-export-pending-title">Processing export request</strong>
              <span id="lan-export-pending-detail">Please wait — keep Loop Segments open in the foreground on the phone.</span>
            </div>
            \(htmlExportSourceLineBlock())
            \(htmlPendingQueueSection())
            \(htmlPausedExportsSection())
            <p>Serving on port \(defaultPort): logs and media under <code>pcld_ios_media/</code> (private on phone, not in Files app). Legacy URLs <code>/export_latest.txt</code>, <code>/logs/export_*.txt</code>, and <code>/loop_segments_ok.txt</code> still work.</p>
            <p>JSON: \(htmlMonitorQuickLogLinks())</p>
            <p>PC: <code>Mount-LoopSegmentsRclone.ps1</code> (maps <code>pcld_ios_media/</code> and logs).</p>
            <p><strong>Playback:</strong> <code>pcld_ios_media/loop/op_00.mp4</code> / <code>pcld_ios_media/loop/op_01.mp4</code> (DLNA can loop the <code>loop/</code> folder). In-progress: <code>_working.mp4</code> (sparse original) or <code>_working_pcloud_transcode.mp4</code> (pCloud HLS transcode — labeled on index when active).</p>
            <div id="lan-playback-status">\(playbackStatusBlock)</div>
            \(exportActive ? """
            <p class="muted">Auto-refresh off during export (tap Refresh or use <a href="/">monitor</a>).</p>
            <p>
              <button type="button" id="lan-refresh-status">Refresh status</button>
              <button type="button" id="lan-refresh-lists">Refresh file list</button>
              <button type="button" id="lan-wifi-www-probe">Probe Phone Wi‑Fi → www</button>
            </p>
            <p id="lan-wifi-www-probe-result" class="muted" role="status"></p>
            """ : "")
            \(htmlLANLoopPlayerBlock())
            <h2>On phone (playback)</h2>
            <div class="lan-playback-section">
            <div id="lan-playback-media" class="lan-playback-media">
            <ul id="lan-playback-files">
            \(mediaList)
            </ul>
            </div>
            <div id="lan-playback-logs" class="lan-playback-logs-block">
            <h3 class="lan-playback-subhead">Export logs (newest first)</h3>
            <div class="lan-playback-logs-scroll" aria-label="Export log files">
            <ul id="lan-export-logs">
            \(logList)
            </ul>
            </div>
            </div>
            </div>
            \(htmlLANSpeedTestScript())
            \(htmlExportControlPanel())
            \(htmlURLDownloadPanel())
            \(htmlLANCloudflareTunnelBlock())
            \(exportActive
                ? htmlMonitorManualRefreshScript()
                : htmlLANLiveRefreshScript(monitorOnly: false, deferAutoPoll: false))
            </body></html>
            """
        sendResponse(
            connection: connection,
            status: 200,
            contentType: "text/html; charset=utf-8",
            body: Data(html.utf8),
            done: done
        )
    }

    static func htmlURLDownloadPanel() -> String {
        let user = htmlEscape(lanWebDAVUsername)
        let pass = htmlEscape(lanWebDAVPassword)
        return """
        <div class="panel">
        <h2>Export from URL</h2>
        <p class="muted">Same pipeline as browse <strong>Export</strong>: phone downloads the link (vanilla → 60s segments → archive). Prefer <strong>https://</strong>. Keep Loop Segments open on Wi‑Fi. Save name becomes the export display name / file extension. REST: <code>POST /export_from_url.json</code> (Basic auth).</p>
        <div class="row">
          <label style="flex:1 1 auto;min-width:0;display:flex;flex-direction:column;gap:0.25rem;width:100%">URL
            <input type="url" id="url-download-link" placeholder="https://…" style="width:100%;box-sizing:border-box;padding:0.4rem" autocomplete="off" />
          </label>
        </div>
        <div class="row" style="align-items:flex-end;flex-wrap:nowrap;gap:0.65rem">
          <label style="flex:1 1 auto;min-width:0;display:flex;flex-direction:column;gap:0.25rem">Save as (file name)
            <input type="text" id="url-download-name" placeholder="MyClip.mp4" style="width:100%;box-sizing:border-box;padding:0.4rem" autocomplete="off" />
          </label>
          <button type="button" id="url-download-start" style="flex:0 0 auto;white-space:nowrap;align-self:flex-end">Start export</button>
        </div>
        <p id="url-download-status" class="muted"></p>
        </div>
        <script>
        (function () {
          var AUTH = "Basic " + btoa("\(user):\(pass)");
          var exportUrlApi = "/export_from_url.json";
          var ackUrl = "/\(LANExportTriggerControl.ackRelativePath)";
          function uuid() {
            return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function (c) {
              var r = Math.random() * 16 | 0, v = c === "x" ? r : (r & 0x3 | 0x8);
              return v.toString(16);
            });
          }
          function setStatus(msg, isErr) {
            var el = document.getElementById("url-download-status");
            el.textContent = msg || "";
            el.style.color = (typeof __lanStatusColor === "function") ? __lanStatusColor(isErr) : (isErr ? "#b00020" : "#333");
          }
          function guessNameFromUrl(urlText) {
            try {
              var u = new URL(urlText);
              var base = (u.pathname || "").split("/").filter(Boolean).pop() || "";
              try { base = decodeURIComponent(base); } catch (e) {}
              return base;
            } catch (e) {
              return "";
            }
          }
          document.getElementById("url-download-link").addEventListener("change", function () {
            var nameEl = document.getElementById("url-download-name");
            if (nameEl.value.trim()) return;
            var guess = guessNameFromUrl(this.value.trim());
            if (guess) nameEl.value = guess;
          });
          document.getElementById("url-download-start").onclick = async function () {
            var url = document.getElementById("url-download-link").value.trim();
            var saveName = document.getElementById("url-download-name").value.trim();
            if (!url) { setStatus("Enter a download URL", true); return; }
            if (!saveName) {
              saveName = guessNameFromUrl(url) || "download";
              document.getElementById("url-download-name").value = saveName;
            }
            var btn = document.getElementById("url-download-start");
            btn.disabled = true;
            setStatus("Starting export… Keep the phone app open.");
            if (window.setExportPending) {
              window.setExportPending(
                true,
                "Starting URL export",
                "Please wait while the phone starts the same export pipeline as browse Export (vanilla → segments). Keep Loop Segments open in the foreground."
              );
            }
            if (window.updateExportSourceLine) {
              window.updateExportSourceLine("running", saveName);
            }
            try {
              var body = {
                url: url,
                saveName: saveName,
                id: uuid()
              };
              var r = await fetch(exportUrlApi, {
                method: "POST",
                headers: { "Authorization": AUTH, "Content-Type": "application/json" },
                body: JSON.stringify(body)
              });
              var j = null;
              try { j = await r.json(); } catch (e) {}
              if (!r.ok && r.status !== 202) {
                var errText = (j && j.message) ? j.message : "";
                if (!errText) {
                  try { errText = await r.text(); } catch (e2) {}
                }
                throw new Error("POST " + r.status + (errText ? ": " + errText.trim() : ""));
              }
              var finalMsg = (j && (j.status || j.message))
                ? ((j.status || "ok") + ": " + (j.message || ""))
                : ("queued: export " + saveName);
              if (j && (j.status === "rejected" || j.status === "error")) {
                setStatus(finalMsg, true);
                return;
              }
              for (var i = 0; i < 8; i++) {
                await new Promise(function (res) { setTimeout(res, 500); });
                try {
                  var ack = await fetch(ackUrl, { headers: { "Authorization": AUTH } });
                  if (ack.ok) {
                    var a = await ack.json();
                    if (j && j.triggerId && a.triggerId && a.triggerId !== j.triggerId) continue;
                    finalMsg = (a.status || "ok") + ": " + (a.message || "");
                    if (a.status === "rejected" || a.status === "ignored") {
                      setStatus(finalMsg, true);
                      return;
                    }
                    break;
                  }
                } catch (e) {}
              }
              setStatus(finalMsg + " Export runs on the phone — watch the top bar / export_latest.txt.");
              if (window.refreshLANPlayback) {
                for (var p = 0; p < 6; p++) {
                  await new Promise(function (res) { setTimeout(res, 500); });
                  try { await window.refreshLANPlayback(); } catch (e) {}
                }
              }
            } catch (e) {
              setStatus(e.message || String(e), true);
            } finally {
              if (window.setExportPending) window.setExportPending(false);
              btn.disabled = false;
            }
          };
        })();
        </script>
        """
    }

    static func htmlExportControlPanel() -> String {
        let user = htmlEscape(lanWebDAVUsername)
        let pass = htmlEscape(lanWebDAVPassword)
        return """
        <div class="panel">
        <h2>Start export (pCloud → phone)</h2>
        <p class="muted">Phone app must be <strong>open and in foreground</strong> on Wi‑Fi. Uses pCloud sign-in on the phone — not your PC pCloud login.</p>
        <div id="pcloud-pinned-wrap" class="pcloud-pinned-wrap" style="display:none">
          <div class="label">Bookmarked folders</div>
          <p class="muted" style="margin:0 0 0.35rem;font-size:0.85em">Synced with Browse bookmarks on the phone.</p>
          <div id="pcloud-pinned" class="pcloud-folders pcloud-pinned"></div>
        </div>
        <div class="row">
          <button type="button" id="export-random">Export random in folder</button>
        </div>
        <div class="row">
          <button type="button" id="export-trim-media">Trim media (keep last 2)</button>
          <button type="button" id="export-clear-media">Clear media</button>
          <button type="button" id="export-lan-speed-test">LAN speed test</button>
        </div>
        <p class="muted" style="margin:0.25rem 0 0;font-size:0.85em">LAN speed test: <strong>10×</strong> browser Range downloads (up to 64&nbsp;MB each ≈ <strong>640&nbsp;MB</strong> total, same file) → <strong>median</strong> Mbps → <code>lan_throughput.json</code> sidecars. Available during export. No other-router reboot — use companion Measure for that.</p>
        <p id="trigger-status" class="muted"></p>
        <div class="row">
          <button type="button" id="pcloud-up" disabled>↑ Up</button>
          <code id="pcloud-path">/</code>
          <button type="button" id="pcloud-refresh">Refresh</button>
          <button type="button" id="pcloud-pin-current" style="display:none" title="Bookmark this folder">Bookmark folder</button>
        </div>
        <div class="row">
          <label>Sort
            <select id="pcloud-sort">
              <option value="name">Name</option>
              <option value="size">Size</option>
              <option value="date">Date</option>
            </select>
          </label>
        </div>
        <div id="pcloud-folders" class="pcloud-folders"><span class="muted">Loading…</span></div>
        <ul id="pcloud-files"><li class="muted">Loading…</li></ul>
        </div>
        <script>
        (function () {
          var AUTH = "Basic " + btoa("\(user):\(pass)");
          var triggerUrl = "/\(LANExportTriggerControl.triggerRelativePath)";
          var ackUrl = "/\(LANExportTriggerControl.ackRelativePath)";
          var pcloudPath = "/";
          var pcloudEntries = [];
          var sortKey = "name";
          var LEGACY_PIN_KEY = "loopsegments.lan.pinnedFolders.v1";
          var pinnedFolders = [];
          function normalizePath(p) {
            p = p || "/";
            if (p === "/") return "/";
            return p.replace(/\\/+$/, "") + "/";
          }
          function folderNameFromPath(p) {
            var trimmed = normalizePath(p).replace(/\\/+$/, "");
            if (!trimmed) return "/";
            var parts = trimmed.split("/").filter(Boolean);
            return parts.length ? parts[parts.length - 1] : "/";
          }
          function applyBookmarkPayload(j) {
            pinnedFolders = (j.entries || j.bookmarks || []).map(function (b) {
              var path = normalizePath(b.listingPath || b.path);
              return { path: path, name: b.displayName || b.name || folderNameFromPath(path) };
            });
            renderPinned();
            updatePinCurrentButton();
            if (pcloudEntries.length) renderPCloud();
          }
          async function loadPins() {
            try {
              var r = await fetch("/pcloud_bookmarks.json");
              var j = await r.json();
              applyBookmarkPayload(j);
              await migrateLegacyLocalPins();
            } catch (e) {
              pinnedFolders = [];
              renderPinned();
            }
          }
          async function migrateLegacyLocalPins() {
            try {
              var raw = localStorage.getItem(LEGACY_PIN_KEY);
              if (!raw) return;
              localStorage.removeItem(LEGACY_PIN_KEY);
              var local = JSON.parse(raw);
              if (!Array.isArray(local)) return;
              for (var i = 0; i < local.length; i++) {
                var item = local[i];
                var path = normalizePath(item.path);
                if (!isPinned(path)) {
                  await togglePin(path, item.name);
                }
              }
            } catch (e) {}
          }
          function isPinned(path) {
            var norm = normalizePath(path);
            return pinnedFolders.some(function (p) { return normalizePath(p.path) === norm; });
          }
          async function togglePin(path, name) {
            var norm = normalizePath(path);
            var r = await fetch("/pcloud_bookmarks.json", {
              method: "PUT",
              headers: { "Authorization": AUTH, "Content-Type": "application/json" },
              body: JSON.stringify({
                action: "toggle",
                listingPath: norm,
                displayName: name || folderNameFromPath(norm)
              })
            });
            if (!r.ok) throw new Error("bookmark PUT " + r.status);
            var j = await r.json();
            applyBookmarkPayload(j);
          }
          function renderPinned() {
            var wrap = document.getElementById("pcloud-pinned-wrap");
            var el = document.getElementById("pcloud-pinned");
            if (!pinnedFolders.length) {
              wrap.style.display = "none";
              el.innerHTML = "";
              return;
            }
            wrap.style.display = "";
            el.innerHTML = pinnedFolders.map(function (p) {
              return "<div class=\\"folder-item\\">" +
                "<button type=\\"button\\" class=\\"pcloud-dir pcloud-pinned-dir\\" data-path=\\"" + esc(p.path) + "\\">⭐ " + esc(p.name) + "</button>" +
                "<button type=\\"button\\" class=\\"pin-toggle pinned\\" data-path=\\"" + esc(p.path) + "\\" data-name=\\"" + esc(p.name) + "\\" title=\\"Remove bookmark\\">★</button>" +
                "</div>";
            }).join("");
          }
          function updatePinCurrentButton() {
            var btn = document.getElementById("pcloud-pin-current");
            var norm = normalizePath(pcloudPath);
            if (norm === "/") {
              btn.style.display = "none";
              return;
            }
            btn.style.display = "";
            btn.textContent = isPinned(norm) ? "Remove bookmark" : "Bookmark folder";
          }
          function esc(s) {
            return String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/"/g,"&quot;");
          }
          function formatBytes(n) {
            if (n == null || isNaN(n)) return "";
            var u = ["B","KB","MB","GB","TB"];
            var i = 0, v = Number(n);
            while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
            return v.toFixed(i ? 1 : 0) + " " + u[i];
          }
          function formatDate(iso) {
            if (!iso) return "";
            try { return new Date(iso).toLocaleString(); } catch (e) { return iso; }
          }
          function compareEntries(a, b) {
            if (sortKey === "size") {
              var as = a.bytes || 0, bs = b.bytes || 0;
              if (as !== bs) return bs - as;
            } else if (sortKey === "date") {
              var ad = a.modified || "", bd = b.modified || "";
              if (ad !== bd) return bd.localeCompare(ad);
            }
            return String(a.name || "").localeCompare(String(b.name || ""), undefined, { sensitivity: "base" });
          }
          function renderPCloud() {
            var foldersEl = document.getElementById("pcloud-folders");
            var filesEl = document.getElementById("pcloud-files");
            var pinnedPaths = pinnedFolders.map(function (p) { return normalizePath(p.path); });
            var dirs = pcloudEntries.filter(function (e) { return e.isDirectory; }).filter(function (e) {
              return pinnedPaths.indexOf(normalizePath(e.path)) === -1;
            }).slice().sort(compareEntries);
            var files = pcloudEntries.filter(function (e) { return e.isVideo; }).slice().sort(compareEntries);
            renderPinned();
            updatePinCurrentButton();
            foldersEl.innerHTML = dirs.length
              ? dirs.map(function (e) {
                  var pinned = isPinned(e.path);
                  return "<div class=\\"folder-item\\">" +
                    "<button type=\\"button\\" class=\\"pcloud-dir\\" data-path=\\"" + esc(e.path) + "\\">📁 " + esc(e.name) + "</button>" +
                    "<button type=\\"button\\" class=\\"pin-toggle" + (pinned ? " pinned" : "") + "\\" data-path=\\"" + esc(e.path) + "\\" data-name=\\"" + esc(e.name) + "\\" title=\\"" + (pinned ? "Remove bookmark" : "Bookmark") + "\\">" + (pinned ? "★" : "☆") + "</button>" +
                    "</div>";
                }).join("")
              : "<span class=\\"muted\\">(no folders)</span>";
            filesEl.innerHTML = files.length
              ? files.map(function (e) {
                  var meta = [];
                  if (e.bytes != null) meta.push(formatBytes(e.bytes));
                  if (e.modified) meta.push(formatDate(e.modified));
                  var metaHtml = meta.length ? " <span class=\\"file-meta\\">(" + esc(meta.join(" · ")) + ")</span>" : "";
                  return "<li><span>🎬 " + esc(e.name) + metaHtml + "</span>" +
                    " <button type=\\"button\\" class=\\"export-file\\" data-href=\\"" + esc(e.href) + "\\" data-name=\\"" + esc(e.name) + "\\">Export 0:00</button></li>";
                }).join("")
              : "<li class=\\"muted\\">(no videos)</li>";
          }
          function uuid() {
            return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function (c) {
              var r = Math.random() * 16 | 0, v = c === "x" ? r : (r & 0x3 | 0x8);
              return v.toString(16);
            });
          }
          function setStatus(msg, isErr) {
            var el = document.getElementById("trigger-status");
            el.textContent = msg || "";
            el.style.color = (typeof __lanStatusColor === "function") ? __lanStatusColor(isErr) : (isErr ? "#b00020" : "#333");
          }
          function exportPendingMessage(command, body) {
            var foreground = " Keep Loop Segments open in the foreground on the phone.";
            switch (command) {
              case "start_export":
                return {
                  title: "Switching export source",
                  detail: "Please wait while the phone switches to "
                    + (body.displayName || "the selected file") + "." + foreground
                };
              case "start_export_random":
                return {
                  title: "Switching export source",
                  detail: "Please wait while the phone picks and starts a new export in this folder." + foreground
                };
              case "resume_export":
                return {
                  title: "Starting export",
                  detail: "Please wait while the phone resumes the paused export." + foreground
                };
              case "clear_media":
                return {
                  title: "Clearing media",
                  detail: "Please wait while the phone permanently deletes active export media, archive/, and downloads/ files." + foreground
                };
              case "download_url":
                return {
                  title: "Starting URL export",
                  detail: "Please wait while the phone starts the same export pipeline as browse Export (vanilla → segments)." + foreground
                };
              case "trim_media":
                return {
                  title: "Trimming archive",
                  detail: "Please wait while the phone removes older archive/ batches (keeps last 2)." + foreground
                };
              default:
                return {
                  title: "Processing export request",
                  detail: "Please wait while the phone applies your export change." + foreground
                };
            }
          }
          function setExportPending(active, title, detail) {
            window._exportSourcePending = !!active;
            var banner = document.getElementById("lan-export-pending");
            if (banner) banner.style.display = active ? "" : "none";
            var titleEl = document.getElementById("lan-export-pending-title");
            var detailEl = document.getElementById("lan-export-pending-detail");
            if (titleEl && title) titleEl.textContent = title;
            if (detailEl && detail) detailEl.textContent = detail;
            ["export-resume", "export-random", "export-trim-media", "export-clear-media"].forEach(function (id) {
              var btn = document.getElementById(id);
              if (btn) btn.disabled = !!active;
            });
            document.querySelectorAll(".export-file").forEach(function (btn) {
              btn.disabled = !!active;
            });
            document.querySelectorAll(".export-parked").forEach(function (btn) {
              btn.disabled = !!active;
            });
          }
          window.setExportPending = setExportPending;
          async function putTrigger(body) {
            var pending = exportPendingMessage(body.command, body);
            setExportPending(true, pending.title, pending.detail);
            try {
            setStatus("Sending trigger…");
            if (body.command === "start_export" && body.displayName && window.updateExportSourceLine) {
              window.updateExportSourceLine("running", body.displayName);
            } else if (body.command === "start_export_random" && window.updateExportSourceLine) {
              window.updateExportSourceLine("running", "Random in " + pcloudPath);
            } else if (body.command === "resume_export" && window.updateExportSourceLine) {
              var curName = document.getElementById("lan-export-source-name");
              if (curName && curName.textContent) window.updateExportSourceLine("running", curName.textContent);
            }
            var r = await fetch(triggerUrl, {
              method: "PUT",
              headers: { "Authorization": AUTH, "Content-Type": "application/json" },
              body: JSON.stringify(body)
            });
            if (!r.ok) {
              var errText = "";
              try { errText = await r.text(); } catch (e) {}
              throw new Error("PUT " + r.status + (errText ? ": " + errText.trim() : ""));
            }
            for (var i = 0; i < 8; i++) {
              await new Promise(function (res) { setTimeout(res, 500); });
              try {
                var ack = await fetch(ackUrl, { headers: { "Authorization": AUTH } });
                if (ack.ok) {
                  var j = await ack.json();
                  setStatus((j.status || "?") + ": " + (j.message || ""), j.status === "rejected");
                  if (j.status === "accepted" && window.refreshLANPlayback) {
                    for (var p = 0; p < 6; p++) {
                      await new Promise(function (res) { setTimeout(res, 500); });
                      try { await window.refreshLANPlayback(); } catch (e) {}
                    }
                  }
                  return;
                }
              } catch (e) {}
            }
            setStatus("Trigger sent — check phone app (foreground).", false);
            } finally {
              setExportPending(false);
            }
          }
          async function loadPCloud() {
            document.getElementById("pcloud-path").textContent = pcloudPath;
            document.getElementById("pcloud-up").disabled = pcloudPath === "/";
            updatePinCurrentButton();
            var foldersEl = document.getElementById("pcloud-folders");
            var filesEl = document.getElementById("pcloud-files");
            foldersEl.innerHTML = "<span class=\\"muted\\">Loading…</span>";
            filesEl.innerHTML = "<li class=\\"muted\\">Loading…</li>";
            try {
              var r = await fetch("/pcloud_list.json?path=" + encodeURIComponent(pcloudPath));
              var j = await r.json();
              if (j.error) {
                foldersEl.innerHTML = "<span class=\\"muted\\">" + esc(j.error) + "</span>";
                filesEl.innerHTML = "";
                pcloudEntries = [];
                renderPinned();
                return;
              }
              pcloudEntries = j.entries || [];
              if (!pcloudEntries.length) {
                foldersEl.innerHTML = "<span class=\\"muted\\">(empty folder)</span>";
                filesEl.innerHTML = "";
                renderPinned();
                updatePinCurrentButton();
                return;
              }
              renderPCloud();
            } catch (err) {
              foldersEl.innerHTML = "<span class=\\"muted\\">" + esc(err.message || err) + "</span>";
              filesEl.innerHTML = "";
              pcloudEntries = [];
              renderPinned();
            }
          }
          function handleFolderAreaClick(ev) {
            var pinBtn = ev.target.closest ? ev.target.closest(".pin-toggle") : null;
            if (pinBtn) {
              togglePin(pinBtn.getAttribute("data-path"), pinBtn.getAttribute("data-name"))
                .catch(function (e) { setStatus(e.message || e, true); });
              return;
            }
            var dirBtn = ev.target.closest ? ev.target.closest(".pcloud-dir") : null;
            if (!dirBtn && ev.target.classList && ev.target.classList.contains("pcloud-dir")) {
              dirBtn = ev.target;
            }
            if (dirBtn) {
              pcloudPath = dirBtn.getAttribute("data-path") || "/";
              loadPCloud();
            }
          }
          document.getElementById("pcloud-up").onclick = function () {
            var trimmed = pcloudPath.replace(/\\/$/, "");
            if (!trimmed || trimmed === "/") { pcloudPath = "/"; loadPCloud(); return; }
            var parts = trimmed.split("/").filter(Boolean);
            parts.pop();
            pcloudPath = parts.length ? "/" + parts.join("/") + "/" : "/";
            loadPCloud();
          };
          document.getElementById("pcloud-refresh").onclick = function () {
            loadPins().then(function () { loadPCloud(); }).catch(function () { loadPCloud(); });
          };
          document.getElementById("export-random").onclick = function () {
            putTrigger({ version: 1, command: "start_export_random", pool: "same_folder", folderPath: pcloudPath, id: uuid(), seekMs: 0 })
              .catch(function (e) { setStatus(e.message || e, true); });
          };
          document.getElementById("export-resume").onclick = function () {
            putTrigger({ version: 1, command: "resume_export", id: uuid() })
              .catch(function (e) { setStatus(e.message || e, true); });
          };
          document.getElementById("export-trim-media").onclick = function () {
            putTrigger({ version: 1, command: "trim_media", id: uuid() })
              .catch(function (e) { setStatus(e.message || e, true); });
          };
          document.getElementById("export-clear-media").onclick = function () {
            if (!confirm("Permanently delete active export media, archive/, and downloads/ files on the phone?")) return;
            putTrigger({ version: 1, command: "clear_media", id: uuid() })
              .catch(function (e) { setStatus(e.message || e, true); });
          };
          if (window.bindLANSpeedTestButton) {
            window.bindLANSpeedTestButton({
              buttonId: "export-lan-speed-test",
              setStatus: setStatus,
              authHeader: AUTH
            });
          }
          document.getElementById("pcloud-sort").onchange = function (ev) {
            sortKey = ev.target.value || "name";
            renderPCloud();
          };
          document.getElementById("pcloud-folders").onclick = handleFolderAreaClick;
          document.getElementById("pcloud-pinned").onclick = handleFolderAreaClick;
          document.getElementById("pcloud-pin-current").onclick = function () {
            togglePin(pcloudPath, folderNameFromPath(pcloudPath))
              .catch(function (e) { setStatus(e.message || e, true); });
          };
          document.getElementById("pcloud-files").onclick = function (ev) {
            var exportBtn = ev.target.closest ? ev.target.closest(".export-file") : null;
            if (!exportBtn && ev.target.classList && ev.target.classList.contains("export-file")) {
              exportBtn = ev.target;
            }
            if (exportBtn) {
              putTrigger({
                version: 1,
                command: "start_export",
                href: exportBtn.getAttribute("data-href"),
                displayName: exportBtn.getAttribute("data-name"),
                folderPath: pcloudPath,
                seekMs: 0,
                id: uuid()
              }).catch(function (e) { setStatus(e.message || e, true); });
            }
          };
          function queueParkedResume(btn) {
            if (!btn) return;
            var href = (btn.getAttribute("data-href") || "").trim();
            var name = (btn.getAttribute("data-name") || "").trim();
            var folder = (btn.getAttribute("data-folder-path") || "").trim();
            var seekMs = parseInt(btn.getAttribute("data-seek-ms") || "0", 10) || 0;
            var body = { version: 1, command: "start_export", displayName: name, seekMs: seekMs, id: uuid() };
            if (href) body.href = href;
            if (folder) body.folderPath = folder;
            if (!href && !folder && !name) {
              setStatus("Parked resume missing href/folder/name", true);
              return;
            }
            putTrigger(body).catch(function (e) { setStatus(e.message || e, true); });
          }
          var playbackFiles = document.getElementById("lan-playback-files");
          if (playbackFiles) {
            playbackFiles.onclick = function (ev) {
              var parkedBtn = ev.target.closest ? ev.target.closest(".export-parked") : null;
              if (!parkedBtn && ev.target.classList && ev.target.classList.contains("export-parked")) {
                parkedBtn = ev.target;
              }
              if (parkedBtn) queueParkedResume(parkedBtn);
            };
          }
          var pausedList = document.getElementById("lan-paused-list");
          if (pausedList) {
            pausedList.onclick = function (ev) {
              var parkedBtn = ev.target.closest ? ev.target.closest(".export-parked") : null;
              if (!parkedBtn && ev.target.classList && ev.target.classList.contains("export-parked")) {
                parkedBtn = ev.target;
              }
              if (parkedBtn) queueParkedResume(parkedBtn);
            };
          }
          loadPins().then(function () { loadPCloud(); }).catch(function () { loadPCloud(); });
          window.refreshLANBookmarks = loadPins;
        })();
        </script>
        """
    }
}
