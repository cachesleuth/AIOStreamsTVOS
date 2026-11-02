import AVFoundation
import AVKit
import UIKit

/**
 * The video in a small window over the Home screen and other apps, as the
 * Android app's picture-in-picture. The page turns it on and off with its
 * Picture-in-picture setting, which comes in each `now-playing` item, and
 * hides its player while the window shows (`pip` messages), as on Android.
 *
 * Android enters it on leaving the app; tvOS only starts it from inside the
 * app, so it starts from a button the bridge script adds to the page's
 * player controls, and the app then steps back to the Home screen. Coming back to the app, or the window's full-screen button,
 * puts the video back in the app; closing the window pauses it, as on Android.
 *
 * mpv's display layer goes into the window as it is, through
 * AVPictureInPictureController's sample buffer source (tvOS 15), as MPVKit's
 * own demo does. All on the main thread.
 */
final class PictureInPicture: NSObject {
    private let layer: AVSampleBufferDisplayLayer
    private let player: PlayerChannel
    private let engine: MPVEngine
    private let send: (Message) -> Void
    private var controller: AVPictureInPictureController?
    private var subtitles: PictureInPictureSubtitles?
    private var status: NSKeyValueObservation?
    /// The window's full-screen button, or the app coming back, rather than its close button.
    private var restoring = false
    /// The app went to the background with the window showing.
    private var left = false

    /// The window couldn't start, with why, for the user.
    var failed: (String) -> Void = { _ in }
    /// The video is back in the app, or stopped, and the page is the app's again.
    var ended: () -> Void = {}

    init(layer: AVSampleBufferDisplayLayer, player: PlayerChannel, engine: MPVEngine, send: @escaping (Message) -> Void) {
        self.layer = layer
        self.player = player
        self.engine = engine
        self.send = send
        super.init()
    }

    /**
     * Off: on tvOS, `isPictureInPicturePossible` never becomes true for a
     * sample buffer display layer, from tvOS 15 to at least tvOS 26, as
     * PiPBugDemo shows (Apple feedback FB9751461): tvOS never asks the
     * playback delegate for the range and paused state, as iOS does. Turning
     * this on, with `pip: true` in the bridge script and the `audio`
     * background mode, brings the button and the page's setting back.
     */
    static let enabled = false

    private let supported = PictureInPicture.enabled && AVPictureInPictureController.isPictureInPictureSupported()
    /// Watches for tvOS to allow the window after a press, and gives up after a while.
    private var possible: NSKeyValueObservation?
    private var waiting: DispatchWorkItem?
    /// The layer's clock, there while the window starts or shows.
    private var timebase: CMTimebase?
    private var clockTimer: Timer?

    var active: Bool { controller?.isPictureInPictureActive == true }

    /// The player's button shows: a video plays and the page's setting allows it.
    var offered: Bool { supported && !active && player.playing && player.pictureInPictureAllowed }

    /**
     * tvOS only allows the window for a display layer with a clock it can read
     * the position from, as MPVKit's demo gives it, and decides once the layer
     * is on screen with frames in it. So each press gives the layer a clock
     * that follows mpv, makes the controller then, and starts the window as
     * soon as tvOS allows it. mpv stamps each frame with the clock's time, so
     * frames still show as they come.
     */
    func start() {
        guard supported else { return failed("This Apple TV has no picture-in-picture.") }
        guard !active, waiting == nil else { return }
        startClock()
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        self.controller = controller
        if controller.isPictureInPicturePossible { return begin(controller) }
        possible = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] controller, _ in
            guard controller.isPictureInPicturePossible else { return }
            DispatchQueue.main.async { self?.begin(controller) }
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.waiting != nil else { return }
            self.endWaiting()
            NSLog("[pip] tvOS didn't allow the window in time")
            self.stopClock()
            self.failed("Picture-in-picture isn't available for this video right now.")
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
        if waiting != nil {
            // Still waiting for tvOS to allow it: the press is dropped.
            endWaiting()
            stopClock()
        }
        guard active else { return }
        restoring = true
        controller?.stopPictureInPicture()
    }

    /// Paused, resumed or a new length: the window's controls ask again.
    func playbackChanged() {
        syncClock()
        if active { controller?.invalidatePlaybackState() }
    }

    // MARK: The layer's clock

    private func startClock() {
        if timebase == nil {
            var made: CMTimebase?
            CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &made)
            guard let made else { return }
            timebase = made
            layer.controlTimebase = made
        }
        syncClock(force: true)
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.syncClock() }
    }

    /// Follows mpv's position and rate, moved only when it has drifted, so frames don't jump.
    private func syncClock(force: Bool = false) {
        guard let timebase else { return }
        let rate = player.paused ? 0 : player.speed
        let at = player.positionMs / 1000
        let now = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
        if force || !now.isFinite || abs(now - at) > 0.5 {
            CMTimebaseSetTime(timebase, time: CMTime(seconds: at, preferredTimescale: 1000))
        }
        if force || CMTimebaseGetRate(timebase) != rate { CMTimebaseSetRate(timebase, rate: rate) }
    }

    /// Back to how the player shows frames outside the window.
    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
        guard timebase != nil else { return }
        layer.controlTimebase = nil
        timebase = nil
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

    /**
     * tvOS can end VideoToolbox's decoder while the app is in the background,
     * which leaves the window black; mpv starts a new one, as MPVKit's demo does.
     */
    private func watchDecoder() {
        status = layer.observe(\.status, options: [.new]) { [weak self] layer, _ in
            guard layer.status == .failed else { return }
            DispatchQueue.main.async {
                NSLog("[pip] the display layer failed; restarting the decoder")
                self?.engine.restartDecoder()
            }
        }
    }
}

// MARK: AVPictureInPictureControllerDelegate

extension PictureInPicture: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        restoring = false
        watchDecoder()
        subtitles = PictureInPictureSubtitles(layer: layer)
        send(["type": "pip", "value": true])
        // Off to the Home screen, as Android leaves the app; the window stays over it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if self?.active == true { suspendApp() }
        }
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        NSLog("[pip] didn't start: %@", error.localizedDescription)
        endWaiting()
        stopClock()
        failed("Picture-in-picture didn't start: \(error.localizedDescription)")
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        restoring = true
        completionHandler(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        status = nil
        stopClock()
        subtitles?.stop()
        subtitles = nil
        // Closing the window, rather than bringing it back full size, stops playback, as on Android.
        if !restoring { player.change(Change(paused: true)) }
        restoring = false
        left = false
        send(["type": "pip", "value": false])
        ended()
    }
}

// MARK: AVPictureInPictureSampleBufferPlaybackDelegate

extension PictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        player.change(Change(paused: !playing))
    }

    /// On the layer's clock, which follows mpv's position, so the window's progress moves.
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        let duration = player.durationMs / 1000
        guard duration > 0 else { return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        player.paused
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        player.skip(byMs: CMTimeGetSeconds(skipInterval) * 1000)
        completionHandler()
    }
}

/**
 * The subtitles in the window. mpv draws them on a layer of their own over
 * the video (`mpv-osd`), which the window doesn't carry, so its picture is
 * copied over the window each frame, as MPVKit's demo does. Without the
 * window found, the window goes without subtitles.
 */
private final class PictureInPictureSubtitles: NSObject {
    private weak var layer: AVSampleBufferDisplayLayer?
    private weak var window: UIWindow?
    private var view: UIImageView?
    private var link: CADisplayLink?
    private var stopped = false

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
        super.init()
        // Once the window has appeared.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.stopped else { return }
            self.attach()
        }
    }

    /// The display link holds on to this, so it goes only when stopped.
    func stop() {
        stopped = true
        link?.invalidate()
        link = nil
        view?.removeFromSuperview()
        view = nil
    }

    private func attach() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: { String(describing: type(of: $0)).contains("PGHostedWindow") }) else {
            return NSLog("[pip] no window to draw subtitles in")
        }
        self.window = window
        let view = UIImageView(frame: window.bounds)
        view.contentMode = .scaleAspectFit
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        window.addSubview(view)
        self.view = view
        let link = CADisplayLink(target: self, selector: #selector(copySubtitles))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func copySubtitles() {
        guard let view else { return }
        let osd = layer?.sublayers?.first { $0.name == "mpv-osd" }
        if let contents = osd?.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
            view.image = UIImage(cgImage: contents as! CGImage)
        } else {
            view.image = nil
        }
        if let window { view.frame = window.bounds }
    }
}
