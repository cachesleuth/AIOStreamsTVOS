import JavaScriptCore
import UIKit

/**
 * tvOS's UIWebView, which the SDK hides but the system still ships. Every call
 * goes through the Objective-C runtime, since no header declares the class.
 */
final class LegacyWebView {
    let view: UIView

    /// Nil when this tvOS no longer has the class.
    init?(frame: CGRect) {
        guard let type = NSClassFromString("UIWebView") as? NSObject.Type,
              let view = type.init() as? UIView
        else { return nil }
        view.frame = frame
        self.view = view
    }

    /// Set before the first web view is made: UIWebView reads it from the defaults.
    static func setUserAgent(_ agent: String) {
        UserDefaults.standard.register(defaults: ["UserAgent": agent])
    }

    /// UIWebView keeps its delegate unretained, so the caller keeps it alive.
    func setDelegate(_ delegate: NSObject) {
        view.setValue(delegate, forKey: "delegate")
    }

    func set(_ key: String, _ value: Bool) {
        view.setValue(value, forKey: key)
    }

    var scrollView: UIScrollView? {
        view.value(forKey: "scrollView") as? UIScrollView
    }

    func load(_ url: URL) {
        _ = view.perform(NSSelectorFromString("loadRequest:"), with: URLRequest(url: url) as NSURLRequest)
    }

    func reload() {
        _ = view.perform(NSSelectorFromString("reload"))
    }

    /// Runs `script` in the page on the main thread and returns its result as text.
    @discardableResult
    func evaluate(_ script: String) -> String? {
        let selector = NSSelectorFromString("stringByEvaluatingJavaScriptFromString:")
        guard view.responds(to: selector) else { return nil }
        return view.perform(selector, with: script)?.takeUnretainedValue() as? String
    }

    /// The main frame's JavaScript context, through WebKit's own object graph.
    var javaScriptContext: JSContext? {
        view.value(forKeyPath: "documentView.webView.mainFrame.javaScriptContext") as? JSContext
    }
}

/**
 * The UIWebView delegate's methods, by the selectors UIWebView calls. The
 * protocol isn't in the tvOS SDK, so nothing checks the names but WebKit.
 */
final class WebViewDelegate: NSObject {
    /// The address and whether it is the main frame's.
    var shouldLoad: (URL, Bool) -> Bool = { _, _ in true }
    var didStart: () -> Void = {}
    var didFinish: () -> Void = {}
    var didFail: (NSError) -> Void = { _ in }

    @objc(webView:shouldStartLoadWithRequest:navigationType:)
    func webView(_ webView: UIView, shouldStartLoadWith request: NSURLRequest, navigationType: Int) -> Bool {
        guard let url = request.url else { return false }
        return shouldLoad(url, request.mainDocumentURL == nil || request.mainDocumentURL == url)
    }

    @objc(webViewDidStartLoad:)
    func webViewDidStartLoad(_ webView: UIView) {
        RunLog.add("Web view started loading")
        didStart()
    }

    @objc(webViewDidFinishLoad:)
    func webViewDidFinishLoad(_ webView: UIView) {
        RunLog.add("Web view finished loading")
        didFinish()
    }

    @objc(webView:didFailLoadWithError:)
    func webView(_ webView: UIView, didFailLoadWithError error: NSError) {
        didFail(error)
    }
}
