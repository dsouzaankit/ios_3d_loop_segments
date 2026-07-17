import AVFoundation
import Foundation
import MediaPlayer
import UIKit

extension Notification.Name {
    /// Posted when Keep Alive playback starts or fully stops (RootView refreshes LAN services).
    static let exportBackgroundKeepAliveActiveDidChange = Notification.Name(
        "ExportBackgroundKeepAlive.activeDidChange"
    )
}

/// Loops muted local media (or synthetic tone) during export for lock-screen / background audio.
@MainActor
final class ExportBackgroundKeepAlive: NSObject, AVAudioPlayerDelegate {
    static let shared = ExportBackgroundKeepAlive()

    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var playbackBackend = ""
    private var loopSourceLabel = ""
    private var timeoutTask: Task<Void, Never>?
    private var sessionAutoStopTask: Task<Void, Never>?
    private var sessionAutoStopEndsAt: Date?
    private var sessionAutoStopSubtitle: String?
    private var nowPlayingRefreshTask: Task<Void, Never>?
    private var playbackWatchdogTask: Task<Void, Never>?
    private var sessionObserversInstalled = false
    private var startedAt = Date()
    private var exportSessionEligible = false
    private var remoteCommandsRegistered = false
    private var loopPlaying = false
    private var userPausedFromLockScreen = false
    private(set) var lastStartError: String?

    private static let playbackVolume: Float = 0.02

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

    func prepareAudioSessionIfEnabled() {
        guard ExportKeepAliveSettings.isEnabled else { return }
        do {
            try configureAudioSession()
            logKeepAlive("Keep Alive: audio session prepared (toggle on)")
        } catch {
            logKeepAlive("Keep Alive: prepare failed — \(Self.describeError(error))")
        }
    }

    func beginExportSession(exportTitle: String) {
        installSessionObserversIfNeeded()
        cancelSessionAutoStop()
        exportSessionEligible = true
        startIfEnabled(exportTitle: exportTitle)
    }

    func endExportSession() {
        exportSessionEligible = false
        timeoutTask?.cancel()
        timeoutTask = nil
        scheduleSessionAutoStopAfterExportIfNeeded()
    }

    /// Starts or extends silent audio for **sessionDurationSeconds** while the app is in the foreground (toggle on).
    func beginAppForegroundSession() {
        guard ExportKeepAliveSettings.isEnabled else { return }
        installSessionObserversIfNeeded()
        guard !exportSessionEligible else { return }
        if !isActive {
            startedAt = Date()
            startPlayback()
            guard isActive else { return }
        } else if let queue = queuePlayer, !userPausedFromLockScreen, !isQueuePlaying {
            try? configureAudioSession()
            queue.play()
            syncLoopPlayingFromQueue()
        }
        let minutes = ExportKeepAliveSettings.sessionDurationSeconds / 60
        scheduleSessionAutoStop(
            logMessage: String(format: "Keep Alive: app foreground — continuing %.0f min", minutes),
            albumHint: "App open"
        )
    }

    func startIfEnabled(exportTitle: String) {
        guard ExportKeepAliveSettings.isEnabled else { return }
        startedAt = Date()
        startPlayback()
    }

    func stopForUserSettingOff() {
        let keepEligible = exportSessionEligible
        cancelSessionAutoStop()
        tearDownPlayback()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        unregisterRemoteCommands()
        NowPlayingFirstResponder.deactivate()
        deactivateAudioSessionIfIdle()
        exportSessionEligible = keepEligible
    }

    var isActive: Bool { queuePlayer != nil }

    var isLoopPlaying: Bool { loopPlaying }

    private var hasSessionAutoStop: Bool { sessionAutoStopTask != nil }

    private var keepAliveSessionActive: Bool {
        exportSessionEligible || hasSessionAutoStop
    }

    // MARK: - Playback

    private func startPlayback() {
        tearDownPlayback()
        lastStartError = nil
        loopSourceLabel = ""
        let session = AVAudioSession.sharedInstance()
        let otherAudio = session.isOtherAudioPlaying
        do {
            try configureAudioSession()
            guard let media = KeepAliveMediaSource.firstPlayable() else {
                throw KeepAliveFailure.message(
                    "KeepAlive_silence.mp3 not available — \(KeepAliveMediaSource.failureReason())"
                )
            }
            do {
                try startMediaLoop(candidate: media)
                playbackBackend = "AVPlayerLooper"
                loopSourceLabel = media.label
            } catch let mediaError {
                throw KeepAliveFailure.stage("AVPlayerLooper KeepAlive_silence.mp3", mediaError)
            }
            loopPlaying = true
            userPausedFromLockScreen = false
            ensureRemoteCommandsRegistered()
            NowPlayingFirstResponder.activate()
            applyNowPlayingInfo(playbackRate: 1, elapsedSeconds: 0)
            startNowPlayingRefresh()
            startPlaybackWatchdog()
            scheduleTimeoutIfNeeded()
            let sourceNote = loopSourceLabel.isEmpty ? "" : " source=\(loopSourceLabel)"
            logKeepAlive(
                "Keep Alive: started via \(playbackBackend)\(sourceNote) (otherAudio=\(otherAudio))"
            )
            postActiveDidChange()
        } catch {
            lastStartError = Self.describeError(error)
            logKeepAlive("Keep Alive: failed — \(lastStartError!)")
            tearDownPlayback()
        }
    }

    private func startMediaLoop(candidate: KeepAliveMediaSource.Candidate) throws {
        let item = AVPlayerItem(url: candidate.url)
        let queue = AVQueuePlayer()
        queue.volume = Self.playbackVolume
        queue.automaticallyWaitsToMinimizeStalling = false
        let looper = AVPlayerLooper(player: queue, templateItem: item)
        queue.play()
        queuePlayer = queue
        playerLooper = looper
    }

    private func tearDownPlayback() {
        nowPlayingRefreshTask?.cancel()
        nowPlayingRefreshTask = nil
        playbackWatchdogTask?.cancel()
        playbackWatchdogTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        loopPlaying = false
        userPausedFromLockScreen = false
        playerLooper?.disableLooping()
        playerLooper = nil
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        queuePlayer = nil
        playbackBackend = ""
        loopSourceLabel = ""
    }

    private func stopFully() {
        let wasActive = isActive
        cancelSessionAutoStop()
        tearDownPlayback()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        unregisterRemoteCommands()
        NowPlayingFirstResponder.deactivate()
        deactivateAudioSessionIfIdle()
        if wasActive {
            postActiveDidChange()
        }
    }

    private func postActiveDidChange() {
        NotificationCenter.default.post(name: .exportBackgroundKeepAliveActiveDidChange, object: nil)
    }

    private func scheduleSessionAutoStopAfterExportIfNeeded() {
        guard ExportKeepAliveSettings.isEnabled, isActive else {
            stopFully()
            return
        }
        let minutes = ExportKeepAliveSettings.sessionDurationSeconds / 60
        scheduleSessionAutoStop(
            logMessage: String(format: "Keep Alive: export ended — continuing %.0f min", minutes),
            albumHint: "Export finished"
        )
    }

    private func scheduleSessionAutoStop(logMessage: String, albumHint: String) {
        guard ExportKeepAliveSettings.isEnabled else {
            if !exportSessionEligible { stopFully() }
            return
        }
        let seconds = ExportKeepAliveSettings.sessionDurationSeconds
        cancelSessionAutoStop()
        sessionAutoStopEndsAt = Date().addingTimeInterval(seconds)
        sessionAutoStopSubtitle = albumHint
        if isActive {
            applyNowPlayingInfo(
                playbackRate: loopPlaying ? 1 : 0,
                elapsedSeconds: Date().timeIntervalSince(startedAt).truncatingRemainder(dividingBy: 60),
                albumHint: albumHint
            )
        }
        logKeepAlive(logMessage)
        sessionAutoStopTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            logKeepAlive("Keep Alive: session ended (60 min)")
            stopFully()
        }
    }

    private func cancelSessionAutoStop() {
        sessionAutoStopTask?.cancel()
        sessionAutoStopTask = nil
        sessionAutoStopEndsAt = nil
        sessionAutoStopSubtitle = nil
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            let wantsControls = ExportKeepAliveSettings.preferLockScreenControls
            let options: AVAudioSession.CategoryOptions = wantsControls ? [] : [.mixWithOthers]
            try session.setCategory(.playback, mode: .default, options: options)
        } catch {
            throw KeepAliveFailure.stage("setCategory", error)
        }
        do {
            try session.setActive(true, options: [])
        } catch {
            throw KeepAliveFailure.stage(
                "setActive (otherAudio=\(session.isOtherAudioPlaying))",
                error
            )
        }
    }

    private func deactivateAudioSessionIfIdle() {
        guard !isActive else { return }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }

    private func applyNowPlayingInfo(
        playbackRate: Double = 1,
        elapsedSeconds: Double = 0,
        albumHint: String? = nil,
        forceLockScreenCard: Bool = false
    ) {
        let subtitle: String
        if let albumHint {
            subtitle = albumHint
        } else if let sessionAutoStopSubtitle {
            subtitle = sessionAutoStopSubtitle
        } else if exportSessionEligible {
            subtitle = playbackRate > 0 ? "Export running" : "Paused"
        } else {
            subtitle = playbackRate > 0 ? "Playing" : "Paused"
        }
        var duration: Double = 60
        if let autoStopEnds = sessionAutoStopEndsAt {
            duration = max(60, autoStopEnds.timeIntervalSinceNow)
        } else if let timeout = ExportKeepAliveSettings.timeoutSeconds {
            duration = max(60, timeout - Date().timeIntervalSince(startedAt))
        }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: "Keep Alive",
            MPMediaItemPropertyArtist: "Loop Segments",
            MPMediaItemPropertyAlbumTitle: subtitle,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsedSeconds),
            MPMediaItemPropertyPlaybackDuration: duration,
            MPMediaItemPropertyArtwork: Self.lockScreenArtwork,
        ]
        let showCard = forceLockScreenCard || ExportKeepAliveSettings.preferLockScreenControls
        if showCard {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            MPNowPlayingInfoCenter.default().playbackState = playbackRate > 0 ? .playing : .paused
        } else {
            // Mix mode: no Now Playing card while another app may own lock screen; playbackState helps background audio.
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = playbackRate > 0 ? .playing : .paused
        }
    }

    private func syncLoopPlayingFromQueue() {
        guard let queue = queuePlayer else {
            loopPlaying = false
            return
        }
        loopPlaying = queue.timeControlStatus == .playing
    }

    private var isQueuePlaying: Bool {
        queuePlayer?.timeControlStatus == .playing
    }

    private func startNowPlayingRefresh() {
        nowPlayingRefreshTask?.cancel()
        nowPlayingRefreshTask = Task { @MainActor in
            while !Task.isCancelled, isActive {
                let elapsed = Date().timeIntervalSince(startedAt)
                    .truncatingRemainder(dividingBy: 60)
                syncLoopPlayingFromQueue()
                let rate: Double = loopPlaying ? 1 : 0
                applyNowPlayingInfo(playbackRate: rate, elapsedSeconds: elapsed)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func startPlaybackWatchdog() {
        playbackWatchdogTask?.cancel()
        playbackWatchdogTask = Task { @MainActor in
            while !Task.isCancelled, exportSessionEligible {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, exportSessionEligible, ExportKeepAliveSettings.isEnabled else {
                    return
                }
                if !isActive {
                    logKeepAlive("Keep Alive: watchdog restart (player missing during export)")
                    startPlayback()
                    continue
                }
                guard loopPlaying, let queue = queuePlayer else { continue }
                if queue.timeControlStatus == .playing { continue }
                logKeepAlive("Keep Alive: watchdog resume (player stalled)")
                do {
                    try configureAudioSession()
                } catch {
                    logKeepAlive("Keep Alive: watchdog session failed — \(Self.describeError(error))")
                }
                queue.play()
            }
        }
    }

    private func installSessionObserversIfNeeded() {
        guard !sessionObserversInstalled else { return }
        sessionObserversInstalled = true
        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleAudioSessionInterruption(notification) }
        }
        center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        }
        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleAudioSessionRouteChange(notification) }
        }
    }

    private func handleAudioSessionRouteChange(_ notification: Notification) {
        guard keepAliveSessionActive, ExportKeepAliveSettings.isEnabled else { return }
        guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }
        switch reason {
        case .categoryChange:
            guard !userPausedFromLockScreen, !isQueuePlaying, isActive else { return }
            logKeepAlive("Keep Alive: audio route/category change — trying to resume loop")
            resumeAfterSessionDisruption(reclaimLockScreen: true)
        default:
            break
        }
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard keepAliveSessionActive, ExportKeepAliveSettings.isEnabled else { return }
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }
        switch type {
        case .began:
            // Another app started playback; the queue can silently stop.
            userPausedFromLockScreen = false
            loopPlaying = false
            applyNowPlayingInfo(
                playbackRate: 0,
                elapsedSeconds: Date().timeIntervalSince(startedAt).truncatingRemainder(dividingBy: 60),
                albumHint: "Interrupted"
            )
            logKeepAlive("Keep Alive: audio session interrupted")
        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            // Some interruptions end without `.shouldResume` even though the user stopped the other app.
            // Keep Alive is best-effort; try to resume either way.
            let note = options.contains(.shouldResume) ? "" : " (no shouldResume)"
            logKeepAlive("Keep Alive: resuming after interruption\(note)")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000) // let the other player fully deactivate
                guard keepAliveSessionActive, ExportKeepAliveSettings.isEnabled else { return }
                resumeAfterSessionDisruption(reclaimLockScreen: true)
            }
        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        guard keepAliveSessionActive, ExportKeepAliveSettings.isEnabled else { return }
        logKeepAlive("Keep Alive: media services reset — restarting loop")
        startPlayback()
    }

    private func resumeAfterSessionDisruption(reclaimLockScreen: Bool = false) {
        do {
            try configureAudioSession()
        } catch {
            logKeepAlive("Keep Alive: resume failed — \(Self.describeError(error))")
            return
        }
        NowPlayingFirstResponder.activate()
        if let queue = queuePlayer {
            queue.play()
            syncLoopPlayingFromQueue()
            applyNowPlayingInfo(
                playbackRate: loopPlaying ? 1 : 0,
                elapsedSeconds: Date().timeIntervalSince(startedAt).truncatingRemainder(dividingBy: 60),
                albumHint: loopPlaying ? "Export running" : "Paused",
                forceLockScreenCard: reclaimLockScreen
            )
            if reclaimLockScreen {
                logKeepAlive("Keep Alive: reclaimed lock screen Now Playing")
            }
        } else {
            startPlayback()
        }
    }

    private static func describeError(_ error: Error) -> String {
        if let failure = error as? KeepAliveFailure {
            return failure.display
        }
        let ns = error as NSError
        if ns.domain == NSOSStatusErrorDomain || ns.domain == "com.apple.coreaudio.avfaudio" {
            return "\(failureLabel(ns)) (\(ns.domain) \(ns.code))"
        }
        return "\(error.localizedDescription) (\(ns.domain) \(ns.code))"
    }

    private static func failureLabel(_ ns: NSError) -> String {
        if !ns.localizedDescription.isEmpty, ns.localizedDescription != "The operation couldn’t be completed." {
            return ns.localizedDescription
        }
        return "audio error"
    }

    private func logKeepAlive(_ message: String) {
        ExportRuntimeLog.mirror(message)
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
        guard keepAliveSessionActive, ExportKeepAliveSettings.isEnabled else {
            logKeepAlive("Keep Alive: play ignored — no active session")
            return
        }
        if let queue = queuePlayer {
            if isQueuePlaying {
                logKeepAlive("Keep Alive: play — already looping (tap pause to stop)")
                return
            }
            userPausedFromLockScreen = false
            try? configureAudioSession()
            queue.play()
            syncLoopPlayingFromQueue()
            applyNowPlayingInfo(
                playbackRate: 1,
                elapsedSeconds: Date().timeIntervalSince(startedAt).truncatingRemainder(dividingBy: 60),
                forceLockScreenCard: true
            )
            logKeepAlive("Keep Alive: play from lock screen — loop \(loopPlaying ? "playing" : "not playing")")
            return
        }
        startedAt = Date()
        startPlayback()
        logKeepAlive("Keep Alive: restarted from lock screen")
    }

    private func pauseFromLockScreen() {
        guard let queue = queuePlayer else {
            logKeepAlive("Keep Alive: pause ignored — no player")
            return
        }
        queue.pause()
        loopPlaying = false
        userPausedFromLockScreen = true
        applyNowPlayingInfo(
            playbackRate: 0,
            elapsedSeconds: Date().timeIntervalSince(startedAt).truncatingRemainder(dividingBy: 60),
            albumHint: "Paused",
            forceLockScreenCard: true
        )
        logKeepAlive("Keep Alive: pause from lock screen — loop stopped")
    }

    private func stopFromLockScreen() {
        tearDownPlayback()
        try? configureAudioSession()
        ensureRemoteCommandsRegistered()
        NowPlayingFirstResponder.activate()
        applyNowPlayingInfo(
            playbackRate: 0,
            elapsedSeconds: 0,
            albumHint: "Stopped"
        )
        logKeepAlive("Keep Alive: stopped from lock screen (tap play to restart; export continues)")
    }

    private func toggleFromLockScreen() {
        logKeepAlive("Keep Alive: toggle from lock screen")
        if isQueuePlaying {
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
            logKeepAlive(
                String(
                    format: "Keep Alive: auto-stopped after %.0f h — tap play on lock screen to restart",
                    ExportKeepAliveSettings.timeoutHours
                )
            )
            stopFromLockScreen()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {}
}

private struct KeepAliveFailure: Error {
    let display: String

    static func stage(_ step: String, _ error: Error) -> KeepAliveFailure {
        let ns = error as NSError
        return KeepAliveFailure(
            display: "\(step): \(error.localizedDescription) (\(ns.domain) \(ns.code))"
        )
    }

    static func message(_ text: String) -> KeepAliveFailure {
        return KeepAliveFailure(display: text)
    }
}
