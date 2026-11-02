import AetherHost
import AVKit
import UIKit

/**
 * The video in a small window over the Home screen and other apps, as the
 * Android app's picture-in-picture. The page turns it on and off with its
 * Picture-in-picture setting, which comes in each `now-playing` item, and
 * hides its player while the window shows (`pip` messages), as on Android.
 *
 * Android enters it on leaving the app; tvOS only starts it from inside the
 * app, so it starts from a button the bridge script adds to the page's player
 * controls, and the app then steps back to the Home screen. Coming back to the
 * app, or the window's full-screen button, puts the video back in the app;
 * closing the window pauses it, as on Android.
 *
 * It takes AetherEngine's AVPlayerLayer (`nativePlayerLayer`), which tvOS
 * puts in the window as it does for Apple's own player; the window's controls
 * drive AVPlayer directly. A video the engine decodes itself (its software
 * route) draws into a sample buffer display layer, which tvOS never allows in
 * the window (FB9751461), so those get no button. The engine's native
 * subtitle rendition carries text subtitles into the window, as the app's own
 * overlay can't leave the app.
 */
@MainActor
final class PictureInPicture: NSObject {
    private let player: AetherPlayer
    private let channel: PlayerChannel
    private let send: (Message) -> Void
    private var controller: AVPictureInPictureController?
    /// Watches for tvOS to allow the window after a press, and gives up after a while.
    private var possible: NSKeyValueObservation?
    private var waiting: DispatchWorkItem?
    /// The window's full-screen button, or the app coming back, rather than its close button.
    private var restoring = false
    /// The app went to the background with the window showing.
    private var left = false

    /// The window couldn't start, with why, for the user.
    var failed: (String) -> Void = { _ in }
    /// The video is back in the app, or stopped, and the page is the app's again.
    var ended: () -> Void = {}

    init(player: AetherPlayer, channel: PlayerChannel, send: @escaping (Message) -> Void) {
        self.player = player
        self.channel = channel
        self.send = send
        super.init()
        // Which mode the TV is in: a switch while a video is loaded is to the video's own mode,
        // one with none loaded is back to the Home screen's, as the engine resets it on stopping.
        modeObserver = NotificationCenter.default.addObserver(
            forName: .AVDisplayManagerModeSwitchStart, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.switchingMode, self.heldCriteria == nil else { return }
                self.inVideoMode = self.channel.playing
            }
        }
    }

    private var modeObserver: NSObjectProtocol?
    /// The TV switched to a mode for the video, so it isn't in the Home screen's.
    private var inVideoMode = false

    private let supported = AVPictureInPictureController.isPictureInPictureSupported()

    var active: Bool { controller?.isPictureInPictureActive == true }

    /// The player's button shows: a video plays on the engine's AVPlayer and the page's setting allows it.
    var offered: Bool {
        supported && !active && channel.playing && channel.pictureInPictureAllowed
            && player.engine.nativePlayerLayer != nil
    }

    /**
     * Makes the controller for the session's layer at the press and starts the
     * window as soon as tvOS allows it, which it decides once the layer is on
     * screen with a picture in it.
     */
    func start() {
        guard supported else { return failed("This Apple TV has no picture-in-picture.") }
        guard player.engine.nativePlayerLayer != nil else {
            return failed("Picture-in-picture isn't available for this video.")
        }
        guard !active, waiting == nil, !switchingMode else { return }
        pressedAt = CACurrentMediaTime()
        Self.trace = []
        // In steps: as one expression, the compiler can give up type-checking it.
        let mode: String = inVideoMode ? "the video switched the TV" : "the TV is in the Home screen's mode"
        let hasCriteria: Bool = window()?.avDisplayManager?.preferredDisplayCriteria != nil
        let criteria: String = hasCriteria ? "has display criteria" : "no display criteria"
        step("button pressed; " + mode + ", " + criteria)
        // Made now, so tvOS weighs up the window during the switch rather than after it.
        guard prepareController() != nil else {
            return failed("Picture-in-picture isn't available for this video.")
        }
        // The engine's HDR or frame-rate mode goes first, in the app, where a paused video can be played
        // again; the window then opens on the Home screen's own mode, so tvOS has nothing to switch.
        // A video that left the TV in the Home screen's mode opens the window straight away.
        guard inVideoMode, let manager = window()?.avDisplayManager,
              let criteria = manager.preferredDisplayCriteria else {
            return openWindow()
        }
        heldCriteria = criteria
        let resume = player.engine.state == .playing
        step("dropping the video's display mode")
        manager.preferredDisplayCriteria = nil
        settleDisplayMode(manager, resume: resume) { [weak self] in
            guard let self else { return }
            guard self.channel.playing else { return self.putBackDisplayMode() }
            self.openWindow()
        }
    }

    /// The controller for the session's layer: a new video has a new layer, so a new controller.
    private func prepareController() -> AVPictureInPictureController? {
        guard let layer = player.engine.nativePlayerLayer else { return nil }
        if let controller, controller.playerLayer === layer { return controller }
        guard let made = AVPictureInPictureController(playerLayer: layer) else { return nil }
        made.delegate = self
        controller = made
        return made
    }

    private func openWindow() {
        guard let controller = prepareController() else {
            putBackDisplayMode()
            return failed("Picture-in-picture isn't available for this video.")
        }
        if controller.isPictureInPicturePossible { return begin(controller) }
        step("waiting for tvOS to allow the window")
        possible = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] controller, _ in
            guard controller.isPictureInPicturePossible else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.begin(controller) } }
        }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.waiting != nil else { return }
                self.endWaiting()
                self.step("tvOS didn't allow the window in time")
                self.putBackDisplayMode()
                self.failed("Picture-in-picture isn't available for this video right now.")
            }
        }
        waiting = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.allowTime, execute: item)
    }

    private func begin(_ controller: AVPictureInPictureController) {
        guard controller === self.controller, !controller.isPictureInPictureActive else { return }
        let waited: Bool = waiting != nil
        step(waited ? "tvOS allowed the window; starting it" : "window allowed; starting it")
        endWaiting()
        controller.startPictureInPicture()
    }

    // MARK: Timing

    /// The last start's steps, timed from the press, for the app menu.
    private(set) static var trace: [String] = []
    private var pressedAt: CFTimeInterval = 0

    private func step(_ what: String) {
        let elapsed: Double = CACurrentMediaTime() - pressedAt
        let line: String = String(format: "+%.2f s  ", elapsed) + what
        NSLog("[pip] %@", line)
        Self.trace.append(line)
        if Self.trace.count > 20 { Self.trace.removeFirst() }
    }

    /// For the app menu: how long the last start took, step by step.
    static var report: [String] {
        if trace.isEmpty { return ["Picture in picture: not started yet"] }
        var lines: [String] = ["Picture in picture, last start:"]
        lines.append(contentsOf: trace)
        return lines
    }

    // MARK: Leaving for the Home screen

    /**
     * Back to the Home screen once the window shows. tvOS doesn't always take
     * the first ask while the window is still settling, so it's asked again
     * until the app has gone, three times at most.
     */
    private func leaveApp(attempt: Int = 1) {
        guard active, UIApplication.shared.applicationState == .active else { return }
        step("to the Home screen (try \(attempt))")
        suspendApp()
        guard attempt < 3 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated { self?.leaveApp(attempt: attempt + 1) }
        }
    }

    private func endWaiting() {
        possible = nil
        waiting?.cancel()
        waiting = nil
    }

    func stop() {
        // Still waiting for tvOS to allow it: the press is dropped.
        if waiting != nil {
            endWaiting()
            putBackDisplayMode()
        }
        guard active else { return }
        restoring = true
        controller?.stopPictureInPicture()
    }

    private static let allowTime: TimeInterval = 4

    func appWillResignActive() {
        if active { left = true }
    }

    /// Back in the app, the video comes back with it.
    func appDidBecomeActive() {
        // The window closed while the app was away: the video's mode comes back with the app.
        if !active, !left { putBackDisplayMode() }
        guard left else { return }
        left = false
        stop()
    }

    // MARK: The display mode

    /// The window the video plays in, whose display manager holds the engine's HDR or frame-rate mode.
    var window: () -> UIWindow? = { nil }
    /// The engine's display criteria, held while the window shows and put back when the video returns.
    private var heldCriteria: AVDisplayCriteria?
    private var modeWatch: Timer?
    private var switchSeen = false
    private var switchingMode: Bool { modeWatch != nil }

    /**
     * An HDR video, or one at its own frame rate, has the TV in a mode of its
     * own. tvOS gives the Home screen back its mode when the window opens, and
     * that switch, in the background, left the window's video paused for good.
     * So the app switches first, in the app, waits for the TV to settle, and
     * plays the video again if the switch paused it.
     */
    private func settleDisplayMode(_ manager: AVDisplayManager, resume: Bool, then: @escaping () -> Void) {
        modeWatch?.invalidate()
        if let switchEnd { NotificationCenter.default.removeObserver(switchEnd) }
        switchEnd = nil
        switchSeen = false
        let began = CACurrentMediaTime()
        let finish: @MainActor (String) -> Void = { [weak self] how in
            guard let self, self.modeWatch != nil else { return }
            self.modeWatch?.invalidate()
            self.modeWatch = nil
            if let observer = self.switchEnd { NotificationCenter.default.removeObserver(observer) }
            self.switchEnd = nil
            let took: Double = CACurrentMediaTime() - began
            self.step("display mode " + how + String(format: " (%.2f s)", took))
            if resume, self.channel.playing, self.player.engine.state != .playing {
                self.step("the switch paused the video; playing it again")
                self.channel.change(Change(paused: false))
            }
            then()
        }
        // tvOS says when the switch ends, the moment the picture is back.
        switchEnd = NotificationCenter.default.addObserver(
            forName: .AVDisplayManagerModeSwitchEnd, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { finish("switched") }
        }
        modeWatch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = CACurrentMediaTime() - began
                if manager.isDisplayModeSwitchInProgress { self.switchSeen = true }
                // A switch starts within half a second of the write, or there is none (the modes matched).
                if !self.switchSeen, elapsed > 0.5 { return finish("unchanged") }
                if self.switchSeen, !manager.isDisplayModeSwitchInProgress { return finish("switched (polled)") }
                if elapsed > Self.switchTime { finish("still switching; going on") }
            }
        }
    }

    private var switchEnd: NSObjectProtocol?

    /// Back to the video's own mode, once it's in the app again.
    private func putBackDisplayMode() {
        guard let criteria = heldCriteria else { return }
        heldCriteria = nil
        // A video the page closed has no mode to go back to; the engine reset it on stopping.
        guard channel.playing, let manager = window()?.avDisplayManager else { return }
        let resume = player.engine.state == .playing
        manager.preferredDisplayCriteria = criteria
        settleDisplayMode(manager, resume: resume) {}
    }

    /// The longest a switch is waited for: a dynamic-range switch takes about 3 seconds.
    private static let switchTime: CFTimeInterval = 8
}

// MARK: AVPictureInPictureControllerDelegate

extension PictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            step("window starting")
            // The engine keeps the session through the background while the window shows.
            player.setPictureInPicture(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            step("window showing")
            restoring = false
            send(["type": "pip", "value": true])
            // Off to the Home screen, as Android leaves the app; the window stays over it. The text
            // subtitles go into the window after that, so fetching them holds nothing up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.leaveApp() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.player.showSubtitlesInWindow() }
            }
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        let reason = error.localizedDescription
        MainActor.assumeIsolated {
            step("didn't start: \(reason)")
            endWaiting()
            player.setPictureInPicture(false)
            putBackDisplayMode()
            failed("Picture-in-picture didn't start: \(reason)")
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        MainActor.assumeIsolated { restoring = true }
        completionHandler(true)
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            player.setPictureInPicture(false)
            // Closing the window, rather than bringing it back full size, stops playback, as on Android.
            if !restoring { channel.change(Change(paused: true)) }
            restoring = false
            left = false
            // In the app again, the video's mode comes back; closed out on the Home screen, it waits for the app.
            if UIApplication.shared.applicationState != .background { putBackDisplayMode() }
            send(["type": "pip", "value": false])
            ended()
        }
    }
}
