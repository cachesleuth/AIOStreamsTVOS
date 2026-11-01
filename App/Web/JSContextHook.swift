import JavaScriptCore
import UIKit

/**
 * Carries the page's messages to the app. UIWebView has no message handler API,
 * so the app puts a function into each JavaScript context WebKit makes, through
 * the frame load delegate callback WebKit sends any object that answers it.
 * Only the main frame of the app's own origin is heard.
 */
enum JSContextHook {
    /// Called on the main thread with each message's JSON text.
    static var onMessage: ((String) -> Void)?

    static func install(in context: JSContext) {
        let post: @convention(block) (String) -> Void = { text in
            let origin = JSContext.current()?
                .evaluateScript("window.top === window ? location.host : ''")?
                .toString()
            guard origin == AppURLProtocol.host else { return }
            DispatchQueue.main.async { onMessage?(text) }
        }
        context.setObject(unsafeBitCast(post, to: AnyObject.self), forKeyedSubscript: "__aiostreamsPost" as NSString)
    }
}

extension NSObject {
    /// WebKit's `webView:didCreateJavaScriptContext:forFrame:`, sent before a page's scripts run.
    @objc(webView:didCreateJavaScriptContext:forFrame:)
    func aiostreams_webView(_ webView: AnyObject, didCreateJavaScriptContext context: JSContext, forFrame frame: AnyObject) {
        JSContextHook.install(in: context)
    }
}
