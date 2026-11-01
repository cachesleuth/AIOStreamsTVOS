import UIKit

/// What the page's focused field is, from `__aiostreamsEditField`.
struct FieldInfo: Decodable {
    let value: String
    let type: String
    let placeholder: String
    let enterKeyHint: String
    let inputMode: String
}

/**
 * Types into the page's fields with tvOS's own keyboard, which has dictation
 * on the remote's microphone button. A screen with one real text field opens
 * over the page and gives it the keyboard; what is typed goes into the page's
 * field as it changes.
 */
final class KeyboardEntry {
    var write: (String) -> Void = { _ in }
    var submit: () -> Void = {}
    var finished: () -> Void = {}

    private weak var host: UIViewController?

    func attach(to host: UIViewController) {
        self.host = host
    }

    func begin(_ info: FieldInfo) {
        guard let host, host.presentedViewController == nil else { return }
        let entry = TextEntryViewController(info: info)
        entry.onChange = { [weak self] in self?.write($0) }
        entry.onDone = { [weak self] text, submitted in
            guard let self else { return }
            self.write(text)
            if submitted { self.submit() }
            self.finished()
        }
        host.present(entry, animated: true)
    }
}

/// A title, the field, and the system keyboard, which tvOS shows full screen.
private final class TextEntryViewController: UIViewController, UITextFieldDelegate {
    var onChange: (String) -> Void = { _ in }
    var onDone: (String, Bool) -> Void = { _, _ in }

    private let info: FieldInfo
    private let field = UITextField()
    private var submitted = false
    private var reported = false

    init(info: FieldInfo) {
        self.info = info
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.03, alpha: 0.92)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.text = info.value
        field.placeholder = info.placeholder
        field.delegate = self
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.borderStyle = .roundedRect
        field.font = .preferredFont(forTextStyle: .title3)
        let password = info.type == "password"
        field.isSecureTextEntry = password
        field.textContentType = password ? .password : nil
        switch info.inputMode.isEmpty ? info.type : info.inputMode {
        case "url": field.keyboardType = .URL
        case "email": field.keyboardType = .emailAddress
        case "number", "numeric", "tel", "decimal": field.keyboardType = .numberPad
        default: field.keyboardType = .default
        }
        field.returnKeyType = info.type == "search" || info.enterKeyHint == "search" ? .search : .done
        field.addTarget(self, action: #selector(changed), for: .editingChanged)
        view.addSubview(field)

        NSLayoutConstraint.activate([
            field.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            field.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.6),
        ])
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [field] }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A visible, focusable field becoming first responder brings up the keyboard.
        field.becomeFirstResponder()
    }

    @objc private func changed() {
        onChange(field.text ?? "")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submitted = true
        textField.resignFirstResponder()
        return false
    }

    /// The keyboard went away: by Done or by Back. Either way the screen closes.
    func textFieldDidEndEditing(_ textField: UITextField) {
        finish()
    }

    /// Back on this screen with the keyboard already closed.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            finish()
        } else {
            super.pressesBegan(presses, with: event)
        }
    }

    private func finish() {
        guard !reported else { return }
        reported = true
        let text = field.text ?? ""
        let submitted = self.submitted
        dismiss(animated: true) { [onDone] in onDone(text, submitted) }
    }
}
