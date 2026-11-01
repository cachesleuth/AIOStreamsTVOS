import UIKit

/**
 * Carries the page's `player-*` and `now-playing` messages to mpv, and mpv's
 * reports back, as AIOStreams' Android PlayerChannel does. All on the main thread.
 */
final class PlayerChannel: MPVEngineListener {
    private let engine: MPVEngine
    private let send: (Message) -> Void
    private let showVideo: (Bool) -> Void
    private let subtitlesDir: URL
    let nowPlaying: NowPlaying

    private var state: Message = [:]
    private var tracks: [Message] = []
    private var chapters: [Message] = []
    private var heldPosition: Message?
    private var positionSentAt: CFTimeInterval = 0
    private var loaded = false
    private var nextSubtitle = 0

    init(engine: MPVEngine, subtitlesDir: URL, send: @escaping (Message) -> Void, showVideo: @escaping (Bool) -> Void) {
        self.engine = engine
        self.subtitlesDir = subtitlesDir
        self.send = send
        self.showVideo = showVideo
        nowPlaying = NowPlaying(send: send)
        engine.listener = self
    }

    var paused: Bool { state.flag("paused") != false }

    func change(_ change: Change) {
        engine.change(change)
    }

    /// False for a message that isn't the player's.
    func handle(_ type: String, _ message: Message) -> Bool {
        do {
            switch type {
            case "player-load":
                let request = try PlayerProtocol.load(message)
                loaded = true
                showVideo(true)
                engine.load(request)
            case "player-stop":
                loaded = false
                engine.stop()
                updateIdleTimer()
                endVideo()
            case "player-set":
                engine.change(try PlayerProtocol.change(message))
            case "player-seek":
                if let at = message.number("positionMs") { engine.seek(at) }
            case "player-subtitle-add":
                let url = message.text("url") ?? ""
                guard PlayerProtocol.isWebURL(url) else { throw ProtocolError("only http(s) subtitles load") }
                engine.addSubtitle(
                    url,
                    title: message.text("title"),
                    language: message.text("language"),
                    replace: message.number("replace").map { Int($0) }
                )
            case "player-style":
                engine.setStyle(try PlayerProtocol.style(message))
            case "player-settings":
                engine.setSettings(PlayerProtocol.settings(message))
            case "player-sync":
                send(stateMessage(state))
                send(["type": "player-tracks", "tracks": tracks])
                send(["type": "player-chapters", "chapters": chapters])
            case "subtitle-file":
                try addSubtitleFile(message)
            case "now-playing":
                let item = message.object("item")
                nowPlaying.setItem(item)
                if item == nil {
                    showVideo(false)
                    endVideo()
                }
            // No seek-bar thumbnails or subtitle index here: the page goes without them.
            case "player-thumbnail":
                send(["type": "player-thumbnail", "url": message.text("url") ?? "", "src": NSNull()])
            case "player-subtitle-index":
                send(["type": "player-subtitle-index", "tracks": NSNull()])
            case "player-subtitle-lines", "player-skips", "player-stats-overlay", "player-stats",
                 "player-controls", "player-retry", "player-unqueue":
                break
            default:
                return false
            }
        } catch let error as ProtocolError {
            reject(error.message)
        } catch {
            reject(error.localizedDescription)
        }
        return true
    }

    // MARK: MPVEngineListener

    func engineState(_ update: Message) {
        state.merge(update) { _, new in new }
        nowPlaying.update(state)
        updateIdleTimer()
        var rest = update
        let position = rest.removeValue(forKey: "positionMs")
        let buffered = rest.removeValue(forKey: "buffered")
        if !rest.isEmpty { send(stateMessage(rest)) }
        guard position != nil || buffered != nil else { return }
        // Positions come several times a second, so they go out at most every 250 ms.
        var held = heldPosition ?? [:]
        if let position { held["positionMs"] = position }
        if let buffered { held["buffered"] = buffered }
        let wait = Self.throttle - (CACurrentMediaTime() - positionSentAt)
        if wait <= 0 { return sendPosition(held) }
        if heldPosition == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                if let held = self?.heldPosition { self?.sendPosition(held) }
            }
        }
        heldPosition = held
    }

    func engineTracks(_ tracks: [Message]) {
        self.tracks = tracks
        send(["type": "player-tracks", "tracks": tracks])
    }

    func engineChapters(_ chapters: [Message]) {
        self.chapters = chapters
        send(["type": "player-chapters", "chapters": chapters])
    }

    func engineEvent(_ name: String) {
        send(["type": "player-event", "name": name])
    }

    /// The TV's picture mode follows the video; nil goes back to the TV's own.
    var onVideoFormat: (VideoFormat?) -> Void = { _ in }
    private var videoFormat: VideoFormat?

    func engineVideo(_ format: VideoFormat) {
        guard loaded, format != videoFormat else { return }
        videoFormat = format
        if format.needsDolbyVisionProcessing {
            NSLog("[player] Dolby Vision profile 5 has no HDR10 base layer; its colours will be off")
        }
        onVideoFormat(format)
    }

    private func endVideo() {
        guard videoFormat != nil else { return }
        videoFormat = nil
        onVideoFormat(nil)
    }

    func engineEnded(reason: String, error: String?, cause: String?) {
        var message: Message = ["type": "player-ended", "reason": reason, "error": nullable(error)]
        if let cause {
            message["cause"] = cause
            if let match = cause.range(of: "HTTP error (\\d{3})", options: .regularExpression),
               let status = Int(cause[match].suffix(3)) {
                message["status"] = status
            }
        }
        send(message)
    }

    // MARK: Private

    private static let throttle: CFTimeInterval = 0.25
    private static let subtitleTypes: Set<String> = ["srt", "vtt", "ass", "ssa", "sub", "sup"]
    private static let maxSubtitleBytes = 10 << 20

    private func sendPosition(_ position: Message) {
        heldPosition = nil
        positionSentAt = CACurrentMediaTime()
        send(stateMessage(position))
    }

    private func stateMessage(_ fields: Message) -> Message {
        var message = fields
        message["type"] = "player-state"
        return message
    }

    /// Keeps the screen saver off while a video plays.
    private func updateIdleTimer() {
        let playing = loaded && state.flag("paused") == false && state.flag("idle") != true
        if UIApplication.shared.isIdleTimerDisabled != playing {
            UIApplication.shared.isIdleTimerDisabled = playing
        }
    }

    /// The page names no path for mpv to open, so the file is written here first.
    private func addSubtitleFile(_ message: Message) throws {
        guard let name = message.text("name") else { throw ProtocolError("subtitle file without a name") }
        let ext = (name as NSString).pathExtension.lowercased()
        guard Self.subtitleTypes.contains(ext) else { throw ProtocolError("\(name) is not a subtitle file") }
        guard let data = Data(base64Encoded: message.text("data") ?? "", options: .ignoreUnknownCharacters) else {
            throw ProtocolError("\(name) could not be read")
        }
        guard data.count <= Self.maxSubtitleBytes else { throw ProtocolError("\(name) is too big") }
        try FileManager.default.createDirectory(at: subtitlesDir, withIntermediateDirectories: true)
        nextSubtitle += 1
        let file = subtitlesDir.appendingPathComponent("\(nextSubtitle).\(ext)")
        try data.write(to: file)
        engine.addSubtitle(file.path, title: String(name.prefix(200)), language: nil, replace: nil)
    }

    private func reject(_ message: String) {
        NSLog("[player] refused: %@", message)
        send(["type": "error", "message": message])
    }
}
