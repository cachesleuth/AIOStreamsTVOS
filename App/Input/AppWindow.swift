import UIKit

/// Takes the Siri Remote while nothing the app shows over the page needs it.
protocol RemoteReceiver: AnyObject {
    var takesRemote: Bool { get }
    func remotePress(_ press: UIPress)
    func remoteTouches(_ touches: Set<UITouch>)
}

/**
 * Hands the remote's presses and touch-surface swipes to the page's handler
 * before UIKit does. WebKit's content view is first responder, so it would
 * otherwise take them itself. As the working aiostreams-tvos project's AIOWindow.
 */
final class AppWindow: UIWindow {
    weak var remote: RemoteReceiver?

    override func sendEvent(_ event: UIEvent) {
        guard let remote, remote.takesRemote else { return super.sendEvent(event) }
        if event.type == .presses, let presses = (event as? UIPressesEvent)?.allPresses {
            for press in presses { remote.remotePress(press) }
            return
        }
        if event.type == .touches, let touches = event.allTouches {
            let indirect = touches.filter { $0.type == .indirect }
            if !indirect.isEmpty {
                remote.remoteTouches(indirect)
                return
            }
        }
        super.sendEvent(event)
    }
}
