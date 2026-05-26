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
    private var exportSubtitle = ""
    private var startedAt = Date()
    private var exportSessionEligible = false
    private var remoteCommandsRegistered = false

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
        startPlayback()
    }

    /// User turned off the toggle mid-export — stop audio only; export session unchanged.
    func stopForUserSettingOff() {
        tearDownPlayback()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        unregisterRemoteCommands()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }

    var isActive: Bool { queuePlayer != nil }

    var isLoopPlaying: Bool {
        guard let queuePlayer else { return false }
        return queuePlayer.rate > 0
    }

    // MARK: - Playback

    private func startPlayback() {
        tearDownPlayback()
        do {
            try configureAudioSession()
            let url = try SilentKeepAliveAudioGenerator.ensureFileURL()
            let template = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            playerLooper = AVPlayerLooper(player: player, templateItem: template)
            queuePlayer = player
            player.volume = 0.0001
            player.actionAtItemEnd = .advance
            ensureRemoteCommandsRegistered()
            UIApplication.shared.beginReceivingRemoteControlEvents()
            applyNowPlayingInfo(playbackRate: 1)
            player.play()
            scheduleTimeoutIfNeeded()
            SearchDebugLog.log("Keep Alive: silent loop started (lock screen — play to resume after stop)")
        } catch {
            SearchDebugLog.log("Keep Alive: failed to start — \(error.localizedDescription)")
            tearDownPlayback()
        }
    }

    private func tearDownPlayback() {
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
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }

    private func applyNowPlayingInfo(playbackRate: Double = 1, albumHint: String? = nil) {
        let hint = albumHint
            ?? (playbackRate > 0
                ? "Export running — stop on lock screen when finished"
                : "Tap play to resume Keep Alive (export still running)")
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "Keep Alive",
            MPMediaItemPropertyArtist: exportSubtitle.isEmpty ? "Loop Segments" : exportSubtitle,
            MPMediaItemPropertyAlbumTitle: hint,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0,
            MPMediaItemPropertyPlaybackDuration: 60,
        ]
        if let timeout = ExportKeepAliveSettings.timeoutSeconds {
            let remaining = max(0, timeout - Date().timeIntervalSince(startedAt))
            info[MPNowPlayingInfoPropertyPlaybackDuration] = remaining
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
            applyNowPlayingInfo(playbackRate: 1)
            SearchDebugLog.log("Keep Alive: resumed from lock screen")
            return
        }
        guard exportSessionEligible, ExportKeepAliveSettings.isEnabled else {
            SearchDebugLog.log("Keep Alive: play ignored — no export session")
            return
        }
        startedAt = Date()
        startPlayback()
        SearchDebugLog.log("Keep Alive: restarted loop from lock screen")
    }

    private func pauseFromLockScreen() {
        queuePlayer?.pause()
        applyNowPlayingInfo(
            playbackRate: 0,
            albumHint: "Paused — tap play to resume Keep Alive"
        )
    }

    private func stopFromLockScreen() {
        tearDownPlayback()
        try? configureAudioSession()
        ensureRemoteCommandsRegistered()
        applyNowPlayingInfo(
            playbackRate: 0,
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
