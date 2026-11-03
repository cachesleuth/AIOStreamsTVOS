import AetherHost
import AVFoundation
import Foundation

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
        ) { _ in widen() }
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

    /// What the last relink did, for the app menu and the diagnostics. Main thread only.
    static var lastRelink: String?

    /// Whether the HDMI link is at stereo or less while every output is HDMI: the case `relink` is for.
    static var linkIsNarrow: Bool {
        routeIsHDMI && AVAudioSession.sharedInstance().outputNumberOfChannels <= 2
    }

    /**
     * An experiment for Continuous Audio Connection off: the session is turned off and on again
     * once a multichannel track the Apple TV decodes has loaded, so tvOS sets the HDMI link up
     * again knowing the sound is multichannel. Asking for more channels on an active session
     * leaves the link at 2 (`2 of 32 channels in use, 8 asked`), whichever player plays the sound.
     *
     * `pause` and `resume` run on the main thread around it: tvOS refuses to turn off a session
     * whose sound is playing (`isBusy`), so the player pauses first and is retried a few times
     * while its output winds down. `done` gets the outcome, on the main thread.
     */
    static func relink(pause: @escaping () -> Void, resume: @escaping () -> Void,
                       done: @escaping (String) -> Void) {
        let before = routeSummary
        pause()
        queue.async {
            let session = AVAudioSession.sharedInstance()
            var deactivated = false
            var lastError: Error?
            for _ in 0..<6 {
                Thread.sleep(forTimeInterval: 0.25)
                do {
                    try session.setActive(false)
                    deactivated = true
                    break
                } catch {
                    lastError = error
                }
            }
            do {
                try session.setActive(true)
            } catch {
                NSLog("[audio] relink reactivate: %@", error.localizedDescription)
            }
            widenNow()
            // The link takes a moment to settle after activation.
            Thread.sleep(forTimeInterval: 0.5)
            widenNow()
            let after = routeSummary
            let outcome = deactivated
                ? "session off and on; before: \(before); after: \(after)"
                : "session wouldn't turn off (\(lastError?.localizedDescription ?? "?")); \(after)"
            NSLog("[audio] relink: %@", outcome)
            DispatchQueue.main.async {
                resume()
                done(outcome)
            }
        }
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
