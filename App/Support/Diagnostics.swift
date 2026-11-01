import UIKit

/// What the page reports about itself, from `__aiostreamsStatus`.
struct PageStatus: Decodable {
    let href: String
    let readyState: String
    let rendered: Bool
    let bridge: Bool
    let storageKeys: Int
    let errors: [String]
}

enum Diagnostics {
    /// The AIOStreams commit the bundled web app was built from, written by scripts/fetch-web.sh.
    static let webCommit: String = {
        guard let root = AppURLProtocol.webRoot,
              let text = try? String(contentsOf: root.appendingPathComponent("aiostreams-commit.txt"), encoding: .utf8)
        else { return "unknown" }
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10))
    }()

    /// The report shown on screen: short enough to read from a sofa, or photograph.
    static func report(status: PageStatus?, rawStatus: String?, nativeErrors: [String]) -> String {
        var lines = [
            "App \(Identity.version) · tvOS \(UIDevice.current.systemVersion) · web app \(webCommit)",
        ]
        if let status {
            lines.append("Page: \(status.readyState), \(status.rendered ? "drawn" : "nothing drawn"), " +
                         "bridge \(status.bridge ? "connected" : "not connected"), \(status.storageKeys) saved keys")
            lines.append("At: \(status.href)")
        } else if let rawStatus, !rawStatus.isEmpty {
            lines.append("Page status unreadable: \(rawStatus.prefix(200))")
        } else {
            lines.append("Page status unavailable: the app's start-up script never ran, or the page's JavaScript stopped.")
        }
        let errors = nativeErrors + (status?.errors ?? [])
        if errors.isEmpty {
            lines.append("No errors were reported.")
        } else {
            lines.append("")
            lines.append("Errors, newest last:")
            for error in errors.suffix(6) {
                lines.append("• " + String(error.prefix(400)))
            }
        }
        return lines.joined(separator: "\n")
    }

    /**
     * Forgets the page's saved data: sign-ins, settings and cached pages. The
     * page's own copy goes from script first, as WebKit holds it in memory, then
     * WebKit's files on disk, then the app's mirror, which would put it back.
     */
    static func resetWebData(web: LegacyWebView?) {
        web?.evaluate("""
        try { localStorage.clear(); } catch (e) {}
        try { sessionStorage.clear(); } catch (e) {}
        try {
          if (indexedDB.databases) indexedDB.databases().then(function (all) {
            all.forEach(function (db) { if (db.name) indexedDB.deleteDatabase(db.name); });
          });
        } catch (e) {}
        """)
        WebStorageMirror.clear()
        let files = FileManager.default
        let library = files.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        try? files.removeItem(at: library.appendingPathComponent("WebKit"))
        if let all = files.enumerator(at: library, includingPropertiesForKeys: nil) {
            for case let url as URL in all {
                let name = url.lastPathComponent.lowercased()
                if name.contains("localstorage") || name.contains("indexeddb") {
                    try? files.removeItem(at: url)
                    all.skipDescendants()
                }
            }
        }
        URLCache.shared.removeAllCachedResponses()
    }
}

/// Over the page: what went wrong, and ways out.
final class DiagnosticsViewController: UIViewController {
    var onRetry: () -> Void = {}
    var onReset: () -> Void = {}

    private let titleText: String
    private let report: String
    private let retry = UIButton(type: .system)

    init(title: String, report: String) {
        titleText = title
        self.report = report
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.027, green: 0.027, blue: 0.027, alpha: 0.97)

        let heading = UILabel()
        heading.text = titleText
        heading.font = .boldSystemFont(ofSize: 52)
        heading.textColor = .white
        heading.textAlignment = .center

        let body = UILabel()
        body.text = report
        body.font = .monospacedSystemFont(ofSize: 24, weight: .regular)
        body.textColor = UIColor(white: 0.75, alpha: 1)
        body.numberOfLines = 0
        body.lineBreakMode = .byCharWrapping

        retry.setTitle("Try again", for: .normal)
        retry.addTarget(self, action: #selector(tappedRetry), for: .primaryActionTriggered)
        let reset = UIButton(type: .system)
        reset.setTitle("Reset the app's data", for: .normal)
        reset.addTarget(self, action: #selector(tappedReset), for: .primaryActionTriggered)
        let close = UIButton(type: .system)
        close.setTitle("Close", for: .normal)
        close.addTarget(self, action: #selector(tappedClose), for: .primaryActionTriggered)

        let buttons = UIStackView(arrangedSubviews: [retry, reset, close])
        buttons.axis = .horizontal
        buttons.spacing = 40
        buttons.alignment = .center

        let note = UILabel()
        note.text = "Resetting signs you out and forgets this app's settings. Hold Play/Pause for 2 seconds to open this screen any time."
        note.font = .systemFont(ofSize: 22)
        note.textColor = UIColor(white: 0.55, alpha: 1)
        note.numberOfLines = 0
        note.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [heading, body, buttons, note])
        stack.axis = .vertical
        stack.spacing = 36
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            // Fixed widths, so the labels wrap rather than run off the screen.
            body.widthAnchor.constraint(equalToConstant: 1400),
            note.widthAnchor.constraint(equalToConstant: 1200),
        ])
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [retry] }

    @objc private func tappedRetry() {
        dismiss(animated: true) { [onRetry] in onRetry() }
    }

    @objc private func tappedReset() {
        let confirm = UIAlertController(
            title: "Reset the app's data?",
            message: "This signs you out and forgets your servers and settings on this Apple TV.",
            preferredStyle: .alert
        )
        confirm.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.dismiss(animated: true) { [onReset = self.onReset] in onReset() }
        })
        confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(confirm, animated: true)
    }

    @objc private func tappedClose() {
        dismiss(animated: true)
    }
}
