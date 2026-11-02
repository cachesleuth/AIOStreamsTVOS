import AetherHost
import CoreGraphics
import Foundation
import ImageIO

/**
 * Seek-bar thumbnails, answering the page's `player-thumbnail` asks as
 * AIOStreams' desktop and Android apps do: a keyframe's picture for the
 * position, the newest ask wins, the picture in `showingMs` isn't sent again,
 * and each picture is a JPEG the page loads from `/thumbnail/<file>-<ms>.jpg`.
 *
 * AetherEngine's FrameExtractor makes them: a decoder of its own on the file,
 * which seeks to the keyframe at or before a position, tone maps HDR and
 * Dolby Vision to SDR, and backs off while the playing video is short of data.
 * Asks are rounded to the second, so the scrub row's neighbours and repeats
 * come from what was made before. All on the main thread but the decoding.
 */
@MainActor
final class Thumbnails {
    private let send: (Message) -> Void
    private let engine: AetherEngine

    private var url: String?
    private var file = 0
    private var extractor: FrameExtractor?
    /// The newest ask not yet answered, in rounded milliseconds, and the picture showing then.
    private var wanted: (ms: Int64, showing: Int64?)?
    private var working = false
    /// Positions that gave no picture, not tried again for this file.
    private var failed = Set<Int64>()
    private var idle: DispatchWorkItem?

    init(engine: AetherEngine, send: @escaping (Message) -> Void) {
        self.engine = engine
        self.send = send
    }

    /// The picture for `positionMs`; without one, only opens the file, so the first ask waits less.
    func want(url: String, headers: [String: String], positionMs: Double?, showingMs: Double?) {
        if url != self.url {
            close()
            guard let address = URL(string: url) else { return }
            self.url = url
            file += 1
            extractor = engine.makeFrameExtractor(url: address, httpHeaders: headers)
        }
        stayOpen()
        guard let extractor else { return }
        guard let positionMs else {
            Task { await extractor.prewarm() }
            return
        }
        let ms = Int64(max(0, positionMs) / 1000) * 1000
        let showing = showingMs.map { Int64($0.rounded()) }
        if ThumbnailStore.has(path(ms)) {
            wanted = nil
            if ms != showing { answer(ms) }
            return
        }
        if failed.contains(ms) { return answer(nil) }
        wanted = (ms, showing)
        pump()
    }

    /// The page closed the player.
    func close() {
        idle?.cancel()
        idle = nil
        if let extractor { Task { await extractor.shutdown() } }
        extractor = nil
        url = nil
        wanted = nil
        failed = []
    }

    private func pump() {
        guard !working, let ask = wanted, let extractor else { return }
        wanted = nil
        working = true
        let file = file
        Task { [weak self] in
            let picture = await extractor.thumbnail(at: Double(ask.ms) / 1000, maxWidth: Self.width)
            let jpeg = picture.flatMap { Self.jpeg($0) }
            guard let self else { return }
            self.working = false
            guard file == self.file else { return self.pump() }
            if let jpeg {
                ThumbnailStore.keep(self.path(ask.ms), jpeg)
                // A newer ask went past this one; it's kept for when the row comes back to it.
                if self.wanted == nil, ask.ms != ask.showing { self.answer(ask.ms) }
            } else {
                NSLog("[thumbnails] none at %lld ms", ask.ms)
                self.failed.insert(ask.ms)
                if self.wanted == nil { self.answer(nil) }
            }
            self.pump()
        }
    }

    /// Sends the picture, or with nil, that there's none.
    private func answer(_ ms: Int64?) {
        guard let url else { return }
        var message: Message = ["type": "player-thumbnail", "url": url, "src": NSNull()]
        if let ms {
            message["positionMs"] = Double(ms)
            message["src"] = path(ms)
        }
        send(message)
    }

    private func path(_ ms: Int64) -> String {
        "\(ThumbnailStore.prefix)\(file)-\(ms).jpg"
    }

    /// A decoder holds a connection, so it closes when the page stops asking.
    private func stayOpen() {
        idle?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.working, let extractor = self.extractor else { return }
                self.extractor = nil
                Task { await extractor.shutdown() }
                // The next ask opens it again.
                self.url = nil
            }
        }
        idle = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleTimeout, execute: item)
    }

    /// The picture's width; the page shows it about 224 points wide.
    private static let width = 384
    private static let idleTimeout: TimeInterval = 45
    private static let quality = 0.75

    private static func jpeg(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}

/// The JPEGs the page was sent paths for, the newest 256, as the desktop and Android apps keep.
enum ThumbnailStore {
    static let prefix = "/thumbnail/"
    private static let kept = 256
    private static let lock = NSLock()
    private static var images: [String: Data] = [:]
    private static var order: [String] = []

    static func keep(_ path: String, _ jpeg: Data) {
        lock.lock()
        defer { lock.unlock() }
        if images.updateValue(jpeg, forKey: path) == nil { order.append(path) }
        while order.count > kept { images.removeValue(forKey: order.removeFirst()) }
    }

    /// For the web view's scheme handler.
    static func image(_ path: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return images[path]
    }

    static func has(_ path: String) -> Bool {
        image(path) != nil
    }
}
