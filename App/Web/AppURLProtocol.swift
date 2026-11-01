import Foundation

/**
 * Serves the bundled web app at `http://aiostreams.localhost/`, so the page has
 * an origin of its own that keeps sign-ins and settings, and can call Jellyfin
 * servers on plain http without mixed-content blocks. The bridge script goes
 * into `index.html` ahead of the page's own scripts.
 */
final class AppURLProtocol: URLProtocol {
    static let host = "aiostreams.localhost"
    static let startURL = URL(string: "http://\(host)/index.html")!

    /// The script `index.html` gets first, made when the page is served.
    static var bootScript: () -> String = { "" }

    static let webRoot: URL? = Bundle.main.url(forResource: "WebBuild", withExtension: nil)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.lowercased() == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return fail(404) }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        guard let root = Self.webRoot?.standardizedFileURL else { return fail(404) }
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        // Nothing outside the bundled build.
        guard file.path.hasPrefix(root.path + "/"), var data = try? Data(contentsOf: file) else {
            RunLog.add("Not found in the app: \(path)")
            return fail(404)
        }
        if file.pathExtension.lowercased() == "css" {
            data = Self.plainFocus(data)
        }
        if file.lastPathComponent == "index.html" {
            let script = Self.bootScript()
            data = Self.inject(script, into: data)
            RunLog.add("Served index.html (\(data.count / 1024) KB, start-up script \(script.utf8.count / 1024) KB)")
        }
        let headers = [
            "Content-Type": Self.mimeType(file.pathExtension),
            "Content-Length": String(data.count),
            "Cache-Control": "no-cache",
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func fail(_ status: Int) {
        guard let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    /**
     * The page rings what has focus with `:focus-visible`, which UIWebView's
     * WebKit leaves off: its parser drops every rule that names it, ring and
     * all. With no pointer here, any focus is the remote's, so it becomes
     * `:focus` before WebKit reads the file. An escaped `\:focus-visible` is
     * part of a class name (Tailwind's `focus-visible:ring-1`) and stays.
     */
    private static let focusVisible = try! NSRegularExpression(pattern: "(?<!\\\\):focus-visible")

    static func plainFocus(_ css: Data) -> Data {
        guard let text = String(data: css, encoding: .utf8), text.contains(":focus-visible") else { return css }
        let range = NSRange(text.startIndex..., in: text)
        let replaced = focusVisible.stringByReplacingMatches(in: text, range: range, withTemplate: ":focus")
        return Data(replaced.utf8)
    }

    /// Right after `<head>`, before the page's inline script that checks for the bridge.
    static func inject(_ script: String, into html: Data) -> Data {
        guard var text = String(data: html, encoding: .utf8),
              let head = text.range(of: "<head>", options: .caseInsensitive)
        else { return html }
        let safe = script.replacingOccurrences(of: "</", with: "<\\/")
        text.insert(contentsOf: "<script>\(safe)</script>", at: head.upperBound)
        return Data(text.utf8)
    }

    private static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "gif": return "image/gif"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "wasm": return "application/wasm"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
