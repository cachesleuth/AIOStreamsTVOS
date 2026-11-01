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
 * on the remote's microphone button. A text field the user never sees takes
 * the keyboard; what is typed goes into the page's field as it changes.
 */
final class KeyboardEntry: NSObject, UITextFieldDelegate {
    var write: (String) -> Void = { _ in }
    var submit: () -> Void = {}
    var finished: () -> Void = {}

    private let field = OffscreenTextField(frame: CGRect(x: -10, y: -10, width: 1, height: 1))
    private var submitted = false

    func attach(to view: UIView) {
        field.alpha = 0.01
        field.delegate = self
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.addTarget(self, action: #selector(changed), for: .editingChanged)
        view.addSubview(field)
    }

    func begin(_ info: FieldInfo) {
        submitted = false
        field.text = info.value
        field.placeholder = info.placeholder
        field.isSecureTextEntry = info.type == "password"
        field.textContentType = info.type == "password" ? .password : nil
        switch info.inputMode.isEmpty ? info.type : info.inputMode {
        case "url": field.keyboardType = .URL
        case "email": field.keyboardType = .emailAddress
        case "number", "numeric", "tel", "decimal": field.keyboardType = .numberPad
        default: field.keyboardType = .default
        }
        field.returnKeyType = info.type == "search" || info.enterKeyHint == "search" ? .search : .done
        field.becomeFirstResponder()
    }

    @objc private func changed() {
        write(field.text ?? "")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submitted = true
        textField.resignFirstResponder()
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        write(textField.text ?? "")
        if submitted { submit() }
        finished()
    }
}

/// Out of the focus engine's reach, so only the app gives it the keyboard.
private final class OffscreenTextField: UITextField {
    override var canBecomeFocused: Bool { false }
}
