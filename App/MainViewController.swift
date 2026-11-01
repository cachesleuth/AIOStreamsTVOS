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
    /// What failed outside the page since it last started loading.
    private var nativeErrors: [String] = []
    /// Counts page loads, so a check scheduled for an older one does nothing.
    private var loadGeneration = 0
    /// How long the page has to draw something before the error screen shows.
    private static let startTimeout: TimeInterval = 20
    private static let afterLoadTimeout: TimeInterval = 10

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
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
            BridgeScript.make(identity: identity, storage: WebStorageMirror.load())
        }
        URLProtocol.registerClass(AppURLProtocol.self)
        guard AppURLProtocol.webRoot != nil else {
            return showProblem("The web app is missing from this build. Run scripts/fetch-web.sh, then build again.")
        }
        startPage()
    }

    /// Loads the web app from the start, and checks that it draws.
    private func startPage() {
        guard let web else { return }
        loadGeneration += 1
        nativeErrors.removeAll()
        linksReady = false
        bridge.pageStarted()
        web.load(AppURLProtocol.startURL)
        checkPage(after: Self.startTimeout)
    }

    private func checkPage(after delay: TimeInterval) {
        let generation = loadGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.loadGeneration == generation else { return }
            let (status, _) = self.pageStatus()
            if status?.rendered != true { self.showDiagnostics(title: "The app could not start") }
        }
    }

    private func pageStatus() -> (PageStatus?, String?) {
        let raw = web?.evaluate("window.__aiostreamsStatus ? __aiostreamsStatus() : ''")
        let status = raw.flatMap { try? JSONDecoder().decode(PageStatus.self, from: Data($0.utf8)) }
        return (status, raw)
    }

    /// The error screen, shown when the page doesn't start, or on a long Play/Pause.
    private func showDiagnostics(title: String) {
        guard presentedViewController == nil else { return }
        // Shown once per load; Try again starts a new one.
        loadGeneration += 1
        let (status, raw) = pageStatus()
        let report = Diagnostics.report(status: status, rawStatus: raw, nativeErrors: nativeErrors)
        NSLog("[app] %@\n%@", title, report)
        let screen = DiagnosticsViewController(title: title, report: report)
        screen.onRetry = { [weak self] in self?.startPage() }
        screen.onReset = { [weak self] in
            guard let self else { return }
            Diagnostics.resetWebData(web: self.web)
            self.startPage()
        }
        present(screen, animated: true)
    }

    @objc private func heldPlayPause(_ press: UILongPressGestureRecognizer) {
        if press.state == .began { showDiagnostics(title: "Diagnostics") }
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
            // Where WebKit never sent the context callback, the page gets its function now.
            self.bridge.pageLoaded {
                if let context = web.javaScriptContext,
                   context.objectForKeyedSubscript("__aiostreamsPost")?.isUndefined != false {
                    JSContextHook.install(in: context)
                }
            }
        }
        webDelegate.didFail = { [weak self] error in
            NSLog("[web] load failed: %@", error.localizedDescription)
            // A load the page itself replaced or stopped isn't a failure.
            guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled else { return }
            let address = (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).map { " (\($0))" } ?? ""
            self?.nativeErrors.append("Load failed: \(error.localizedDescription)\(address)")
            self?.checkPage(after: 1)
        }
        web.setDelegate(webDelegate)
        view.addSubview(web.view)
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
        input.attach(to: view)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(heldPlayPause(_:)))
        hold.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
        hold.allowedTouchTypes = []
        hold.minimumPressDuration = 2
        hold.cancelsTouchesInView = false
        view.addGestureRecognizer(hold)

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
        if player?.handle(type, message) == true { return }
        switch type {
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
            NSLog("[page] %@", message.text("message") ?? "")
        default:
            // Downloads, watch-next, keyboard completions and the like have no Apple TV part.
            break
        }
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
