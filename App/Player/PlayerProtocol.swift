import Foundation

/*
 * The page's player messages, as the desktop and Android apps read them
 * (AIOStreams' packages/android/playback Player.kt). The page names no mpv
 * command or property; each field is checked before mpv sees it.
 */

struct ProtocolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

enum SubtitleMode: String {
    case `default`, always, smart, forced, none
}

struct LoadRequest {
    let url: String
    let headers: [String: String]
    let startMs: Double
    /// Plays after the current file rather than in its place.
    let append: Bool
    let audioLanguages: [String]
    let subtitleLanguages: [String]
    let subtitleMode: SubtitleMode
}

/// A track to show, or none at all.
enum Pick: Equatable {
    case track(String)
    case off
}

struct Change {
    var paused: Bool?
    var volume: Double?
    var muted: Bool?
    var speed: Double?
    var audio: Pick?
    var subtitle: Pick?
    var subtitleDelayMs: Double?
}

enum Fit {
    case fit, crop, stretch
}

/// Colours are `#AARRGGBB` or `#RRGGBB`, sizes in mpv's units.
struct SubtitleLook {
    let scale: Double
    let bold: Bool
    let color: String
    let outlineColor: String
    let outlineSize: Double
    let shadowSize: Double
    /// A family libass finds through Core Text, or nil for mpv's own.
    let font: String?
    let backColor: String
    let box: Bool
    let forceStyle: Bool
    /// Percent of the height from the top where the bottom line sits.
    let position: Double
}

struct Style {
    let fit: Fit
    let subtitles: SubtitleLook
}

/// The settings the page sends that the player applies itself.
struct PlayerSettings {
    var hardwareDecoding = true
    /// `auto`, `stereo`, `5.1` or `7.1`.
    var audioChannels = "auto"
    /// In mpv's `audio-spdif` names.
    var passthrough: [String] = []
    var audioDelayMs = 0.0
    /// Megabytes of the stream to hold, 0 for the app's default.
    var cacheMb = 0
}

enum PlayerProtocol {
    static func isWebURL(_ value: String) -> Bool {
        guard let scheme = URL(string: value)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func load(_ message: Message) throws -> LoadRequest {
        guard let url = message.text("url") else { throw ProtocolError("player-load takes a url") }
        guard isWebURL(url) else { throw ProtocolError("only http(s) urls play") }
        return LoadRequest(
            url: url,
            headers: try headers(message["headers"]),
            startMs: message.number("startMs") ?? 0,
            append: message.flag("append") == true,
            audioLanguages: try languages(message["audioLanguages"]),
            subtitleLanguages: try languages(message["subtitleLanguages"]),
            subtitleMode: message.text("subtitleMode").flatMap(SubtitleMode.init(rawValue:)) ?? .default
        )
    }

    static func change(_ message: Message) throws -> Change {
        Change(
            paused: message.flag("paused"),
            volume: message.number("volume"),
            muted: message.flag("muted"),
            speed: message.number("speed"),
            audio: try pick(message, "audio"),
            subtitle: try pick(message, "subtitle"),
            subtitleDelayMs: message.number("subtitleDelayMs")
        )
    }

    static func style(_ message: Message) throws -> Style {
        guard let look = message.object("subtitles") else { throw ProtocolError("player-style takes subtitles") }
        func colour(_ name: String) throws -> String {
            guard let value = look.text(name), value.range(of: colourPattern, options: .regularExpression) != nil else {
                throw ProtocolError("\(name) is not a colour")
            }
            return value
        }
        let fit: Fit
        switch message.text("fit") {
        case "crop": fit = .crop
        case "stretch": fit = .stretch
        default: fit = .fit
        }
        return Style(
            fit: fit,
            subtitles: SubtitleLook(
                scale: look.number("scale") ?? 1,
                bold: look.flag("bold") == true,
                color: try colour("color"),
                outlineColor: try colour("outlineColor"),
                outlineSize: look.number("outlineSize") ?? 0,
                shadowSize: look.number("shadowSize") ?? 0,
                font: try look.text("font").flatMap(font),
                backColor: try colour("backColor"),
                box: look.flag("box") == true,
                forceStyle: look.text("override") == "force",
                position: look.number("position") ?? 100
            )
        )
    }

    static func settings(_ message: Message) -> PlayerSettings {
        var settings = PlayerSettings()
        settings.hardwareDecoding = message.flag("hardwareDecoding") != false
        settings.audioChannels = message.text("audioChannels") ?? "auto"
        // `passthroughAuto` keeps the formats the output decodes, which this app can't ask tvOS for.
        if message.flag("passthroughAuto") != true {
            settings.passthrough = (message["passthrough"] as? [Any])?
                .compactMap { $0 as? String }
                .filter { passthroughFormats.contains($0) } ?? []
        }
        settings.audioDelayMs = message.number("audioDelayMs") ?? 0
        settings.cacheMb = Int(message.number("cacheMb") ?? 0)
        return settings
    }

    /// The page's font names, which are Android's. libass here can only open the bundled Noto Sans, so all of them get it.
    private static func font(_ name: String) throws -> String? {
        switch name {
        case "sans-serif", "serif", "monospace", "serif-monospace", "casual", "cursive": return nil
        default: throw ProtocolError("\(name) is not a font")
        }
    }

    private static let colourPattern = "^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"
    private static let languagePattern = "^[A-Za-z0-9-]{1,16}$"
    private static let passthroughFormats: Set<String> = ["ac3", "eac3", "dts", "dts-hd", "truehd"]
    private static let headerNameCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~"
    )

    private static func headers(_ value: Any?) throws -> [String: String] {
        guard let map = value as? Message else { return [:] }
        var headers: [String: String] = [:]
        for (name, raw) in map {
            guard let text = raw as? String,
                  !name.isEmpty,
                  name.unicodeScalars.allSatisfy(headerNameCharacters.contains),
                  text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7e }),
                  // A backslash before mpv's list separator would escape it.
                  !text.hasSuffix("\\")
            else { throw ProtocolError("header \(name) is not allowed") }
            headers[name] = text
        }
        return headers
    }

    private static func languages(_ value: Any?) throws -> [String] {
        guard let list = value as? [Any] else { return [] }
        return try list.map { item in
            guard let code = item as? String, code.range(of: languagePattern, options: .regularExpression) != nil else {
                throw ProtocolError("\(item) is not a language")
            }
            return code
        }
    }

    private static func pick(_ message: Message, _ name: String) throws -> Pick? {
        guard let value = message[name] else { return nil }
        if value is NSNull { return .off }
        guard let id = value as? String, !id.isEmpty, id.allSatisfy(\.isASCIIDigit) else {
            throw ProtocolError("\(name) \(value) is not a track")
        }
        return .track(id)
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
