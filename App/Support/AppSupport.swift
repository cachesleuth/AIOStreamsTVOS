import os
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
    static let subtitles = caches.appendingPathComponent("subtitles", isDirectory: true)

    static func create() {
        try? FileManager.default.createDirectory(at: subtitles, withIntermediateDirectories: true)
        // mpv's folders, from before the app played with AetherEngine.
        for old in ["mpv", "shaders"] {
            try? FileManager.default.removeItem(at: caches.appendingPathComponent(old, isDirectory: true))
        }
    }
}

/**
 * What the page's mpv.conf editor shows. The page offers it while its engine
 * setting says mpv, but this app plays with AetherEngine, which has no
 * config file, so saving changes nothing.
 */
enum MPVConfig {
    static let text = """
    # This app plays with AetherEngine, not mpv, so options here do nothing.
    # Sound and subtitle settings are under Settings → Playback.

    """
}

/**
 * When the page's web process ended and what memory looked like then, to see
 * whether it runs out while browsing or while a video plays. The web process
 * is WebKit's own, so only the app's side can be measured here.
 */
enum MemoryLog {
    private(set) static var lines: [String] = []
    private(set) static var pageEnds = 0

    /// This app's own memory, as tvOS counts it against the app's limit.
    static var appMB: Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : nil
    }

    /// What the app may still take before tvOS ends it.
    static var leftMB: Int { Int(os_proc_available_memory() >> 20) }

    static var now: String {
        "app \(appMB.map { "\($0) MB" } ?? "?"), \(leftMB) MB left"
    }

    static func pageEnded(playing: Bool) {
        pageEnds += 1
        note("page's web process ended \(playing ? "with a video loaded" : "while browsing")")
    }

    static func warning(playing: Bool) {
        note("memory warning \(playing ? "with a video loaded" : "while browsing")")
    }

    private static func note(_ what: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "\(time): \(what); \(now)"
        NSLog("[memory] %@", line)
        lines.append(line)
        if lines.count > 6 { lines.removeFirst(lines.count - 6) }
    }

    /// For the app menu and the diagnostics.
    static var report: [String] {
        ["Memory: \(now); the page reloaded \(pageEnds) times since launch"] + lines
    }
}

/// Answers to the page's requests about the app itself.
@MainActor
enum AppAnswers {
    static func appInfo() -> Message {
        [
            "type": "app-info",
            "app": "\(Identity.version) (tvOS)",
            "platform": "android",
            "mpv": NSNull(),
            "ffmpeg": "FFmpeg in AetherEngine \(AetherPlayer.version)",
            "player": "AetherEngine \(AetherPlayer.version)",
            "ac3Encoder": false,
        ]
    }

    /// How the video and its sound play, what the TV does with them, and the engine's latest audio lines.
    static func videoLines(player: AetherPlayer?, window: UIWindow?) -> [String] {
        let matching = window.map { $0.avDisplayManager.isDisplayCriteriaMatchingEnabled ? "on" : "off" } ?? "unknown"
        var lines = player?.report ?? ["Player: not started"]
        lines.append("Match Content: \(matching)")
        let audio = EngineLogBook.recentAudio
        if !audio.isEmpty {
            lines.append("")
            lines.append("Engine's audio log, newest last:")
            lines += audio
        }
        return lines
    }

    static func diagnostics(player: AetherPlayer?, window: UIWindow?, web: String?, server: String?) -> Message {
        let lines = [
            "AIOStreams for Apple TV \(Identity.version)",
            "tvOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)",
        ] + videoLines(player: player, window: window) + [""] + MemoryLog.report + TopShelf.report + [
            "Web app: \(web ?? "unknown")",
            "Server: \(server ?? "none")",
        ]
        return ["type": "diagnostics", "text": lines.joined(separator: "\n")]
    }

    static let licenses: Message = [
        "type": "licenses",
        "texts": [
            "GNU Lesser General Public License, version 3, with AetherEngine's Apple Store exception: https://github.com/superuser404notfound/AetherEngine/blob/main/LICENSE",
            "GNU Lesser General Public License, version 2.1: https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html",
            "MIT License: https://opensource.org/license/mit",
        ],
        "libraries": [
            ["name": "AetherEngine", "licence": "LGPL-3.0", "url": "https://github.com/superuser404notfound/AetherEngine", "texts": [0]],
            ["name": "FFmpeg (FFmpegBuild)", "licence": "LGPL-2.1", "url": "https://github.com/superuser404notfound/FFmpegBuild", "texts": [1]],
            ["name": "libdovi (LibDovi)", "licence": "MIT", "url": "https://github.com/quietvoid/dovi_tool", "texts": [2]],
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
