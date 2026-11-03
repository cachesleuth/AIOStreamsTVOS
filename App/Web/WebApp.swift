import Foundation

/**
 * The bundled web app (AIOStreams' standalone build, from scripts/fetch-web.sh),
 * served at `aiostv://localhost/` by AIOWebView. Its own scheme, apart from the
 * `aiostreams://` links players and the system send the app.
 */
enum WebApp {
    static let scheme = "aiostv"
    static let root: URL? = Bundle.main.url(forResource: "WebBuild", withExtension: nil)
    static let startURL = URL(string: "\(scheme)://localhost/index.html")!

    /// The AIOStreams commit the build came from, and how many of patches/web/ it was built with.
    static let commit: String = {
        guard let root,
              let text = try? String(contentsOf: root.appendingPathComponent("aiostreams-commit.txt"), encoding: .utf8)
        else { return "unknown" }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let hash = String((lines.first ?? "unknown").prefix(10))
        let patched = lines.filter { $0.hasPrefix("patched:") }.count
        return patched > 0 ? "\(hash) + \(patched) patches" : hash
    }()
}
