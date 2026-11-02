import AetherHost
import Foundation

/**
 * Whether a freeze came from the stream running out or from the picture
 * falling behind with the data in hand, for the app menu's report.
 *
 * - The stream ran out: the buffer AVPlayer holds ahead falls toward nothing,
 *   playback stalls, and the source delivers less than the video plays.
 * - The picture fell behind: the buffer stays full while dropped frames climb.
 *
 * Fed the engine's 1 Hz telemetry; covers one file, from its load.
 */
struct PlaybackHealth {
    /// How far back the recent figures look.
    static let window: TimeInterval = 30

    private struct Sample {
        let at: TimeInterval
        let sourceBytes: Int64
        let dropped: Int?
        /// Only while playing: a pause or a load says nothing about keeping up.
        let buffer: Double?
    }

    private var samples: [Sample] = []
    private(set) var latest: LiveTelemetry?
    /// Times playback stopped to wait for data, after the first picture and outside seeks and reloads.
    private(set) var stalls = 0
    private(set) var lastStallAt: Date?

    /// Seconds the file has played for, from the 1 Hz ticks, for an estimate of the frames shown.
    private(set) var playedSeconds: Double = 0
    private var lastTick: TimeInterval?

    mutating func record(_ telemetry: LiveTelemetry, playing: Bool, at now: TimeInterval) {
        // A gap longer than a couple of ticks is the app away or the sampler stopped, not playing.
        if playing, let lastTick { playedSeconds += min(max(0, now - lastTick), 2) }
        lastTick = now
        latest = telemetry
        // A reload starts the session's counters again; figures across it would be nonsense.
        if let last = samples.last, telemetry.demuxerBytesFetched < last.sourceBytes {
            samples.removeAll()
        }
        samples.append(Sample(
            at: now,
            sourceBytes: telemetry.demuxerBytesFetched,
            dropped: telemetry.droppedFrameCount,
            buffer: playing ? telemetry.forwardBufferSeconds : nil
        ))
        samples.removeAll { now - $0.at > Self.window }
    }

    mutating func stalled() {
        stalls += 1
        lastStallAt = Date()
    }

    /// Seconds the recent figures cover.
    var span: TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.at - first.at
    }

    /// What the source delivered over the window, its pauses included: below the video's
    /// bitrate for long, and the buffer has to run out.
    var sourceMbps: Double? {
        guard let first = samples.first, let last = samples.last, span >= 5 else { return nil }
        return Double(last.sourceBytes - first.sourceBytes) * 8 / span / 1_000_000
    }

    /// Frames dropped over the window.
    var recentDropped: Int? {
        guard let first = samples.first?.dropped, let last = samples.last?.dropped, span >= 5 else { return nil }
        return max(0, last - first)
    }

    /// The least buffer held ahead while playing, over the window.
    var lowestBuffer: Double? { samples.compactMap(\.buffer).min() }

    var lines: [String] {
        guard let latest else { return ["Playback health: no figures yet"] }
        let covered = Int(span.rounded())
        var lines: [String] = []

        var buffer = "Buffer ahead: " + (latest.forwardBufferSeconds.map { Self.seconds($0) } ?? "unknown")
        if let lowest = lowestBuffer { buffer += ", lowest \(Self.seconds(lowest)) while playing in the last \(covered) s" }
        lines.append(buffer)

        var stallLine = "Stalls waiting for data: \(stalls)"
        if let at = lastStallAt { stallLine += ", last \(Int(Date().timeIntervalSince(at).rounded())) s ago" }
        lines.append(stallLine)

        var dropped = "Dropped frames: " + (latest.droppedFrameCount.map(String.init) ?? "unknown")
        if let recent = recentDropped { dropped += ", \(recent) in the last \(covered) s" }
        lines.append(dropped)

        var rates: [String] = []
        if let played = latest.instantBitrateMbps { rates.append("video plays at \(Self.mbps(played))") }
        if let source = sourceMbps { rates.append("source delivered \(Self.mbps(source)) over the last \(covered) s") }
        // On the AVPlayer route this is the in-app loopback to AVPlayer, not the Wi-Fi.
        if let link = latest.networkThroughputMbps { rates.append("loopback to AVPlayer \(Self.mbps(link))") }
        if !rates.isEmpty { lines.append("Rates: " + rates.joined(separator: ", ")) }

        if let ahead = latest.readerWindowAheadBytes {
            lines.append(String(format: "Read ahead of the demuxer: %.1f MB", Double(ahead) / 1_048_576))
        }
        lines.append("Producer restarts: \(latest.producerRestartCount)")
        return lines
    }

    private static func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }
    private static func mbps(_ value: Double) -> String { String(format: "%.1f Mbps", value) }
}
