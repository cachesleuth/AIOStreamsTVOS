import AetherHost
import AVFoundation
import Foundation
import UIKit

/**
 * The audio session, set up for Dolby Atmos over HDMI.
 *
 * The category is declared at launch but the session is only activated when
 * a video starts, as AVKit does. Activating it at launch pins the HDMI route
 * to what the link reported then, and with Continuous Audio Connection off
 * that is 2 channels: multichannel PCM (lossless TrueHD and DTS-HD, rendered
 * Atmos beds) then plays downmixed (AetherEngine#24). The engine leaves
 * activation to the host on its native AVPlayer path, which has no
 * AVPlayerViewController here, so the app does it.
 */
enum AudioOutput {
    /// What the engine declares on tvOS: movie playback, long-form audio, multichannel.
    static func declare() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
            try session.setSupportsMultichannelContent(true)
        } catch {
            NSLog("[audio] category: %@", error.localizedDescription)
        }
        watchRoute()
    }

    private static var watchingRoute = false

    /// A route change is where an HDMI link that came up at 2 channels gets its full width.
    private static func watchRoute() {
        guard !watchingRoute else { return }
        watchingRoute = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { note in
            widen()
            // A new output or a wake can set the HDMI link up again at stereo. Not the route changes
            // a channel preference or the primer's own format change cause, or every video would prime.
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            switch raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) {
            case .newDeviceAvailable, .oldDeviceUnavailable, .wakeFromSleep, .override, .noSuitableRouteForCategory:
                linkMayHaveReset()
            default:
                break
            }
        }
        // The Apple TV sleeping suspends the app, and the TV and soundbar usually sleep with it.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { _ in linkMayHaveReset() }
    }

    private static let queue = DispatchQueue(label: "audio-session", qos: .userInitiated)

    /**
     * Activates the session off the main thread, as it can block, and asks
     * for every channel the route takes. Calls back on the main thread.
     */
    static func activate(_ done: @escaping () -> Void) {
        queue.async {
            let session = AVAudioSession.sharedInstance()
            do {
                if session.category != .playback { declare() }
                try session.setActive(true)
            } catch {
                NSLog("[audio] activate: %@", error.localizedDescription)
            }
            widenNow()
            NSLog("[audio] active: %@", routeSummary)
            DispatchQueue.main.async(execute: done)
        }
    }

    /**
     * The video has started playing. With Continuous Audio Connection off the
     * HDMI link idles at 2 channels and only widens once multichannel sound
     * plays, which is after activation and usually after the file has opened;
     * asked again then, multichannel PCM (TrueHD, DTS-HD) plays in full.
     */
    static func playbackStarted() {
        widen()
        for delay in [1.0, 3.0, 6.0] {
            queue.asyncAfter(deadline: .now() + delay) { widenNow() }
        }
        queue.asyncAfter(deadline: .now() + 6.5) { NSLog("[audio] playing: %@", routeSummary) }
    }

    private static func widen() {
        queue.async { widenNow() }
    }

    // MARK: Dolby primer

    /// Whether the primer has played since the Apple TV last went to sleep or the HDMI output last changed.
    private static var primed = false
    private static var primer: AVQueuePlayer?
    private static var primerLooper: AVPlayerLooper?
    private static var primerWatch: NSKeyValueObservation?
    /// What the primer last did, for the app menu and the diagnostics. Main thread only.
    static private(set) var lastPrime: String?

    /// How long the primer plays once it's playing, and the most it waits for that.
    private static let primerPlays: TimeInterval = 1.2
    private static let primerGivesUpAfter: TimeInterval = 4

    /**
     * With Continuous Audio Connection off, the HDMI link idles at stereo PCM, and sound the
     * Apple TV decodes (TrueHD, DTS-HD, anything shaped) plays downmixed into it, whichever
     * player plays it: asking the session for more channels doesn't widen it. A Dolby bitstream
     * does, and the link stays wide for the PCM that follows. Measured on an Apple TV 4K into a
     * Samsung TV and HW-Q990F on eARC: Infuse played TrueHD as stereo PCM, then as multichannel
     * PCM after a switch to the E-AC-3 track and back, and this app's TrueHD did too from then on.
     * Infuse users with Samsung soundbars report the same workaround.
     *
     * So before the first video after the Apple TV wakes or its HDMI output changes, a second of
     * silent Dolby Digital Plus Atmos plays, then the video loads. The stream is AetherEngine's
     * (`silent-atmos.mp4`, written bit by bit by its `Scripts/make-silent-atmos.swift`), decoding
     * to digital silence. Main thread; `done` is called on it.
     */
    static func primeLink(_ done: @escaping () -> Void) {
        guard !primed, primer == nil, routeIsHDMI,
              let url = Bundle.main.url(forResource: "silent-atmos", withExtension: "mp4") else {
            done()
            return
        }
        primed = true
        let before = routeSummary
        let player = AVQueuePlayer()
        player.automaticallyWaitsToMinimizeStalling = false
        primer = player
        primerLooper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        var finished = false
        func finish(_ played: Bool) {
            guard !finished else { return }
            finished = true
            primerWatch?.invalidate()
            primerWatch = nil
            player.pause()
            primerLooper?.disableLooping()
            primerLooper = nil
            player.removeAllItems()
            primer = nil
            let outcome = (played ? "played" : "didn't start in \(Int(primerGivesUpAfter)) s")
                + "; before: \(before); after: \(routeSummary)"
            lastPrime = outcome
            NSLog("[audio] Dolby primer: %@", outcome)
            done()
        }
        primerWatch = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            guard player.timeControlStatus == .playing else { return }
            DispatchQueue.main.async {
                primerWatch?.invalidate()
                primerWatch = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + primerPlays) { finish(true) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + primerGivesUpAfter) {
            // Still waiting to play: the link is left as it was.
            if primerWatch != nil { finish(false) }
        }
        player.play()
    }

    /// The link may have gone back to stereo: the next video primes it again.
    private static func linkMayHaveReset() {
        DispatchQueue.main.async { primed = false }
    }

    /**
     * Asks for every channel the route takes, if it now takes more than the
     * session has. Never asks for 2 or fewer: a preference of 2, written while
     * the link idles at stereo, holds the route at stereo once the link could
     * take more, which is what downmixed TrueHD with the setting off.
     */
    private static func widenNow() {
        let session = AVAudioSession.sharedInstance()
        let most = session.maximumOutputNumberOfChannels
        // Written only when it changes, so the route change a write causes ends here.
        guard most > 2, session.preferredOutputNumberOfChannels != most else { return }
        do {
            try session.setPreferredOutputNumberOfChannels(most)
            NSLog("[audio] widened: %@", routeSummary)
        } catch {
            NSLog("[audio] widen: %@", error.localizedDescription)
        }
    }

    /// Where the sound goes and how many channels it takes, for the diagnostics.
    static var routeSummary: String {
        let session = AVAudioSession.sharedInstance()
        let ports = session.currentRoute.outputs.map { port in
            "\(port.portName) (\(portName(port.portType)), \(port.channels?.count ?? 0) ch)"
        }
        return (ports.isEmpty ? "no output" : ports.joined(separator: ", "))
            + "; \(session.outputNumberOfChannels) of \(session.maximumOutputNumberOfChannels) channels in use"
            + ", \(session.preferredOutputNumberOfChannels) asked"
    }

    /// Every output is HDMI: the only route that carries Dolby MAT, so Atmos, from an Apple TV.
    static var routeIsHDMI: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return !outputs.isEmpty && outputs.allSatisfy { $0.portType == .HDMI }
    }

    private static func portName(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .HDMI: return "HDMI"
        case .airPlay: return "AirPlay"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "Bluetooth"
        default: return type.rawValue
        }
    }
}

/**
 * AetherEngine's log, into the app's log, with its recent audio lines kept
 * for the app menu and the diagnostics: whether Atmos went out as a stream
 * copy, or why not, is only in them.
 */
enum EngineLogBook {
    private static let lock = NSLock()
    private static var audio: [String] = []
    private static let kept = 14
    private static let audioWords = ["atmos", "eac3", "e-ac-3", "joc", "truehd", "dts", "audio", "mat ", "apac", "bridge", "spatial"]

    /// The engine calls the handler from its own threads, so this keeps no main-thread state.
    static func install() {
        EngineLog.handler = { line in
            NSLog("[aether] %@", line)
            let lower = line.lowercased()
            guard audioWords.contains(where: { lower.contains($0) }) else { return }
            lock.lock()
            audio.append(String(line.prefix(400)))
            if audio.count > kept { audio.removeFirst(audio.count - kept) }
            lock.unlock()
        }
    }

    static var recentAudio: [String] {
        lock.lock()
        defer { lock.unlock() }
        return audio
    }
}
