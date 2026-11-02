import AetherHost
import UIKit

/**
 * AetherEngine's video beneath, its subtitles over it, the web app over both,
 * and the bridge between them. The web side follows the working
 * aiostreams-tvos project: a WKWebView loaded at runtime, given the whole
 * screen, focused so the page's focus ring shows, and the remote taken at the
 * window and handed to the page as keys.
 */
final class MainViewController: UIViewController, RemoteReceiver {
    private let videoView = AetherPlayerView(frame: .zero)
    private let subtitleView = SubtitleOverlay(frame: .zero)
    private var web: AIOWebView?
    private let status = UILabel()
    private var engine: AetherPlayer?
    private var player: PlayerChannel?
    private var pip: PictureInPicture?
    private let input = RemoteInput()
    private let storage = WebStorage()
    /// The page has said hello, so it takes Back.
    private var connected = false
    /// `aiostreams://` links, held until the page listens for them.
    private var links: [String] = []
    private var linksReady = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        AppFolders.create()

        for pane in [videoView, subtitleView] as [UIView] {
            pane.frame = view.bounds
            pane.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            pane.isHidden = true
            pane.isUserInteractionEnabled = false
            view.addSubview(pane)
        }
        videoView.backgroundColor = .black

        status.frame = view.bounds.insetBy(dx: 160, dy: 160)
        status.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        status.textColor = UIColor(white: 0.85, alpha: 1)
        status.font = .systemFont(ofSize: 36, weight: .medium)
        status.textAlignment = .center
        status.numberOfLines = 0

        guard let root = WebApp.root else {
            view.addSubview(status)
            return showStatus("The web app is missing from this build. Run scripts/fetch-web.sh, then build again.")
        }
        let web = AIOWebView(frame: view.bounds, scheme: WebApp.scheme, root: root)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(web)
        view.addSubview(status)
        self.web = web
        guard web.available else {
            return showStatus("This version of tvOS has no web engine the app can use.")
        }
        web.userAgent = Identity.userAgent
        web.onMessage = { [weak self] in self?.receive($0) }
        web.onLoadFinished = { [weak self] in
            self?.status.isHidden = true
            self?.web?.focusPage()
        }
        web.onLoadFailed = { [weak self] error in
            self?.connected = false
            self?.showStatus("The page couldn't load.\n\(error)\n\nHold Play/Pause for options.")
        }
        web.onProcessEnded = { [weak self] in
            // Most often memory; the page loads again where it was.
            MemoryLog.pageEnded(playing: self?.player?.playing == true)
            self?.flashStatus("The page ran out of memory and reloaded.")
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue.
            MainActor.assumeIsolated {
                MemoryLog.warning(playing: self?.player?.playing == true)
            }
        }
        web.onOpenURL = { [weak self] in self?.open($0) }
        web.onServed = { path, status, _ in
            if status != 200 { NSLog("[web] %ld for %@", status, path) }
        }
        web.thumbnailAtPath = { ThumbnailStore.image($0) }

        startPlayer()
        setUpInput()
        loadPage()
    }

    /**
     * Cancels tvOS's safe area for the whole screen: the page lays out edge to
     * edge and keeps its own margins, as on Android TV.
     */
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        let safe = view.safeAreaInsets
        let added = additionalSafeAreaInsets
        let cancel = UIEdgeInsets(
            top: -(safe.top - added.top), left: -(safe.left - added.left),
            bottom: -(safe.bottom - added.bottom), right: -(safe.right - added.right)
        )
        if added != cancel { additionalSafeAreaInsets = cancel }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        web?.focusPage()
    }

    // MARK: Page

    /// The bridge script carries the app's copy of the page's storage, so it's made fresh for each load.
    private func loadPage() {
        guard let web else { return }
        connected = false
        linksReady = false
        showStatus("Loading AIOStreams…")
        web.setStartScript(BridgeScript.make(
            version: "\(Identity.version)-tvos",
            device: Identity.device,
            deviceId: Identity.deviceId,
            storage: storage.json
        ))
        // `loadURL:` in Objective-C; Swift names it `load(_:)`.
        web.load(WebApp.startURL)
    }

    private func showStatus(_ text: String) {
        status.text = text
        status.isHidden = false
    }

    /// A notice that clears itself.
    private func flashStatus(_ text: String) {
        showStatus(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.status.text == text { self?.status.isHidden = true }
        }
    }

    private func sendToPage(_ message: Message) {
        guard let json = JSON.string(message) else { return }
        web?.evaluateJavaScript("window.__aioReceive&&window.__aioReceive(\(json))")
    }

    /// What the page was last told about the player's picture-in-picture button.
    private var pipButtonShown = false

    /// Shown while a video plays on the engine's AVPlayer and the page's Picture-in-picture setting is on.
    private func updatePipButton() {
        let offered = pip?.offered == true
        guard offered != pipButtonShown else { return }
        pipButtonShown = offered
        callTV("pip(\(offered))")
    }

    private func callTV(_ call: String) {
        web?.evaluateJavaScript("window.__aioTV&&window.__aioTV.\(call)")
    }

    private func jsString(_ text: String) -> String {
        JSON.string([text]).map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    // MARK: Player

    private func startPlayer() {
        do {
            let engine = try AetherPlayer(view: videoView, subtitles: subtitleView)
            self.engine = engine
            // Match Content's HDR10, HLG, Dolby Vision and frame rate are the engine's own to ask tvOS for.
            let player = PlayerChannel(
                player: engine,
                subtitlesDir: AppFolders.subtitles,
                send: { [weak self] in self?.sendToPage($0) },
                showVideo: { [weak self] shown in
                    self?.videoView.isHidden = !shown
                    self?.subtitleView.isHidden = !shown
                }
            )
            self.player = player
            let pip = PictureInPicture(player: engine, channel: player, send: { [weak self] in self?.sendToPage($0) })
            pip.failed = { [weak self] in self?.flashStatus($0) }
            pip.window = { [weak self] in self?.view.window }
            pip.ended = { [weak self] in
                self?.web?.focusPage()
                self?.updatePipButton()
            }
            player.onStopped = { [weak pip] in pip?.stop() }
            // The engine's AVPlayer layer is there once a video has loaded.
            player.onPlayerEvent = { [weak self] in self?.updatePipButton() }
            self.pip = pip
        } catch {
            NSLog("[app] AetherEngine did not start: %@", String(describing: error))
        }
    }

    // MARK: Remote

    var takesRemote: Bool { presentedViewController == nil && web?.available == true }

    func remotePress(_ press: UIPress) {
        input.press(press)
    }

    func remoteTouches(_ touches: Set<UITouch>) {
        input.touches(touches)
    }

    private func setUpInput() {
        input.keyDown = { [weak self] key, repeated in
            guard let self else { return }
            self.callTV("down(\(self.jsString(key)),\(repeated))")
        }
        input.keyUp = { [weak self] key in
            guard let self else { return }
            self.callTV("up(\(self.jsString(key)))")
        }
        input.back = { [weak self] in
            guard let self else { return }
            if self.connected { self.sendToPage(["type": "back"]) } else { self.leaveApp() }
        }
        input.menu = { [weak self] in self?.showAppMenu() }
    }

    private func leaveApp() {
        player?.change(Change(paused: true))
        suspendApp()
    }

    // MARK: The app's own screens

    /// With how the video and its sound play, to see why HDR or Atmos doesn't reach the TV.
    private func showAppMenu() {
        guard presentedViewController == nil else { return }
        // In steps: as one expression, the compiler gives up type-checking it.
        var lines: [String] = ["App \(Identity.version) · web app \(WebApp.commit) · \(storage.keyCount) saved keys", ""]
        lines += AppAnswers.videoLines(player: engine, window: view.window)
        lines.append("")
        lines += MemoryLog.report
        lines.append("")
        lines += PictureInPicture.report
        lines.append("")
        lines += TopShelf.report
        let menu = AppMenu(title: "AIOStreams", text: lines.joined(separator: "\n"), actions: [
            AppMenu.Action(title: "Reload", destructive: false) { [weak self] in self?.loadPage() },
            AppMenu.Action(title: "Reset the app's data", destructive: true) { [weak self] in self?.confirmReset() },
            AppMenu.Action(title: "Close", destructive: false) {},
        ])
        // However it closed: an action, Close or Menu.
        menu.closed = { [weak self] in self?.web?.focusPage() }
        present(menu, animated: true)
    }

    private func confirmReset() {
        let confirm = UIAlertController(
            title: "Reset the app's data?",
            message: "This signs you out and forgets your servers and settings on this Apple TV.",
            preferredStyle: .alert
        )
        confirm.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.storage.clear()
            self.web?.removeAllWebData { [weak self] in self?.loadPage() }
        })
        confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.web?.focusPage()
        })
        present(confirm, animated: true)
    }

    /**
     * tvOS has no keyboard for a web page, so a field the page asks for opens
     * the system's, with dictation. Most fields get the search keyboard over
     * the page, typing straight into the field; passwords and PINs get the
     * alert, which keeps them hidden and sends a PIN's form on Done.
     */
    private func showKeyboard(_ message: Message) {
        guard presentedViewController == nil else { return }
        if message.flag("secure") == true || message.flag("numeric") == true { return showKeyboardAlert(message) }
        let keyboard = SearchKeyboard(
            text: message.text("value") ?? "",
            prompt: message.text("label") ?? "",
            keyboardType: message.flag("email") == true ? .emailAddress : message.flag("url") == true ? .URL : .default,
            onChange: { [weak self] text in
                guard let self else { return }
                self.callTV("input(\(self.jsString(text)))")
            },
            onClose: { [weak self] submit in
                guard let self else { return }
                self.keyboard = nil
                self.callTV("done(\(submit))")
                self.web?.focusPage()
            }
        )
        self.keyboard = keyboard
        present(keyboard.controller, animated: true)
    }

    /// The keyboard open over the page, kept until it closes.
    private var keyboard: SearchKeyboard?

    private func showKeyboardAlert(_ message: Message) {
        let label = message.text("label") ?? ""
        let alert = UIAlertController(title: label.isEmpty ? "Enter text" : label, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = message.text("value") ?? ""
            field.isSecureTextEntry = message.flag("secure") == true
            if message.flag("email") == true { field.keyboardType = .emailAddress }
            if message.flag("url") == true { field.keyboardType = .URL }
            // A PIN gets the digits-only keyboard.
            if message.flag("numeric") == true { field.keyboardType = .numberPad }
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Done", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let text = alert?.textFields?.first?.text ?? ""
            // A PIN is the last thing its form asks for, so Done sends it.
            let submit = message.flag("numeric") == true
            self.callTV("type(\(self.jsString(text)),\(submit))")
            self.web?.focusPage()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.web?.focusPage()
        })
        present(alert, animated: true) { [weak alert] in
            // Straight to the keyboard rather than the alert's field.
            alert?.textFields?.first?.becomeFirstResponder()
        }
    }

    // MARK: Links

    /// A link out of the page: an `aiostreams://` link for the page, or another app's, such as a player's.
    private func open(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "aiostreams" { return receiveLink(url.absoluteString) }
        // A TV has no browser for a web link.
        if scheme == "http" || scheme == "https" { return }
        UIApplication.shared.open(url) { [weak self] opened in
            guard !opened else { return }
            self?.flashStatus("Couldn't open the player. Check that the app for \(scheme):// links is installed.")
        }
    }

    /// From the system, or a link in the page.
    func receiveLink(_ url: String) {
        guard url.lowercased().hasPrefix("aiostreams://") else { return }
        links.append(url)
        sendLinks()
    }

    private func sendLinks() {
        while linksReady, !links.isEmpty {
            sendToPage(["type": "link", "url": links.removeFirst()])
        }
    }

    // MARK: Messages

    private func receive(_ message: Message) {
        guard let type = message.text("type") else { return }
        if player?.handle(type, message) == true {
            // A load, a stop or a new item may show or hide the player's picture-in-picture button.
            updatePipButton()
            return
        }
        switch type {
        case "hello":
            connected = true
            status.isHidden = true
            web?.focusPage()
            pipButtonShown = false
            updatePipButton()
        case "tvos-pip":
            // The player's picture-in-picture button, which the bridge script adds.
            pip?.start()
        case "app-info":
            sendToPage(AppAnswers.appInfo())
        case "player-engine":
            // The page asks for its engine choice; this app has only AetherEngine. Like the Android app's
            // ExoPlayer, it plays on the system's decoders and has no mpv options, so the page treats it as
            // that: it hides mpv's settings and asks for ExoPlayer-style statistics (`player-stats`).
            sendToPage(["type": "player-engine", "name": "exoplayer"])
        case "fullscreen":
            sendToPage(["type": "fullscreen", "value": true])
        case "levels":
            sendToPage(["type": "levels", "volume": 1.0, "brightness": 1.0])
        case "links-ready":
            linksReady = true
            sendLinks()
        case "exit":
            leaveApp()
        case "tvos-storage":
            storage.apply(message)
        case "watch-next":
            // Continue Watching and Next Up, for the Top Shelf.
            TopShelf.publish(message)
        case "tvos-keyboard":
            showKeyboard(message)
        case "mpv-config", "mpv-config-save":
            sendToPage(["type": "mpv-config", "text": MPVConfig.text])
        case "diagnostics":
            sendToPage(AppAnswers.diagnostics(
                player: engine, window: view.window,
                web: message.text("web"), server: message.text("server")
            ))
        case "licenses":
            sendToPage(AppAnswers.licenses)
        case "crash-report":
            sendToPage(["type": "crash-report"])
        case "update-check", "update-apply":
            sendToPage(AppAnswers.updateState)
        case "youtube-resolve":
            // A trailer: its stream, for the player. Without one the page opens the link, which the YouTube app takes.
            let request = message.text("request") ?? ""
            YouTube.resolve(message.text("id") ?? "") { [weak self] url in
                self?.sendToPage(["type": "youtube-resolved", "request": request, "url": nullable(url)])
            }
        case "voice-search":
            // Dictation is on the keyboard's microphone; the page doesn't offer its own here.
            sendToPage(["type": "voice-result", "text": NSNull(), "error": "failed"])
        case "web-error":
            NSLog("[page] %@", message.text("message") ?? "")
        default:
            // Downloads, keyboard completions and the like have no Apple TV part.
            break
        }
    }

    // MARK: App state

    func appWillResignActive() {
        storage.save()
        input.stopRepeating()
        pip?.appWillResignActive()
        // The picture-in-picture window keeps playing over the Home screen.
        if pip?.active != true { player?.change(Change(paused: true)) }
    }

    /// The player opens a video again that tvOS made it let go of in the background (`AetherPlayer`);
    /// a picture-in-picture window comes back into the app.
    func appDidBecomeActive() {
        pip?.appDidBecomeActive()
        web?.focusPage()
    }
}
