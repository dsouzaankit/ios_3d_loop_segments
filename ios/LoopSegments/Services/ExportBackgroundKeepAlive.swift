import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// Loops local silent audio during export so iOS keeps the process alive behind the lock screen.
@MainActor
final class ExportBackgroundKeepAlive: NSObject {
    static let shared = ExportBackgroundKeepAlive()

    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var timeoutTask: Task<Void, Never>?
    private var nowPlayingRefreshTask: Task<Void, Never>?
    private var exportSubtitle = ""
    private var startedAt = Date()
    private var exportSessionEligible = false
    private var remoteCommandsRegistered = false
    private(set) var lastStartError: String?

    private static let lockScreenArtwork: MPMediaItemArtwork = {
        let size = CGSize(width: 300, height: 300)
        return MPMediaItemArtwork(boundsSize: size) { _ in
            UIGraphicsImageRenderer(size: size).image { context in
                UIColor.systemOrange.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
        }
    }()

    private override init() {
        super.init()
    }

    func beginExportSession(exportTitle: String) {
        exportSessionEligible = true
        exportSubtitle = exportTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        startIfEnabled(exportTitle: exportTitle)
    }

    func endExportSession() {
        exportSessionEligible = false
        stopFully()
    }

    func startIfEnabled(exportTitle: String) {
        guard ExportKeepAliveSettings.isEnabled else { return }
        exportSubtitle = exportTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        startedAt = Date()
        Task { await startPlaybackAsync() }
    }

    /// User turned off the toggle mid-export — stop audio only; export session unchanged.
    func stopForUserSettingOff() {
        let keepEligible = exportSessionEligible
        tearDownPlayback()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        unregisterRemoteCommands()
        NowPlayingFirstResponder.deactivate()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
        exportSessionEligible = keepEligible
    }

    var isActive: Bool { queuePlayer != nil }

    var isLoopPlaying: Bool {
        guard let queuePlayer else { return false }
        return queuePlayer.rate > 0
    }

    // MARK: - Playback

    private func startPlaybackAsync() async {
        tearDownPlayback()
        lastStartError = nil
        do {
            try configureAudioSession()
            let url = try SilentKeepAliveAudioGenerator.ensureFileURL()
            let template = AVPlayerItem(url: url)
            template.audioTimePitchAlgorithm = .timeDomain
            try await waitUntilReadyToPlay(template)

            let player = AVQueuePlayer()
            player.automaticallyWaitsToMinimizeStalling = false
            playerLooper = AVPlayerLooper(player: player, templateItem: template)
            queuePlayer = player
            // File is digital silence; full volume keeps the playback pipeline (and lock screen) alive.
            player.volume = 1
            player.actionAtItemEnd = .advance
            ensureRemoteCommandsRegistered()
            NowPlayingFirstResponder.activate()
            applyNowPlayingInfo(playbackRate: 1, elapsedSeconds: 0)
            player.play()
            startNowPlayingRefresh()
            scheduleTimeoutIfNeeded()
            SearchDebugLog.log("Keep Alive: silent loop started — lock screen should show Now Playing")
        } catch {
            lastStartError = error.localizedDescription
            SearchDebugLog.log("Keep Alive: failed to start — \(error.localizedDescription)")
            tearDownPlayback()
        }
    }

    private func waitUntilReadyToPlay(_ item: AVPlayerItem) async throws {
        for _ in 0 ..< 200 {
            switch item.status {
            case .readyToPlay:
                return
            case .failed:
                throw item.error ?? SilentKeepAliveAudioGenerator.GeneratorError.buffer
            default:
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        throw SilentKeepAliveAudioGenerator.GeneratorError.buffer
    }

    private func tearDownPlayback() {
        nowPlayingRefreshTask?.cancel()
        nowPlayingRefreshTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        queuePlayer?.pause()
        playerLooper?.disableLooping()
        queuePlayer = nil
        playerLooper = nil
    }

    private func stopFully() {
        tearDownPlayback()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        unregisterRemoteCommands()
        NowPlayingFirstResponder.deactivate()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    private func applyNowPlayingInfo(
        playbackRate: Double = 1,
        elapsedSeconds: Double = 0,
        albumHint: String? = nil
    ) {
        let hint = albumHint
            ?? (playbackRate > 0
                ? "Export running — stop on lock screen when finished"
                : "Tap play to resume Keep Alive (export still running)")
        var duration: Double = 60
        if let timeout = ExportKeepAliveSettings.timeoutSeconds {
            duration = max(60, timeout - Date().timeIntervalSince(startedAt))
        }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: "Keep Alive",
            MPMediaItemPropertyArtist: exportSubtitle.isEmpty ? "Loop Segments" : exportSubtitle,
            MPMediaItemPropertyAlbumTitle: hint,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsedSeconds),
            MPMediaItemPropertyPlaybackDuration: duration,
            MPMediaItemPropertyArtwork: Self.lockScreenArtwork,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func startNowPlayingRefresh() {
        nowPlayingRefreshTask?.cancel()
        nowPlayingRefreshTask = Task { @MainActor in
            while !Task.isCancelled, let player = queuePlayer {
                let elapsed = player.currentTime().seconds
                let safeElapsed = elapsed.isFinite ? max(0, elapsed) : 0
                let rate: Double = player.rate > 0 ? 1 : 0
                applyNowPlayingInfo(playbackRate: rate, elapsedSeconds: safeElapsed)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - Lock screen remote

    private func ensureRemoteCommandsRegistered() {
        guard !remoteCommandsRegistered else { return }
        remoteCommandsRegistered = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playFromLockScreen() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pauseFromLockScreen() }
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.stopFromLockScreen() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggleFromLockScreen() }
            return .success
        }
    }

    private func unregisterRemoteCommands() {
        guard remoteCommandsRegistered else { return }
        remoteCommandsRegistered = false
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.stopCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
    }

    private func playFromLockScreen() {
        if let queuePlayer {
            queuePlayer.play()
            applyNowPlayingInfo(playbackRate: 1, elapsedSeconds: queuePlayer.currentTime().seconds)
            SearchDebugLog.log("Keep Alive: resumed from lock screen")
            return
        }
        guard exportSessionEligible, ExportKeepAliveSettings.isEnabled else {
            SearchDebugLog.log("Keep Alive: play ignored — no export session")
            return
        }
        startedAt = Date()
        Task { await startPlaybackAsync() }
        SearchDebugLog.log("Keep Alive: restarted loop from lock screen")
    }

    private func pauseFromLockScreen() {
        queuePlayer?.pause()
        let elapsed = queuePlayer?.currentTime().seconds ?? 0
        applyNowPlayingInfo(
            playbackRate: 0,
            elapsedSeconds: elapsed.isFinite ? elapsed : 0,
            albumHint: "Paused — tap play to resume Keep Alive"
        )
    }

    private func stopFromLockScreen() {
        tearDownPlayback()
        try? configureAudioSession()
        ensureRemoteCommandsRegistered()
        NowPlayingFirstResponder.activate()
        applyNowPlayingInfo(
            playbackRate: 0,
            elapsedSeconds: 0,
            albumHint: "Stopped — tap play to resume Keep Alive (export still running)"
        )
        SearchDebugLog.log("Keep Alive: stopped from lock screen (tap play to restart; export continues)")
    }

    private func toggleFromLockScreen() {
        if isLoopPlaying {
            pauseFromLockScreen()
        } else {
            playFromLockScreen()
        }
    }

    private func scheduleTimeoutIfNeeded() {
        guard let timeout = ExportKeepAliveSettings.timeoutSeconds else { return }
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, isActive else { return }
            SearchDebugLog.log(
                String(
                    format: "Keep Alive: auto-stopped after %.0f h — tap play on lock screen to restart",
                    ExportKeepAliveSettings.timeoutHours
                )
            )
            stopFromLockScreen()
        }
    }
}
