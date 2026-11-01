import JavaScriptCore
import UIKit

/// mpv's video beneath, the web app over it, and the bridge between them.
final class MainViewController: UIViewController {
    private let videoView = UIView()
    private let videoLayer = MetalLayer()
    private var web: LegacyWebView?
    private let webDelegate = WebViewDelegate()
    private var bridge: AppBridge!
    private var engine: MPVEngine?
    private var player: PlayerChannel?
    private let input = RemoteInput()
    private let keyboard = KeyboardEntry()
    /// `aiostreams://` links, held until the page listens for them.
    private var links: [String] = []
    private var linksReady = false
    /// The page's latest report on itself.
    private var latestStatus: PageStatus?
    private var contentSizeWatch: NSKeyValueObservation?
    private var connectedLogged = false
    /// The last start never drew the page, so this one shows what happened first.
    private var recoverOnAppear = false
    /// Counts page loads, so a check scheduled for an older one does nothing.
    private var loadGeneration = 0
    /// How long the page has to draw something before the error screen shows.
    private static let startTimeout: TimeInterval = 20
    private static let afterLoadTimeout: TimeInterval = 10

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // Read before this start writes over them.
        recoverOnAppear = RunLog.lastStartFailed
        _ = RunLog.previous
        AppFolders.create()
        MPVConfig.writeFile()

        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoView.isHidden = true
        videoLayer.frame = videoView.bounds
        videoLayer.contentsScale = UIScreen.main.nativeScale
        videoLayer.framebufferOnly = true
        videoLayer.backgroundColor = UIColor.black.cgColor
        videoView.layer.addSublayer(videoLayer)
        view.addSubview(videoView)

        LegacyWebView.setUserAgent(Identity.userAgent)
        guard let web = LegacyWebView(frame: view.bounds) else {
            return showProblem("This version of tvOS has no web view for the app to show its pages in.")
        }
        self.web = web
        bridge = AppBridge(evaluate: { [weak self] in self?.web?.evaluate($0) }) { [weak self] type, message in
            self?.onMessage(type, message)
        }
        startPlayer()
        setUpWebView(web)
        setUpInput()
        observeLifecycle()

        // Read here, on the main thread; the protocol serves the page from another.
        let identity = Identity.script
        AppURLProtocol.bootScript = {
            BridgeScript.make(
                identity: identity,
                storage: WebStorageMirror.load(),
                clear: WebStorageMirror.takeClearRequest()
            )
        }
        URLProtocol.registerClass(AppURLProtocol.self)
        guard AppURLProtocol.webRoot != nil else {
            return showProblem("The web app is missing from this build. Run scripts/fetch-web.sh, then build again.")
        }
        // A start that never drew may be one the page hangs on, so nothing loads until the user chooses.
        if !recoverOnAppear { startPage() }
    }

    /// Loads the web app from the start, and checks that it draws.
    private func startPage() {
        guard let web else { return }
        loadGeneration += 1
        latestStatus = nil
        connectedLogged = false
        linksReady = false
        RunLog.begin("Loading the page; app \(Identity.version), web app \(Diagnostics.webCommit), " +
                     "\(WebStorageMirror.load().count) keys in the app's copy")
        bridge.pageStarted()
        web.load(AppURLProtocol.startURL)
        checkPage(after: Self.startTimeout)
    }

    /// Never asks the page: one that is stuck would never answer, and the app would wait with it.
    private func checkPage(after delay: TimeInterval) {
        let generation = loadGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.loadGeneration == generation, self.latestStatus?.rendered != true else { return }
            RunLog.add("Nothing drawn after \(Int(delay)) s")
            self.showDiagnostics(title: "The app could not start")
        }
    }

    /// The error screen: when the page doesn't start, on a long Play/Pause, or after a start that never drew.
    private func showDiagnostics(title: String, lines: [String]? = nil, beforeStart: Bool = false) {
        guard presentedViewController == nil else { return }
        // Shown once per load; Try again starts a new one.
        loadGeneration += 1
        let report = Diagnostics.report(status: beforeStart ? nil : latestStatus, lines: lines ?? RunLog.lines)
        let screen = DiagnosticsViewController(title: title, report: report)
        screen.onRetry = { [weak self] in self?.startPage() }
        screen.onReset = { [weak self] in
            Diagnostics.resetWebData()
            self?.startPage()
        }
        // Before the page has started, closing starts it.
        screen.onClose = beforeStart ? { [weak self] in self?.startPage() } : {}
        present(screen, animated: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        videoLayer.frame = videoView.bounds
        if let scale = view.window?.screen.nativeScale { videoLayer.contentsScale = scale }
        web?.view.frame = view.bounds
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        if recoverOnAppear, web != nil {
            recoverOnAppear = false
            showDiagnostics(title: "The app didn't start last time", lines: RunLog.previous, beforeStart: true)
        }
    }

    // MARK: Setup

    private func startPlayer() {
        do {
            let engine = try MPVEngine(layer: videoLayer, configDir: AppFolders.mpv, cacheDir: AppFolders.shaders)
            self.engine = engine
            player = PlayerChannel(
                engine: engine,
                subtitlesDir: AppFolders.subtitles,
                send: { [weak self] in self?.bridge.send($0) },
                showVideo: { [weak self] in self?.videoView.isHidden = !$0 }
            )
        } catch {
            NSLog("[app] mpv did not start: %@", String(describing: error))
        }
    }

    private func setUpWebView(_ web: LegacyWebView) {
        web.view.frame = view.bounds
        web.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // The page is transparent where the video shows through it.
        web.view.isOpaque = false
        web.view.backgroundColor = .clear
        // The remote's touches go to RemoteInput, not to taps in the page.
        web.view.isUserInteractionEnabled = false
        // The page asks for a 1280-wide layout on a TV, scaled up to the screen.
        web.set("scalesPageToFit", true)
        web.set("mediaPlaybackRequiresUserAction", false)
        web.set("allowsInlineMediaPlayback", true)
        if let scroll = web.scrollView {
            scroll.backgroundColor = .clear
            scroll.bounces = false
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.showsVerticalScrollIndicator = false
            scroll.showsHorizontalScrollIndicator = false
        }

        webDelegate.shouldLoad = { [weak self] url, mainFrame in
            self?.shouldLoad(url, mainFrame: mainFrame) ?? false
        }
        webDelegate.didFinish = { [weak self] in
            guard let self, let web = self.web else { return }
            self.checkPage(after: Self.afterLoadTimeout)
            self.fitPage(self.latestStatus)
            // Where WebKit never sent the context callback, the page gets its function now.
            self.bridge.pageLoaded {
                if let context = web.javaScriptContext,
                   context.objectForKeyedSubscript("__aiostreamsPost")?.isUndefined != false {
                    JSContextHook.install(in: context, from: "after load")
                }
            }
        }
        webDelegate.didFail = { [weak self] error in
            NSLog("[web] load failed: %@", error.localizedDescription)
            // A load the page itself replaced or stopped isn't a failure.
            guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled else { return }
            let address = (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).map { " (\($0))" } ?? ""
            RunLog.add("Load failed: \(error.localizedDescription)\(address)")
            self?.checkPage(after: 1)
        }
        web.setDelegate(webDelegate)
        view.addSubview(web.view)
        // The page's width can change without a resize event, as after signing in.
        contentSizeWatch = web.scrollView?.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.fitPage(self?.latestStatus) }
        }
    }

    private func setUpInput() {
        input.key = { [weak self] type, key, repeated in
            self?.web?.evaluate("window.__aiostreamsKey && __aiostreamsKey('\(type)','\(key)',\(repeated))")
        }
        input.back = { [weak self] in
            guard let self, self.bridge.connected else { return false }
            self.bridge.send(["type": "back"])
            return true
        }
        input.editText = { [weak self] in
            guard let self,
                  let text = self.web?.evaluate("window.__aiostreamsEditField ? __aiostreamsEditField() : ''"),
                  !text.isEmpty,
                  let info = try? JSONDecoder().decode(FieldInfo.self, from: Data(text.utf8))
            else { return false }
            self.keyboard.begin(info)
            return true
        }
        input.heldPlayPause = { [weak self] in self?.showDiagnostics(title: "Diagnostics") }
        input.attach(to: view)

        keyboard.write = { [weak self] text in
            guard let literal = JSON.string([text]) else { return }
            self?.web?.evaluate("window.__aiostreamsSetText && __aiostreamsSetText(\(literal)[0])")
        }
        keyboard.submit = { [weak self] in
            self?.web?.evaluate("window.__aiostreamsSubmitText && __aiostreamsSubmitText()")
        }
        keyboard.finished = { [weak self] in
            self?.web?.evaluate("window.__aiostreamsEndEdit && __aiostreamsEndEdit()")
            self?.becomeFirstResponder()
        }
        keyboard.attach(to: self)
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.web?.evaluate("window.__aiostreamsFlushStorage && __aiostreamsFlushStorage()")
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.player?.change(Change(paused: true))
            self?.engine?.setVideoEnabled(false)
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine?.setVideoEnabled(true)
        }
    }

    // MARK: Navigation

    /// The app's own pages load here; anything else opens the app it names, if any.
    private func shouldLoad(_ url: URL, mainFrame: Bool) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if url.host?.lowercased() == AppURLProtocol.host { return true }
        if ["about", "data", "blob"].contains(scheme) { return true }
        if scheme == "http" || scheme == "https" {
            // Frames such as trailers load; the page itself never leaves, as a TV has no browser.
            return !mainFrame
        }
        if scheme == "aiostreams" {
            receiveLink(url.absoluteString)
            return false
        }
        // An external player's link, such as infuse://x-callback-url/play?…
        UIApplication.shared.open(url) { [weak self] opened in
            if !opened {
                self?.alert("Couldn't open the player", "Check that the app for \(scheme):// links is installed.")
            }
        }
        return false
    }

    /// From the system, or a link in the page.
    func receiveLink(_ url: String) {
        guard url.lowercased().hasPrefix("aiostreams://") else { return }
        links.append(url)
        sendLinks()
    }

    private func sendLinks() {
        while linksReady, !links.isEmpty {
            bridge.send(["type": "link", "url": links.removeFirst()])
        }
    }

    // MARK: Messages

    private func onMessage(_ type: String, _ message: Message) {
        if !connectedLogged {
            connectedLogged = true
            RunLog.add("Bridge connected (first message: \(type))")
        }
        if player?.handle(type, message) == true { return }
        switch type {
        case "tvos-boot":
            RunLog.add("Start-up script ran, \(Int(message.number("storageKeys") ?? -1)) keys in the page's storage")
        case "tvos-status":
            guard let status = PageStatus(message) else { return }
            latestStatus = status
            if status.rendered { RunLog.drew() }
            fitPage(status)
        case "app-info":
            bridge.send(AppAnswers.appInfo(engine: engine))
        case "player-engine":
            // The page asks for its engine choice; this app has only mpv.
            bridge.send(["type": "player-engine", "name": "mpv"])
        case "fullscreen":
            bridge.send(["type": "fullscreen", "value": true])
        case "levels":
            bridge.send(["type": "levels", "volume": 1.0, "brightness": 1.0])
        case "links-ready":
            linksReady = true
            sendLinks()
        case "exit":
            suspendApp()
        case "tvos-storage":
            if let items = message.object("items") { WebStorageMirror.save(items) }
        case "mpv-config":
            bridge.send(["type": "mpv-config", "text": MPVConfig.text])
        case "mpv-config-save":
            MPVConfig.save(message.text("text") ?? "")
            engine?.reloadConfig()
            bridge.send(["type": "mpv-config", "text": MPVConfig.text])
        case "diagnostics":
            bridge.send(AppAnswers.diagnostics(engine: engine, web: message.text("web"), server: message.text("server")))
        case "licenses":
            bridge.send(AppAnswers.licenses)
        case "crash-report":
            bridge.send(["type": "crash-report"])
        case "update-check", "update-apply":
            bridge.send(AppAnswers.updateState)
        case "youtube-resolve":
            bridge.send(["type": "youtube-resolved", "request": message.text("request") ?? "", "url": NSNull()])
        case "voice-search":
            // Dictation is on the keyboard's microphone; the page doesn't offer its own here.
            bridge.send(["type": "voice-result", "text": NSNull(), "error": "failed"])
        case "save-file":
            alert("Can't save files", "Apple TV has no files to save \(message.text("name") ?? "this") to.")
        case "web-error":
            RunLog.add("Page: \(message.text("message") ?? "")")
        default:
            // Downloads, watch-next, keyboard completions and the like have no Apple TV part.
            break
        }
    }

    // MARK: Zoom

    /**
     * Zooms the page so its layout width spans the screen. The web app lays a
     * TV's page out 1280 wide and leaves the scaling to the web view, which
     * UIWebView doesn't do reliably from the page's viewport. The page reports
     * how wide it lays out and how much of that is on screen; the zoom changes
     * by their ratio, which corrects itself whatever WebKit's zoom units are.
     */
    private func fitPage(_ status: PageStatus?) {
        guard let scroll = web?.scrollView, view.bounds.width > 0 else { return }
        let drawn = scroll.contentSize.width
        let ratio: CGFloat
        let why: String
        if drawn > 1, drawn < view.bounds.width - 2 {
            // Narrower than the screen: the page leaves a strip down the side.
            ratio = view.bounds.width / drawn
            why = "drawn \(Int(drawn)) pt wide on a \(Int(view.bounds.width)) pt screen"
        } else if let status, status.layoutWidth > 0, status.visibleWidth > 0,
                  abs(status.visibleWidth - status.layoutWidth) > 2 {
            // More of the page on screen than it lays out: zoomed out.
            ratio = CGFloat(status.visibleWidth / status.layoutWidth)
            why = "laid out \(Int(status.layoutWidth)) wide, \(Int(status.visibleWidth)) on screen"
        } else {
            return
        }
        let target = min(4, max(0.5, scroll.zoomScale * ratio))
        guard abs(target - scroll.zoomScale) > 0.01 else { return }
        RunLog.add("Zoom \(String(format: "%.2f", scroll.zoomScale)) → \(String(format: "%.2f", target)): \(why)")
        scroll.minimumZoomScale = min(scroll.minimumZoomScale, target)
        scroll.maximumZoomScale = max(scroll.maximumZoomScale, target)
        scroll.setZoomScale(target, animated: false)
        scroll.minimumZoomScale = target
        scroll.maximumZoomScale = target
        scroll.contentOffset = CGPoint(x: 0, y: scroll.contentOffset.y)
    }

    // MARK: Presses

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = input.pressesBegan(presses)
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = input.pressesEnded(presses)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = input.pressesEnded(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    // MARK: Messages to the user

    private func alert(_ title: String, _ text: String) {
        let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func showProblem(_ text: String) {
        let label = UILabel(frame: view.bounds.insetBy(dx: 160, dy: 160))
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.text = text
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .title2)
        view.addSubview(label)
    }
}
