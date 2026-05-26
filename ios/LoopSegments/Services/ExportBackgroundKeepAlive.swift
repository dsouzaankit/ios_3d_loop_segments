import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// Loops muted local media (or synthetic tone) during export for lock-screen / background audio.
@MainActor
final class ExportBackgroundKeepAlive: NSObject, AVAudioPlayerDelegate {
    static let shared = ExportBackgroundKeepAlive()

    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var audioPlayer: AVAudioPlayer?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var playbackBackend = ""
    private var loopSourceLabel = ""
    private var timeoutTask: Task<Void, Never>?
    private var nowPlayingRefreshTask: Task<Void, Never>?
    private var exportSubtitle = ""
    private var startedAt = Date()
    private var exportSessionEligible = false
    private var remoteCommandsRegistered = false
    private var loopPlaying = false
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

    func stopForUserSettingOff() {
        let keepEligible = exportSessionEligible
        tearDownPlayback()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        unregisterRemoteCommands()
        NowPlayingFirstResponder.deactivate()
        deactivateAudioSessionIfIdle()
        exportSessionEligible = keepEligible
    }

    var isActive: Bool { queuePlayer != nil || audioPlayer != nil || audioEngine != nil }

    var isLoopPlaying: Bool { loopPlaying }

    // MARK: - Playback

    private func startPlayback() {
        tearDownPlayback()
        lastStartError = nil
        loopSourceLabel = ""
        let session = AVAudioSession.sharedInstance()
        let otherAudio = session.isOtherAudioPlaying
        do {
            try configureAudioSession()
            if let media = KeepAliveMediaSource.firstPlayable() {
                do {
                    try startMediaLoop(candidate: media)
                    playbackBackend = "AVPlayerLooper"
                    loopSourceLabel = media.label
                } catch let mediaError {
                    logKeepAlive(
                        "Keep Alive: media loop failed (\(Self.describeError(mediaError))), trying tone"
                    )
                    try startSyntheticTone()
                }
            } else {
                logKeepAlive("Keep Alive: no local media yet — using synthetic tone")
                try startSyntheticTone()
            }
            loopPlaying = true
            ensureRemoteCommandsRegistered()
            NowPlayingFirstResponder.activate()
            applyNowPlayingInfo(playbackRate: 1, elapsedSeconds: 0)
            startNowPlayingRefresh()
            scheduleTimeoutIfNeeded()
            let sourceNote = loopSourceLabel.isEmpty ? "" : " source=\(loopSourceLabel)"
            logKeepAlive(
                "Keep Alive: started via \(playbackBackend)\(sourceNote) (otherAudio=\(otherAudio))"
            )
        } catch {
            lastStartError = Self.describeError(error)
            logKeepAlive("Keep Alive: failed — \(lastStartError!)")
            tearDownPlayback()
        }
    }

    private func startSyntheticTone() throws {
        do {
            try startSilentPlayer()
            playbackBackend = "AVAudioPlayer"
        } catch let playerError {
            logKeepAlive(
                "Keep Alive: tone player failed (\(Self.describeError(playerError))), trying engine"
            )
            try startSilentEngine()
            playbackBackend = "AVAudioEngine"
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

    private func startSilentPlayer() throws {
        let wav = KeepAliveSilentWAV.data()
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: wav)
        } catch {
            throw KeepAliveFailure.stage("AVAudioPlayer init", error)
        }
        player.delegate = self
        player.numberOfLoops = -1
        player.volume = Self.playbackVolume
        guard player.prepareToPlay() else {
            throw KeepAliveFailure.message("AVAudioPlayer prepareToPlay returned false")
        }
        guard player.play() else {
            throw KeepAliveFailure.message("AVAudioPlayer play returned false")
        }
        audioPlayer = player
    }

    private func startSilentEngine() throws {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        let format = engine.outputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw KeepAliveFailure.message("invalid hardware output format")
        }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = Self.playbackVolume

        let frames = AVAudioFrameCount(format.sampleRate * 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw KeepAliveFailure.message("could not allocate PCM buffer")
        }
        buffer.frameLength = frames
        if let channels = buffer.floatChannelData {
            for ch in 0 ..< Int(format.channelCount) {
                memset(channels[ch], 0, Int(frames) * MemoryLayout<Float>.size)
            }
        }
        node.scheduleBuffer(buffer, at: nil, options: .loops)
        do {
            try engine.start()
        } catch {
            throw KeepAliveFailure.stage("AVAudioEngine.start", error)
        }
        node.play()
        audioEngine = engine
        playerNode = node
    }

    private func tearDownPlayback() {
        nowPlayingRefreshTask?.cancel()
        nowPlayingRefreshTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        loopPlaying = false
        playerLooper?.disableLooping()
        playerLooper = nil
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        queuePlayer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
        playbackBackend = ""
        loopSourceLabel = ""
    }

    private func stopFully() {
        tearDownPlayback()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        unregisterRemoteCommands()
        NowPlayingFirstResponder.deactivate()
        deactivateAudioSessionIfIdle()
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
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
        albumHint: String? = nil
    ) {
        let mutedSource = loopSourceLabel.isEmpty
            ? "Muted loop — export running"
            : "Muted loop of \(loopSourceLabel)"
        let hint = albumHint
            ?? (playbackRate > 0
                ? "\(mutedSource) — stop on lock screen when finished"
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
            while !Task.isCancelled, isActive {
                let elapsed = Date().timeIntervalSince(startedAt)
                    .truncatingRemainder(dividingBy: 60)
                let rate: Double = loopPlaying ? 1 : 0
                applyNowPlayingInfo(playbackRate: rate, elapsedSeconds: elapsed)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
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
        if let queue = queuePlayer, queue.timeControlStatus != .playing {
            queue.play()
            loopPlaying = true
            applyNowPlayingInfo(
                playbackRate: 1,
                elapsedSeconds: Date().timeIntervalSince(startedAt).truncatingRemainder(dividingBy: 60)
            )
            logKeepAlive("Keep Alive: resumed from lock screen (media loop)")
            return
        }
        if let player = audioPlayer, !player.isPlaying {
            player.play()
            loopPlaying = true
            applyNowPlayingInfo(
                playbackRate: 1,
                elapsedSeconds: Date().timeIntervalSince(startedAt).truncatingRemainder(dividingBy: 60)
            )
            logKeepAlive("Keep Alive: resumed from lock screen (tone)")
            return
        }
        if let node = playerNode, let engine = audioEngine, !engine.isRunning {
            try? engine.start()
            node.play()
            loopPlaying = true
            applyNowPlayingInfo(
                playbackRate: 1,
                elapsedSeconds: Date().timeIntervalSince(startedAt).truncatingRemainder(dividingBy: 60)
            )
            logKeepAlive("Keep Alive: resumed from lock screen (engine)")
            return
        }
        if isActive, loopPlaying { return }
        guard exportSessionEligible, ExportKeepAliveSettings.isEnabled else {
            logKeepAlive("Keep Alive: play ignored — no export session")
            return
        }
        startedAt = Date()
        startPlayback()
        logKeepAlive("Keep Alive: restarted from lock screen")
    }

    private func pauseFromLockScreen() {
        queuePlayer?.pause()
        audioPlayer?.pause()
        playerNode?.pause()
        loopPlaying = false
        applyNowPlayingInfo(
            playbackRate: 0,
            elapsedSeconds: Date().timeIntervalSince(startedAt).truncatingRemainder(dividingBy: 60),
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
        logKeepAlive("Keep Alive: stopped from lock screen (tap play to restart; export continues)")
    }

    private func toggleFromLockScreen() {
        if loopPlaying {
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

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            lastStartError = Self.describeError(error)
            logKeepAlive("Keep Alive: player decode error — \(lastStartError!)")
        }
    }
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
