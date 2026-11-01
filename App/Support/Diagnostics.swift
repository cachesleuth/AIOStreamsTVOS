import UIKit

/**
 * What happened while the page started, kept in the user defaults as it
 * happens, so it outlives an app that froze and was force-quit. The next launch
 * shows it when that one never got as far as the page drawing.
 */
enum RunLog {
    private static let linesKey = "aiostreams.runLog"
    private static let previousKey = "aiostreams.previousRunLog"
    private static let pendingKey = "aiostreams.launchPending"
    private static let lock = NSLock()
    private static let maxLines = 40
    private static let started = Date()

    /// True when the last start never reached the page drawing.
    static let lastStartFailed: Bool = UserDefaults.standard.bool(forKey: pendingKey)

    /// The last start's lines, read before this one replaces them.
    static let previous: [String] = UserDefaults.standard.stringArray(forKey: linesKey) ?? []

    /// A new start of the page: earlier lines move aside.
    static func begin(_ what: String) {
        lock.lock()
        let defaults = UserDefaults.standard
        defaults.set(defaults.stringArray(forKey: linesKey) ?? [], forKey: previousKey)
        defaults.set([String](), forKey: linesKey)
        defaults.set(true, forKey: pendingKey)
        lock.unlock()
        add(what)
    }

    /// From any thread.
    static func add(_ line: String) {
        let seconds = String(format: "%5.1fs", Date().timeIntervalSince(started))
        let entry = "\(seconds) \(line.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(400))"
        NSLog("[run] %@", entry)
        lock.lock()
        var lines = UserDefaults.standard.stringArray(forKey: linesKey) ?? []
        lines.append(entry)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        UserDefaults.standard.set(lines, forKey: linesKey)
        lock.unlock()
    }

    static func drew() {
        guard UserDefaults.standard.bool(forKey: pendingKey) else { return }
        UserDefaults.standard.set(false, forKey: pendingKey)
        add("Page drew")
    }

    static var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return UserDefaults.standard.stringArray(forKey: linesKey) ?? []
    }
}

/// The page's own report, which it sends every few seconds as `tvos-status`.
struct PageStatus {
    let href: String
    let readyState: String
    let rendered: Bool
    let text: String
    let storageKeys: Int
    let errors: Int
    /// In CSS pixels: the width the page lays out at, and the part of it on screen.
    let layoutWidth: Double
    let visibleWidth: Double

    init?(_ message: Message) {
        guard let href = message.text("href") else { return nil }
        self.href = href
        readyState = message.text("readyState") ?? "?"
        rendered = message.flag("rendered") == true
        text = message.text("text") ?? ""
        layoutWidth = message.number("layoutWidth") ?? 0
        visibleWidth = message.number("visibleWidth") ?? 0
        storageKeys = Int(message.number("storageKeys") ?? -1)
        errors = Int(message.number("errors") ?? 0)
    }
}

enum Diagnostics {
    /// The AIOStreams commit the bundled web app was built from, written by scripts/fetch-web.sh.
    static let webCommit: String = {
        guard let root = AppURLProtocol.webRoot,
              let text = try? String(contentsOf: root.appendingPathComponent("aiostreams-commit.txt"), encoding: .utf8)
        else { return "unknown" }
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10))
    }()

    /// Short enough to read from a sofa, or photograph.
    static func report(status: PageStatus?, lines: [String]) -> String {
        var out = ["App \(Identity.version) · tvOS \(UIDevice.current.systemVersion) · web app \(webCommit)"]
        if let status {
            out.append("Page: \(status.readyState), \(status.rendered ? "has content" : "nothing drawn"), " +
                       "\(status.storageKeys) saved keys, \(status.errors) errors, " +
                       "laid out \(Int(status.layoutWidth)) wide, \(Int(status.visibleWidth)) on screen")
            if !status.text.isEmpty { out.append("Shows: \(status.text.prefix(120))") }
        } else {
            out.append("Page: never reported in")
        }
        out.append("")
        // The screen holds about this many lines; the newest matter most.
        out += lines.suffix(16)
        return out.joined(separator: "\n")
    }

    /**
     * Forgets the page's saved data. Nothing runs in the page now, which may be
     * stuck: WebKit's files and the app's copy go here, and the next page start
     * clears what WebKit still holds in memory, before the page reads it.
     */
    static func resetWebData() {
        WebStorageMirror.clear()
        WebStorageMirror.requestClear()
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
        RunLog.add("Reset the app's data")
    }
}

/// Over the page, or in its place: what went wrong, and ways out.
final class DiagnosticsViewController: UIViewController {
    var onRetry: () -> Void = {}
    var onReset: () -> Void = {}
    var onClose: () -> Void = {}

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
        heading.font = .boldSystemFont(ofSize: 48)
        heading.textColor = .white
        heading.textAlignment = .center

        let body = UILabel()
        body.text = report
        body.font = .monospacedSystemFont(ofSize: 20, weight: .regular)
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
        stack.spacing = 28
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            // Fixed widths, so the labels wrap rather than run off the screen.
            body.widthAnchor.constraint(equalToConstant: 1600),
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
        dismiss(animated: true) { [onClose] in onClose() }
    }

    /// Back closes it, as Close does.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            tappedClose()
        } else {
            super.pressesBegan(presses, with: event)
        }
    }
}
