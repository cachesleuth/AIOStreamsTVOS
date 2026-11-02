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
    }

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
        guard let layer = player.engine.nativePlayerLayer else {
            return failed("Picture-in-picture isn't available for this video.")
        }
        guard !active, waiting == nil else { return }
        // The layer is the session's: a new video has a new one, so a new controller.
        if controller?.playerLayer !== layer {
            guard let made = AVPictureInPictureController(playerLayer: layer) else {
                return failed("Picture-in-picture isn't available for this video.")
            }
            made.delegate = self
            controller = made
        }
        guard let controller else { return }
        if controller.isPictureInPicturePossible { return begin(controller) }
        possible = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] controller, _ in
            guard controller.isPictureInPicturePossible else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.begin(controller) } }
        }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.waiting != nil else { return }
                self.endWaiting()
                NSLog("[pip] tvOS didn't allow the window in time")
                self.failed("Picture-in-picture isn't available for this video right now.")
            }
        }
        waiting = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.allowTime, execute: item)
    }

    private func begin(_ controller: AVPictureInPictureController) {
        guard controller === self.controller, !controller.isPictureInPictureActive else { return }
        endWaiting()
        controller.startPictureInPicture()
    }

    private func endWaiting() {
        possible = nil
        waiting?.cancel()
        waiting = nil
    }

    func stop() {
        // Still waiting for tvOS to allow it: the press is dropped.
        if waiting != nil { endWaiting() }
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
        guard left else { return }
        left = false
        stop()
    }
}

// MARK: AVPictureInPictureControllerDelegate

extension PictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            // The engine keeps the session through the background while the window shows.
            player.setPictureInPicture(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            restoring = false
            send(["type": "pip", "value": true])
            // Off to the Home screen, as Android leaves the app; the window stays over it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated {
                    if self?.active == true { suspendApp() }
                }
            }
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        let reason = error.localizedDescription
        MainActor.assumeIsolated {
            NSLog("[pip] didn't start: %@", reason)
            endWaiting()
            player.setPictureInPicture(false)
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
            send(["type": "pip", "value": false])
            ended()
        }
    }
}
