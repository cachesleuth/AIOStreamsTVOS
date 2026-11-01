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
        bridge.pageStarted()
        web.load(AppURLProtocol.startURL)
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
        web.set("scalesPageToFit", false)
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
            // Where WebKit never sent the context callback, the page gets its function now.
            self.bridge.pageLoaded {
                if let context = web.javaScriptContext,
                   context.objectForKeyedSubscript("__aiostreamsPost")?.isUndefined != false {
                    JSContextHook.install(in: context)
                }
            }
        }
        webDelegate.didFail = { error in
            NSLog("[web] load failed: %@", error.localizedDescription)
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
