import Foundation

/**
 * The app's end of `window.aiostreamsApp`. Messages to the page are evaluated
 * in it on the main thread; messages from it arrive through JSContextHook.
 */
final class AppBridge {
    private let evaluate: (String) -> String?
    private let onMessage: (String, Message) -> Void

    /// A page is listening: it has sent a message since it last loaded.
    private(set) var connected = false

    init(evaluate: @escaping (String) -> String?, onMessage: @escaping (String, Message) -> Void) {
        self.evaluate = evaluate
        self.onMessage = onMessage
        JSContextHook.onMessage = { [weak self] text in self?.receive(text) }
    }

    func pageStarted() {
        connected = false
    }

    /// For a web view whose context the hook missed: hands the page the function now.
    func pageLoaded(context install: () -> Void) {
        install()
        _ = evaluate("window.__aiostreamsFlush && window.__aiostreamsFlush()")
    }

    func send(_ message: Message) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.send(message) }
            return
        }
        guard let json = JSON.string(message) else {
            NSLog("[bridge] can't encode %@", String(describing: message["type"]))
            return
        }
        _ = evaluate("window.__aiostreamsReceive && window.__aiostreamsReceive(\(json))")
    }

    private func receive(_ text: String) {
        guard let message = JSON.parse(text), let type = message.text("type") else { return }
        connected = true
        onMessage(type, message)
    }
}
