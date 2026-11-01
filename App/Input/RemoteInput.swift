import UIKit

/**
 * Turns the Siri Remote into the keys the web app reads from a TV's remote:
 * clickpad presses and swipes into arrows, Select into `GamepadA` (which the
 * page treats as Select, and holds for the item menu), Play/Pause into
 * `MediaPlayPause`. Back goes through the bridge, as on Android.
 */
final class RemoteInput: NSObject {
    /// Sends `keydown` or `keyup` for a key name.
    var key: (_ type: String, _ key: String, _ repeat: Bool) -> Void = { _, _, _ in }
    /// Play/Pause held for 2 seconds.
    var heldPlayPause: () -> Void = {}
    private var playPauseHold: Timer?
    /// The Menu/Back button; false lets tvOS have it, which leaves the app.
    var back: () -> Bool = { false }
    /// Select on a text field; true when it opened the keyboard instead.
    var editText: () -> Bool = { false }

    private var held: [UIPress.PressType: String] = [:]
    private var repeating: (key: String, timer: Timer)?
    private var panStart: CGPoint = .zero
    private var consumedSelect = false
    private var menuTaken = false

    private static let repeatDelay: TimeInterval = 0.4
    private static let repeatEvery: TimeInterval = 0.11
    /// How far a swipe on the touch surface goes for each step.
    private static let swipeStep: CGFloat = 220

    func attach(to view: UIView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(pan)
    }

    /// The presses it didn't take, which go on to `super`.
    func pressesBegan(_ presses: Set<UIPress>) -> Set<UIPress> {
        var rest = Set<UIPress>()
        for press in presses {
            switch press.type {
            case .menu:
                menuTaken = back()
                if !menuTaken { rest.insert(press) }
            case .select:
                if editText() {
                    consumedSelect = true
                } else {
                    down(press.type, "GamepadA", repeats: false)
                }
            default:
                if press.type == .playPause {
                    playPauseHold?.invalidate()
                    playPauseHold = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                        self?.playPauseHold = nil
                        self?.heldPlayPause()
                    }
                }
                if let name = Self.names[press.type] {
                    down(press.type, name, repeats: Self.arrows.contains(name))
                } else {
                    rest.insert(press)
                }
            }
        }
        return rest
    }

    func pressesEnded(_ presses: Set<UIPress>) -> Set<UIPress> {
        var rest = Set<UIPress>()
        for press in presses {
            if press.type == .playPause {
                playPauseHold?.invalidate()
                playPauseHold = nil
            }
            if press.type == .select, consumedSelect {
                consumedSelect = false
            } else if let name = held.removeValue(forKey: press.type) {
                if repeating?.key == name { stopRepeating() }
                key("keyup", name, false)
            } else if press.type == .menu {
                // tvOS gets the release only when it got the press.
                if menuTaken { menuTaken = false } else { rest.insert(press) }
            } else {
                rest.insert(press)
            }
        }
        return rest
    }

    private func down(_ type: UIPress.PressType, _ name: String, repeats: Bool) {
        held[type] = name
        key("keydown", name, false)
        guard repeats else { return }
        stopRepeating()
        let start = Timer.scheduledTimer(withTimeInterval: Self.repeatDelay, repeats: false) { [weak self] _ in
            guard let self, self.repeating?.key == name else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: Self.repeatEvery, repeats: true) { [weak self] _ in
                self?.key("keydown", name, true)
            }
            self.repeating = (name, timer)
        }
        repeating = (name, start)
    }

    private func stopRepeating() {
        repeating?.timer.invalidate()
        repeating = nil
    }

    @objc private func onPan(_ pan: UIPanGestureRecognizer) {
        guard let view = pan.view else { return }
        let at = pan.translation(in: view)
        switch pan.state {
        case .began:
            panStart = at
        case .changed:
            let dx = at.x - panStart.x
            let dy = at.y - panStart.y
            let name: String?
            if abs(dx) >= Self.swipeStep, abs(dx) > abs(dy) {
                name = dx > 0 ? "ArrowRight" : "ArrowLeft"
            } else if abs(dy) >= Self.swipeStep {
                name = dy > 0 ? "ArrowDown" : "ArrowUp"
            } else {
                name = nil
            }
            guard let name else { return }
            panStart = at
            key("keydown", name, false)
            key("keyup", name, false)
        default:
            break
        }
    }

    private static let arrows: Set<String> = ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"]

    private static let names: [UIPress.PressType: String] = [
        .upArrow: "ArrowUp",
        .downArrow: "ArrowDown",
        .leftArrow: "ArrowLeft",
        .rightArrow: "ArrowRight",
        .playPause: "MediaPlayPause",
        .pageUp: "PageUp",
        .pageDown: "PageDown",
    ]
}
