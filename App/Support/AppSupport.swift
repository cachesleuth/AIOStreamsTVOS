import UIKit

/// Who the app is to the page and to Jellyfin servers.
enum Identity {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    /// Kept by the app, since the page's storage may be cleared with the caches.
    static let deviceId: String = {
        let key = "aiostreams.deviceId"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    static let device = UIDevice.current.name.isEmpty ? "Apple TV" : UIDevice.current.name

    /// Ends in "iPad" so the web app offers the iOS players (Infuse, VLC) for external playback.
    static var userAgent: String {
        let os = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPad; CPU OS \(os) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) AIOStreamsTV/\(version)"
    }
}

/// The app's folders. tvOS keeps only caches on disk, which it may clear when space runs low.
enum AppFolders {
    static let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    static let mpv = caches.appendingPathComponent("mpv", isDirectory: true)
    static let shaders = caches.appendingPathComponent("shaders", isDirectory: true)
    static let subtitles = caches.appendingPathComponent("subtitles", isDirectory: true)

    static func create() {
        for folder in [mpv, shaders, subtitles] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }
}

/// The user's mpv.conf, kept in the defaults and written where mpv reads it at each start.
enum MPVConfig {
    private static let key = "aiostreams.mpvConf"
    static var file: URL { AppFolders.mpv.appendingPathComponent("mpv.conf") }

    static let starter = """
    # mpv's own options, read at start and when saved here.
    # See https://mpv.io/manual/stable/#options. The app keeps idle, keep-open,
    # force-window, osc, osd-bar, ytdl and the key bindings as it needs them.
    #
    # profile=fast
    # deband=yes

    """

    static var text: String {
        UserDefaults.standard.string(forKey: key) ?? starter
    }

    static func save(_ text: String) {
        UserDefaults.standard.set(text, forKey: key)
        writeFile()
    }

    static func writeFile() {
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }
}

/// Answers to the page's requests about the app itself.
enum AppAnswers {
    static func appInfo(engine: MPVEngine?) -> Message {
        [
            "type": "app-info",
            "app": "\(Identity.version) (tvOS)",
            "platform": "android",
            "mpv": nullable(engine?.property("mpv-version")),
            "ffmpeg": nullable(engine?.property("ffmpeg-version")),
            "ac3Encoder": false,
        ]
    }

    /// The mpv properties `videoLines` reads.
    static let videoProperties = [
        "current-vo", "hwdec-current", "video-params/pixelformat", "video-params/primaries", "video-params/gamma",
    ]

    /// How the video plays and what the TV was asked for, from `videoProperties`' values.
    static func videoLines(_ values: [String: String], window: UIWindow?) -> [String] {
        let matching = DisplayMode.matchingEnabled(in: window).map { $0 ? "on" : "off" } ?? "unknown"
        return [
            "Video output: \(values["current-vo"] ?? "none")",
            "Decoder: \(values["hwdec-current"] ?? "none")",
            "Pixel format: \(values["video-params/pixelformat"] ?? "none")",
            "Colours: \(values["video-params/primaries"] ?? "?"), \(values["video-params/gamma"] ?? "?")",
            "Match Content: \(matching)",
            "Display request: \(DisplayMode.lastReport)",
        ]
    }

    static func diagnostics(engine: MPVEngine?, video: [String: String], window: UIWindow?, web: String?, server: String?) -> Message {
        let lines = [
            "AIOStreams for Apple TV \(Identity.version)",
            "tvOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)",
            "mpv: \(engine?.property("mpv-version") ?? "not started")",
            "FFmpeg: \(engine?.property("ffmpeg-version") ?? "unknown")",
        ] + videoLines(video, window: window) + [
            "Web app: \(web ?? "unknown")",
            "Server: \(server ?? "none")",
        ]
        return ["type": "diagnostics", "text": lines.joined(separator: "\n")]
    }

    static let licenses: Message = [
        "type": "licenses",
        "texts": [
            "GNU General Public License, version 3: https://www.gnu.org/licenses/gpl-3.0.html",
            "SIL Open Font License, version 1.1: https://openfontlicense.org",
        ],
        "libraries": [
            ["name": "MPVKit (Streamyfin build)", "licence": "GPL-3.0", "url": "https://github.com/streamyfin/MPVKit", "texts": [0]],
            ["name": "mpv", "licence": "GPL-3.0", "url": "https://mpv.io", "texts": [0]],
            ["name": "FFmpeg", "licence": "GPL-3.0", "url": "https://ffmpeg.org", "texts": [0]],
            ["name": "Noto Sans", "licence": "OFL-1.1", "url": "https://notofonts.github.io", "texts": [1]],
        ] as [Message],
    ]

    /// This app doesn't update itself; it's built and installed from Xcode.
    static let updateState: Message = [
        "type": "update-state", "state": "off", "channel": NSNull(), "version": NSNull(), "error": NSNull(),
    ]
}

/// Back to the TV's home screen, as the Menu button does. tvOS has no public call for it.
func suspendApp() {
    UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
}
