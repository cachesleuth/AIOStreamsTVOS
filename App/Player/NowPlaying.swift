import MediaPlayer
import UIKit

/**
 * What plays, for the TV's Now Playing screen and Control Center, and the
 * commands they send, which reach the page as `media-key` messages. The page
 * drops a command that repeats a remote press it just handled.
 */
final class NowPlaying {
    private let send: (Message) -> Void
    private var item: Message?
    private var artwork: (url: String, image: MPMediaItemArtwork?)?
    private var info: [String: Any] = [:]
    private var commandsOn = false

    init(send: @escaping (Message) -> Void) {
        self.send = send
    }

    func setItem(_ item: Message?) {
        self.item = item
        guard let item, let title = item.text("title") else {
            info = [:]
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            setCommands(false)
            return
        }
        info[MPMediaItemPropertyTitle] = title
        if let subtitle = item.text("subtitle") {
            info[MPMediaItemPropertyArtist] = subtitle
        } else {
            info.removeValue(forKey: MPMediaItemPropertyArtist)
        }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        if let url = item.text("artwork") { loadArtwork(url) }
        setCommands(true)
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = item.flag("next") == true
        center.previousTrackCommand.isEnabled = item.flag("previous") == true
        publish()
    }

    /// From the player's merged state.
    func update(_ state: Message) {
        guard item != nil else { return }
        let paused = state.flag("paused") != false
        let position = (state.number("positionMs") ?? 0) / 1000
        let duration = (state.number("durationMs") ?? 0) / 1000
        let rate = paused ? 0 : (state.number("speed") ?? 1)
        // The system moves the position on by itself between updates, so only big changes go out.
        let old = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? -10
        let oldRate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double
        let oldDuration = info[MPMediaItemPropertyPlaybackDuration] as? Double
        guard oldRate != rate || oldDuration != duration || abs(old + rate * 5 - position) > 5 else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPMediaItemPropertyPlaybackDuration] = duration
        publish()
    }

    private func publish() {
        if let image = artwork?.image { info[MPMediaItemPropertyArtwork] = image }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(_ url: String) {
        guard artwork?.url != url, let address = URL(string: url) else { return }
        artwork = (url, nil)
        URLSession.shared.dataTask(with: address) { [weak self] data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            DispatchQueue.main.async {
                guard let self, self.artwork?.url == url else { return }
                self.artwork = (url, art)
                self.publish()
            }
        }.resume()
    }

    private func key(_ key: Message) -> MPRemoteCommandHandlerStatus {
        send(["type": "media-key", "key": key])
        return .success
    }

    private func setCommands(_ on: Bool) {
        guard on != commandsOn else { return }
        commandsOn = on
        let center = MPRemoteCommandCenter.shared()
        let commands: [MPRemoteCommand] = [
            center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.stopCommand,
            center.nextTrackCommand, center.previousTrackCommand, center.changePlaybackPositionCommand,
            center.skipForwardCommand, center.skipBackwardCommand,
        ]
        guard on else {
            for command in commands { command.removeTarget(nil) }
            return
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.playCommand.addTarget { [weak self] _ in self?.key(["action": "play"]) ?? .commandFailed }
        center.pauseCommand.addTarget { [weak self] _ in self?.key(["action": "pause"]) ?? .commandFailed }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.key(["action": "toggle"]) ?? .commandFailed }
        center.stopCommand.addTarget { [weak self] _ in self?.key(["action": "stop"]) ?? .commandFailed }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.key(["action": "next"]) ?? .commandFailed }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.key(["action": "previous"]) ?? .commandFailed }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.key(["action": "seek", "position": event.positionTime * 1000]) ?? .commandFailed
        }
        center.skipForwardCommand.addTarget { [weak self] _ in self?.key(["action": "skip", "offset": 10_000]) ?? .commandFailed }
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.key(["action": "skip", "offset": -10_000]) ?? .commandFailed }
    }
}
