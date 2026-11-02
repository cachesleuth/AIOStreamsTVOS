import AVFoundation
import Foundation
import MPVKit

/// What the engine reports, always on the main thread.
protocol MPVEngineListener: AnyObject {
    /// Only the fields that changed, in the page's `player-state` terms.
    func engineState(_ state: Message)
    func engineTracks(_ tracks: [Message])
    func engineChapters(_ chapters: [Message])
    /// `start`, `loaded` or `restart`.
    func engineEvent(_ name: String)
    func engineEnded(reason: String, error: String?, cause: String?)
    /// The video's colours and frame rate, for the TV's picture mode.
    func engineVideo(_ format: VideoFormat)
}

/**
 * libmpv with Streamyfin's vo_avfoundation output: VideoToolbox decodes, and
 * the frames go to an AVSampleBufferDisplayLayer with their HDR metadata, so
 * HDR10 and HLG reach the TV as HDR, and HDR10+ with its dynamic metadata. Set up as the working aiostreams-tvos
 * project does. Otherwise follows AIOStreams' Android MpvEngine: the same
 * options, the same properties observed and the same reports.
 * Every mpv call runs on one serial queue, never the main thread: mpv's video
 * output waits on the main thread as it starts.
 */
final class MPVEngine {
    private var mpv: OpaquePointer?
    private let queue = DispatchQueue(label: "mpv", qos: .userInitiated)
    weak var listener: MPVEngineListener?
    let configFile: URL
    /// What mpv draws into; it doesn't retain it, and the view outlives mpv.
    private weak var displayLayer: AVSampleBufferDisplayLayer?

    // Used on `queue` only.
    private var cause: String?
    private var styled: [String: String] = [:]
    private var subtitleScale: Double?
    private var hwdec: String?
    private var pictures = Set<String>()
    private var shownSubtitle: String?
    private var picture = false

    init(layer: AVSampleBufferDisplayLayer, configDir: URL, fontsDir: URL?) throws {
        configFile = configDir.appendingPathComponent("mpv.conf")
        displayLayer = layer
        guard let mpv = mpv_create() else { throw ProtocolError("libmpv could not start") }
        self.mpv = mpv

        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid)
        // In this order: Streamyfin found tvOS freezes leaving the player otherwise.
        for (name, value) in [
            ("vo", "avfoundation"),
            ("avfoundation-composite-osd", "no"),
            ("hwdec", "videotoolbox"),
            ("hwdec-codecs", "all"),
            ("hwdec-software-fallback", "yes"),
            // Tells the display layer the video's colours, so HDR reaches the TV as HDR.
            ("target-colorspace-hint", "yes"),
            // audiounit keeps video timed to the HDMI output's real clock.
            ("ao", "audiounit"),
            // Without it audiounit makes the audio session mixable, and tvOS gives Now Playing
            // and the remote's media commands only to an app whose audio doesn't mix.
            ("audio-exclusive", "yes"),
            ("audio-client-name", "AIOStreams"),
            ("config", "yes"),
            ("config-dir", configDir.path),
            ("video-rotate", "no"),
            // Streams from addons drop now and then; FFmpeg reconnects rather than ending the file.
            ("stream-lavf-o", "reconnect=1,reconnect_on_http_error=%23%408,429,500,502,503,504,reconnect_delay_max=15"),
            // libass can't open tvOS's own font files, so subtitles use the bundled Noto Sans.
            ("sub-font", Self.subtitleFont),
            ("sub-scale-with-window", "no"),
            ("sub-use-margins", "no"),
        ] {
            mpv_set_option_string(mpv, name, value)
        }
        if let fontsDir { mpv_set_option_string(mpv, "sub-fonts-dir", fontsDir.path) }
        Self.applyFixed(mpv, option: true)
        // Info, for vo_avfoundation's note that it passes HDR10+ metadata; only warnings are logged.
        mpv_request_log_messages(mpv, "info")
        guard mpv_initialize(mpv) >= 0 else {
            mpv_terminate_destroy(mpv)
            self.mpv = nil
            throw ProtocolError("libmpv could not start")
        }
        // The user's mpv.conf may set these, but the app drives playback itself.
        Self.applyFixed(mpv, option: false)
        for (name, format) in Self.observed {
            mpv_observe_property(mpv, 0, name, format)
        }
        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            Unmanaged<MPVEngine>.fromOpaque(context).takeUnretainedValue().drain()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        if let mpv {
            mpv_set_wakeup_callback(mpv, nil, nil)
            mpv_terminate_destroy(mpv)
        }
    }

    private static func applyFixed(_ mpv: OpaquePointer, option: Bool) {
        for (name, value) in [
            ("idle", "yes"),
            ("keep-open", "no"),
            ("force-window", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("osc", "no"),
            ("osd-bar", "no"),
            ("ytdl", "no"),
            ("terminal", "no"),
        ] {
            if option { mpv_set_option_string(mpv, name, value) } else { mpv_set_property_string(mpv, name, value) }
        }
    }

    // MARK: Requests

    func load(_ request: LoadRequest) {
        queue.async { [self] in
            var options: [String] = []
            if request.startMs > 0 { options.append("start=\(Self.seconds(request.startMs))") }
            options += Self.listOption("alang", request.audioLanguages)
            let slang = Self.listOption("slang", request.subtitleLanguages)
            switch request.subtitleMode {
            case .none: options.append("sid=no")
            case .forced: options += ["subs-fallback=no", "subs-fallback-forced=always"]
            case .always: options += slang + ["subs-fallback=yes", "subs-with-matching-audio=yes"]
            case .smart: options += slang + ["subs-with-matching-audio=no"]
            case .default: options += slang
            }
            if let fields = Self.headerFields(request.headers) { options.append(fields) }
            // A queued file replaces whatever was queued before it.
            if request.append { run(["playlist-clear"]) }
            run(["loadfile", request.url, request.append ? "append" : "replace", "-1", options.joined(separator: ",")])
        }
    }

    func stop() {
        queue.async { [self] in run(["stop"]) }
    }

    func change(_ change: Change) {
        queue.async { [self] in
            if let paused = change.paused { set("pause", Self.flag(paused)) }
            if let volume = change.volume { set("volume", String(Int((volume * 100).rounded()))) }
            if let muted = change.muted { set("mute", Self.flag(muted)) }
            if let speed = change.speed { set("speed", String(speed)) }
            if let audio = change.audio { set("aid", Self.trackValue(audio)) }
            if let subtitle = change.subtitle { set("sid", Self.trackValue(subtitle)) }
            if let delay = change.subtitleDelayMs { set("sub-delay", Self.seconds(delay)) }
        }
    }

    func seek(_ positionMs: Double) {
        queue.async { [self] in run(["seek", Self.seconds(positionMs), "absolute"]) }
    }

    /// From the server or a file the user added, shown in place of track `replace`.
    func addSubtitle(_ url: String, title: String?, language: String?, replace: Int?) {
        queue.async { [self] in
            if let replace { run(["sub-remove", String(replace)]) }
            run(["sub-add", url, "select", title ?? "", language ?? ""])
        }
    }

    /// Sets only what changed, so profiles in the user's mpv.conf keep what they set since.
    func setStyle(_ style: Style) {
        queue.async { [self] in
            let s = style.subtitles
            func put(_ name: String, _ value: String) {
                if styled.updateValue(value, forKey: name) != value { set(name, value) }
            }
            // The display layer scales the picture itself.
            let gravity: AVLayerVideoGravity
            switch style.fit {
            case .fit: gravity = .resizeAspect
            case .crop: gravity = .resizeAspectFill
            case .stretch: gravity = .resize
            }
            DispatchQueue.main.async { [weak self] in self?.displayLayer?.videoGravity = gravity }
            put("sub-ass-force-margins", Self.flag(style.fit == .crop))
            put("sub-bold", Self.flag(s.bold))
            put("sub-color", s.color)
            put("sub-outline-color", s.outlineColor)
            put("sub-outline-size", String(s.outlineSize))
            put("sub-shadow-offset", String(s.shadowSize))
            put("sub-shadow-color", s.outlineColor)
            put("sub-font", s.font ?? Self.subtitleFont)
            put("sub-back-color", s.backColor)
            put("sub-border-style", s.box ? "background-box" : "outline-and-shadow")
            put("sub-ass-override", s.forceStyle ? "force" : "scale")
            put("sub-pos", String(s.position))
            if subtitleScale != s.scale {
                subtitleScale = s.scale
                set("sub-scale", picture ? "1" : String(s.scale))
            }
        }
    }

    func setSettings(_ settings: PlayerSettings) {
        queue.async { [self] in
            let hwdec = settings.hardwareDecoding ? "videotoolbox" : "no"
            // Setting it mid-file overrides the file's own choice, so only when it changes.
            if hwdec != self.hwdec {
                self.hwdec = hwdec
                set("hwdec", hwdec)
            }
            set("audio-channels", ["stereo", "5.1", "7.1"].contains(settings.audioChannels) ? settings.audioChannels : "auto-safe")
            set("audio-spdif", settings.passthrough.joined(separator: ","))
            set("audio-delay", Self.seconds(settings.audioDelayMs))
            // The user's mpv.conf may size the cache instead.
            let config = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
            if !config.contains("demuxer-max-bytes") {
                let budget = (settings.cacheMb > 0 ? settings.cacheMb : Self.defaultCacheMb) << 20
                set("demuxer-max-bytes", String(budget - budget / 4))
                set("demuxer-max-back-bytes", String(budget / 4))
            }
        }
    }

    func reloadConfig() {
        queue.async { [self] in run(["load-config-file", configFile.path]) }
    }

    /// The video's colours and frame rate, read when mpv reports new video parameters.
    private func reportVideo(_ params: Message) {
        var fps = 0.0
        if let mpv { mpv_get_property(mpv, "container-fps", MPV_FORMAT_DOUBLE, &fps) }
        let dolbyVision = property("current-tracks/video/dolby-vision-profile").flatMap(Int.init)
        let format = VideoFormat(
            primaries: params["primaries"] as? String ?? "",
            gamma: params["gamma"] as? String ?? "",
            fps: fps,
            dolbyVisionProfile: dolbyVision
        )
        emit { $0.engineVideo(format) }
    }

    /**
     * One of the page's statistics pages, as text. mpv's own overlay is its
     * stats.lua, and tvOS's libmpv has no Lua, so the app writes the pages
     * from mpv's properties. Reads on mpv's queue, answers on the main thread.
     */
    func stats(page: String, done: @escaping (String) -> Void) {
        queue.async { [self] in
            func osd(_ name: String) -> String {
                guard let mpv, let value = mpv_get_property_osd_string(mpv, name) else { return "–" }
                defer { mpv_free(value) }
                let text = String(cString: value)
                return text.isEmpty ? "–" : text
            }
            func line(_ label: String, _ value: String) -> String {
                label.padding(toLength: 12, withPad: " ", startingAt: 0) + value
            }
            var lines: [String]
            switch page {
            case "2":
                lines = [
                    "Frame timings",
                    line("Display", "\(osd("display-fps")) Hz"),
                    line("Video", "\(osd("container-fps")) fps, estimated \(osd("estimated-vf-fps"))"),
                    line("A/V sync", osd("avsync")),
                    line("Dropped", "\(osd("frame-drop-count")) output, \(osd("decoder-frame-drop-count")) decoder"),
                    line("Mistimed", osd("mistimed-frame-count")),
                    line("Delayed", osd("vo-delayed-frame-count")),
                ]
            case "3":
                lines = [
                    "Cache",
                    line("Ahead", osd("demuxer-cache-duration")),
                    line("Held", osd("demuxer-cache-state/fw-bytes")),
                    line("Reading", "\(osd("cache-speed"))/s"),
                    line("Most", "\(osd("demuxer-max-bytes")) ahead, \(osd("demuxer-max-back-bytes")) behind"),
                    line("Waiting", osd("paused-for-cache")),
                ]
            case "5":
                lines = ["Tracks"]
                for kind in ["video", "audio", "sub"] {
                    let codec = osd("current-tracks/\(kind)/codec")
                    let title = osd("current-tracks/\(kind)/title")
                    let lang = osd("current-tracks/\(kind)/lang")
                    let name = ["video": "Video", "audio": "Audio", "sub": "Subtitles"][kind] ?? kind
                    lines.append(line(name, codec == "–" ? "none" : "\(codec) · \(lang) · \(title)"))
                }
            default:
                lines = [
                    "Playback",
                    line("Video", "\(osd("video-codec")) \(osd("video-params/w"))×\(osd("video-params/h")) \(osd("container-fps")) fps"),
                    line("Decoder", "\(osd("hwdec-current")) · \(osd("video-params/pixelformat"))"),
                    line("Colour", "\(osd("video-params/primaries")) · \(osd("video-params/gamma"))"),
                    line("Bitrate", "video \(osd("video-bitrate")) · audio \(osd("audio-bitrate"))"),
                    line("Audio", "\(osd("audio-codec-name")) \(osd("audio-params/channel-count")) ch \(osd("audio-params/samplerate")) Hz"),
                    line("Output", "\(osd("current-ao")) · \(osd("audio-out-params/format"))"),
                    line("Dropped", "\(osd("frame-drop-count")) output, \(osd("decoder-frame-drop-count")) decoder"),
                    line("Cache", "\(osd("demuxer-cache-duration")) ahead"),
                ]
            }
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async { done(text) }
        }
    }

    /// Reads on mpv's queue and answers on the main thread, which mpv's video output may be waiting on.
    func properties(_ names: [String], done: @escaping ([String: String]) -> Void) {
        queue.async { [self] in
            var values: [String: String] = [:]
            for name in names { values[name] = property(name) }
            DispatchQueue.main.async { done(values) }
        }
    }

    /// Reads on the calling thread; libmpv's getters are thread-safe.
    func property(_ name: String) -> String? {
        guard let mpv, let value = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    // MARK: mpv calls, on `queue`

    private func set(_ name: String, _ value: String) {
        guard let mpv else { return }
        let status = mpv_set_property_string(mpv, name, value)
        if status < 0 { NSLog("[mpv] set %@=%@: %@", name, value, String(cString: mpv_error_string(status))) }
    }

    private func run(_ args: [String]) {
        guard let mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for arg in cargs { free(UnsafeMutablePointer(mutating: arg)) } }
        let status = mpv_command(mpv, &cargs)
        if status < 0 { NSLog("[mpv] %@: %@", args.first ?? "", String(cString: mpv_error_string(status))) }
    }

    // MARK: Events

    private func drain() {
        queue.async { [weak self] in
            guard let self else { return }
            while let mpv = self.mpv, let event = mpv_wait_event(mpv, 0) {
                let id = event.pointee.event_id
                if id == MPV_EVENT_NONE { break }
                self.handle(event.pointee)
                if id == MPV_EVENT_SHUTDOWN { break }
            }
        }
    }

    private func emit(_ call: @escaping (MPVEngineListener) -> Void) {
        DispatchQueue.main.async { [weak self] in
            if let listener = self?.listener { call(listener) }
        }
    }

    private func handle(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            report(String(cString: property.name), MPVNode.value(of: property))
        case MPV_EVENT_START_FILE:
            cause = nil
            emit { $0.engineEvent("start") }
        case MPV_EVENT_FILE_LOADED:
            // mpv reports the tracks it picked only after this, which the page picks again on.
            for name in ["aid", "sid"] {
                if let value = property(name) { report(name, value) }
            }
            emit { $0.engineEvent("loaded") }
        case MPV_EVENT_PLAYBACK_RESTART:
            emit { $0.engineEvent("restart") }
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            let reason = Self.reasonName(end.reason)
            let error = end.reason == MPV_END_FILE_REASON_ERROR && end.error < 0
                ? String(cString: mpv_error_string(end.error)) : nil
            let cause = error == nil ? nil : self.cause
            self.cause = nil
            emit { $0.engineEnded(reason: reason, error: error, cause: cause) }
        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.data else { return }
            let log = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            let prefix = log.prefix.map { String(cString: $0) } ?? ""
            let text = (log.text.map { String(cString: $0) } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let level = log.log_level.rawValue
            // mpv's error names only the step that failed; FFmpeg's first network error says why.
            if level <= MPV_LOG_LEVEL_ERROR.rawValue, prefix == "ffmpeg", cause == nil {
                cause = text.replacingOccurrences(of: "^\\w+: ", with: "", options: .regularExpression)
            }
            // Said once per process by the HDR10+ build, on the first frame that carries it.
            if text.contains("HDR10+ dynamic metadata") { HDR10Plus.seenSinceLaunch = true }
            if level <= MPV_LOG_LEVEL_WARN.rawValue || text.contains("HDR10+") {
                NSLog("[mpv/%@] %@", prefix, text)
            }
        case MPV_EVENT_SHUTDOWN:
            if let mpv {
                mpv_set_wakeup_callback(mpv, nil, nil)
                mpv_terminate_destroy(mpv)
            }
            mpv = nil
        default:
            break
        }
    }

    /// An observed property's change, in the page's terms.
    private func report(_ name: String, _ value: Any?) {
        let number = value as? Double
        let on = value as? Bool == true
        var state: Message
        switch name {
        case "time-pos":
            guard let number else { return }
            state = ["positionMs": number * 1000]
        case "duration":
            guard let number else { return }
            state = ["durationMs": number * 1000]
        case "demuxer-cache-state":
            guard let cache = value as? Message else { return }
            state = ["buffered": Self.cacheRanges(cache)]
        case "pause": state = ["paused": on]
        case "paused-for-cache": state = ["buffering": on]
        case "seeking": state = ["seeking": on]
        case "idle-active": state = ["idle": on]
        case "volume":
            guard let number else { return }
            state = ["volume": number / 100]
        case "volume-max":
            guard let number else { return }
            state = ["maxVolume": number / 100]
        case "mute": state = ["muted": on]
        case "speed":
            guard let number else { return }
            state = ["speed": number]
        case "aid":
            state = ["audio": nullable(Self.trackId(value))]
        case "sid":
            shownSubtitle = Self.trackId(value)
            followSubtitle()
            state = ["subtitle": nullable(shownSubtitle)]
        case "audio-params/format":
            state = ["passthrough": (value as? String)?.hasPrefix("spdif") == true]
        case "track-list":
            let list = (value as? [Any])?.compactMap { $0 as? Message } ?? []
            pictures = Set(list.filter {
                $0["type"] as? String == "sub" && Self.pictureCodecs.contains($0["codec"] as? String ?? "")
            }.compactMap { ($0["id"] as? Int64).map(String.init) })
            followSubtitle()
            let tracks = list.compactMap(Self.track)
            emit { $0.engineTracks(tracks) }
            return
        case "video-params":
            if let params = value as? Message { reportVideo(params) }
            return
        case "chapter-list":
            let chapters: [Message] = ((value as? [Any]) ?? []).compactMap { item in
                guard let chapter = item as? Message else { return nil }
                var entry: Message = ["startMs": ((chapter["time"] as? Double) ?? 0) * 1000]
                if let title = chapter["title"] as? String { entry["title"] = title }
                return entry
            }
            emit { $0.engineChapters(chapters) }
            return
        default:
            return
        }
        emit { $0.engineState(state) }
    }

    /// Keeps a picture subtitle at its own size.
    private func followSubtitle() {
        let now = shownSubtitle.map(pictures.contains) ?? false
        guard now != picture else { return }
        picture = now
        guard let scale = subtitleScale else { return }
        set("sub-scale", now ? "1" : String(scale))
    }

    // MARK: Helpers

    private static let defaultCacheMb = 150
    private static let pictureCodecs: Set<String> = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"]

    private static let observed: [(String, mpv_format)] = [
        ("time-pos", MPV_FORMAT_DOUBLE),
        ("duration", MPV_FORMAT_DOUBLE),
        ("demuxer-cache-state", MPV_FORMAT_NODE),
        ("pause", MPV_FORMAT_FLAG),
        ("paused-for-cache", MPV_FORMAT_FLAG),
        ("seeking", MPV_FORMAT_FLAG),
        ("idle-active", MPV_FORMAT_FLAG),
        ("volume", MPV_FORMAT_DOUBLE),
        ("volume-max", MPV_FORMAT_DOUBLE),
        ("mute", MPV_FORMAT_FLAG),
        ("speed", MPV_FORMAT_DOUBLE),
        ("aid", MPV_FORMAT_STRING),
        ("sid", MPV_FORMAT_STRING),
        ("audio-params/format", MPV_FORMAT_STRING),
        ("track-list", MPV_FORMAT_NODE),
        ("chapter-list", MPV_FORMAT_NODE),
        ("video-params", MPV_FORMAT_NODE),
    ]

    /// The bundled font's family, which libass finds in `sub-fonts-dir`.
    static let subtitleFont = "Noto Sans"

    private static func flag(_ on: Bool) -> String { on ? "yes" : "no" }

    private static func seconds(_ ms: Double) -> String { String(format: "%.3f", ms / 1000) }

    private static func trackValue(_ pick: Pick) -> String {
        if case .track(let id) = pick { return id }
        return "no"
    }

    /// mpv reads a track id as `auto` until a file picks one.
    private static func trackId(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.allSatisfy(\.isASCIIDigit) else { return nil }
        return text
    }

    private static func listOption(_ name: String, _ values: [String]) -> [String] {
        values.enumerated().map { i, value in "\(name)\(i > 0 ? "-append" : "")=\(value)" }
    }

    /// mpv's `http-header-fields` for the headers; the length prefix keeps the list's commas in one option.
    private static func headerFields(_ headers: [String: String]) -> String? {
        guard !headers.isEmpty else { return nil }
        let list = headers.map { "\($0.key): \($0.value.replacingOccurrences(of: ",", with: "\\,"))" }
            .joined(separator: ",")
        return "http-header-fields=%\(list.utf8.count)%\(list)"
    }

    private static func reasonName(_ reason: mpv_end_file_reason) -> String {
        switch reason {
        case MPV_END_FILE_REASON_EOF: return "eof"
        case MPV_END_FILE_REASON_STOP: return "stop"
        case MPV_END_FILE_REASON_QUIT: return "quit"
        case MPV_END_FILE_REASON_ERROR: return "error"
        case MPV_END_FILE_REASON_REDIRECT: return "redirect"
        default: return "unknown"
        }
    }

    /// The cache's seekable ranges, or from where it reads to where it ends.
    private static func cacheRanges(_ cache: Message) -> [Message] {
        func range(_ start: Any?, _ end: Any?) -> Message? {
            guard let start = start as? Double, let end = end as? Double else { return nil }
            return ["startMs": start * 1000, "endMs": end * 1000]
        }
        var ranges = ((cache["seekable-ranges"] as? [Any]) ?? []).compactMap { item -> Message? in
            guard let r = item as? Message else { return nil }
            return range(r["start"], r["end"])
        }
        if ranges.isEmpty, let r = range(cache["reader-pts"], cache["cache-end"]) { ranges = [r] }
        return ranges.sorted { ($0["startMs"] as? Double ?? 0) < ($1["startMs"] as? Double ?? 0) }
    }

    private static func track(_ track: Message) -> Message? {
        let type: String
        switch track["type"] as? String {
        case "audio": type = "audio"
        case "sub": type = "subtitle"
        default: return nil
        }
        guard let id = track["id"] as? Int64 else { return nil }
        func on(_ name: String) -> Bool { track[name] as? Bool == true }
        var entry: Message = [
            "id": String(id),
            "type": type,
            "default": on("default"),
            "forced": on("forced"),
            "hearingImpaired": on("hearing-impaired"),
            "visualImpaired": on("visual-impaired"),
            "external": on("external"),
        ]
        if let title = track["title"] as? String { entry["title"] = title }
        if let lang = track["lang"] as? String { entry["language"] = lang }
        if let codec = track["codec"] as? String { entry["codec"] = codec }
        if let file = track["external-filename"] as? String { entry["url"] = file }
        return entry
    }
}
