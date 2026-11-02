import CoreGraphics
import Foundation
import ImageIO
import MPVKit

/**
 * Seek-bar thumbnails, answering the page's `player-thumbnail` asks as
 * AIOStreams' desktop and Android apps do: the keyframe at or before the
 * position, the newest ask wins, the keyframe in `showingMs` isn't sent again,
 * and each picture is a JPEG the page loads from `/thumbnail/<file>-<ms>.jpg`.
 *
 * Those apps decode keyframes with AIOStreams/media, which loads FFmpeg as a
 * shared library. Here FFmpeg is linked into MPVKit without its headers, so
 * silent mpvs make them: each opens the file paused, seeks to keyframes and
 * renders each in software at thumbnail size.
 *
 * Two of them run, as most of a picture's wait is the network: one is kept for
 * the page's next ask, and the other finds the remote's scrub row's next
 * pictures before the page asks, as those apps fetch several keyframes at once.
 * Everything but `want` and `close` runs on one serial queue.
 */
final class Thumbnails {
    private let send: (Message) -> Void
    private let queue = DispatchQueue(label: "thumbnails", qos: .utility)

    private struct Ask {
        let ms: Int64
        let showing: Int64?
    }

    /// Positions `from` to `to` have `keyframe` as theirs.
    private struct Span {
        let from: Int64
        let to: Int64
        let keyframe: Int64
    }

    /// One mpv and the keyframe it's finding.
    private final class Worker {
        var decoder: ThumbnailDecoder?
        /// The position it's seeking to.
        var target: Int64?
        /// The page's ask for `target`; without one, it's finding it ahead of the page.
        var ask: Ask?
        var giveUp: DispatchWorkItem?
        /// It failed on this file, so it sits out.
        var broken = false

        /// Free for a seek: nothing in flight, and the first picture already come if it's open.
        var free: Bool { !broken && target == nil && (decoder?.ready ?? true) }
    }

    // Used on `queue` only.
    private let workers = (0..<Thumbnails.workerCount).map { _ in Worker() }
    private var url: String?
    private var headers: [String: String] = [:]
    private var file = 0
    /// The file has no thumbnails.
    private var none = false
    private var wanted: Ask?
    private var spans: [Span] = []
    /// The scrub row's recent asks, which come without `showingMs`, and when.
    private var rowAsks: [(ms: Int64, at: TimeInterval)] = []
    /// Positions found ahead that took too long, not tried ahead again.
    private var skipped = Set<Int64>()
    private var idle: DispatchWorkItem?

    init(send: @escaping (Message) -> Void) {
        self.send = send
    }

    /// The keyframe at or before `positionMs`; without one, only opens the file, so the first ask waits less.
    func want(url: String, headers: [String: String], positionMs: Double?, showingMs: Double?) {
        let position = positionMs.map { Int64(max(0, $0).rounded()) }
        let showing = showingMs.map { Int64($0.rounded()) }
        queue.async { [self] in ask(url, headers, position, showing) }
    }

    /// The page closed the player.
    func close() {
        queue.async { [self] in
            reset()
            idle?.cancel()
            idle = nil
        }
    }

    // MARK: On `queue`

    private func ask(_ url: String, _ headers: [String: String], _ position: Int64?, _ showing: Int64?) {
        if url != self.url {
            reset()
            self.url = url
            self.headers = headers
            file += 1
        }
        if none { return answer(nil) }
        stayOpen()
        guard let position else {
            if let first = workers.first, first.decoder == nil, !first.broken { open(first, at: nil) }
            return
        }
        if showing == nil { noteRow(position) }
        wanted = Ask(ms: position, showing: showing)
        pump()
    }

    /// Answers the newest ask from what's known or hands it to a free mpv, then finds what the row asks next.
    private func pump() {
        guard !none else { return }
        if let ask = wanted {
            if let keyframe = known(ask.ms) {
                wanted = nil
                if keyframe != ask.showing { answer(keyframe) }
            } else if let ahead = workers.first(where: { $0.target == ask.ms && $0.ask == nil }) {
                // Already being found ahead of the page.
                wanted = nil
                ahead.ask = ask
            } else if let worker = workers.first(where: { $0.free }) {
                wanted = nil
                start(worker, at: ask.ms, for: ask)
            }
        }
        findAhead()
    }

    /**
     * The row's pictures are a step apart around where the remote scrubs to,
     * and the page asks for them one at a time, so the ones a step or more
     * from the latest are found while it waits on that one.
     */
    private func findAhead() {
        guard !none, wanted == nil, let latest = rowAsks.last?.ms, let step = rowStep() else { return }
        let free = workers.filter { $0.free }
        // One stays free for the page's next ask.
        guard free.count >= 2, let worker = free.last else { return }
        let end = workers.lazy.compactMap { $0.decoder?.durationMs }.first
        for k in 1...Self.aheadSteps {
            for sign: Int64 in [1, -1] {
                let ms = latest + sign * Int64(k) * step
                guard ms >= 0, end.map({ ms <= $0 }) ?? true, known(ms) == nil, !skipped.contains(ms),
                      !workers.contains(where: { $0.target == ms })
                else { continue }
                return start(worker, at: ms, for: nil)
            }
        }
    }

    private func noteRow(_ ms: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        rowAsks.removeAll { now - $0.at > Self.rowWindow }
        rowAsks.append((ms, now))
        if rowAsks.count > 6 { rowAsks.removeFirst(rowAsks.count - 6) }
    }

    /// The row's step: the smallest gap between its recent asks.
    private func rowStep() -> Int64? {
        var step: Int64?
        for (i, a) in rowAsks.enumerated() {
            for b in rowAsks[(i + 1)...] {
                let gap = abs(a.ms - b.ms)
                if gap >= Self.minStep, gap < (step ?? .max) { step = gap }
            }
        }
        return step
    }

    private func start(_ worker: Worker, at ms: Int64, for ask: Ask?) {
        worker.target = ms
        worker.ask = ask
        if let decoder = worker.decoder {
            decoder.seek(ms)
        } else {
            open(worker, at: ms)
            guard worker.decoder != nil else { return }
        }
        worker.giveUp?.cancel()
        let item = DispatchWorkItem { [weak self, weak worker] in
            guard let self, let worker, worker.target == ms else { return }
            NSLog("[thumbnails] no picture for %lld ms in time", ms)
            if worker.ask == nil { self.skipped.insert(ms) }
            worker.target = nil
            worker.ask = nil
            self.pump()
        }
        worker.giveUp = item
        queue.asyncAfter(deadline: .now() + Self.askTimeout, execute: item)
    }

    private func open(_ worker: Worker, at ms: Int64?) {
        guard let url, !worker.broken else { return }
        do {
            let opened = try ThumbnailDecoder(url: url, headers: headers, startMs: ms, queue: queue) {
                [weak self, weak worker] event in
                guard let self, let worker else { return }
                self.decoded(event, by: worker)
            }
            worker.decoder = opened
            // A file that never shows its first picture opens again for the next ask.
            queue.asyncAfter(deadline: .now() + Self.askTimeout) { [weak self, weak worker, weak opened] in
                guard let self, let worker, let opened, worker.decoder === opened, !opened.ready else { return }
                NSLog("[thumbnails] the file showed no picture in time")
                self.closeDecoder(worker)
                self.pump()
            }
        } catch {
            broke(worker, (error as? ProtocolError)?.message ?? error.localizedDescription)
        }
    }

    private func decoded(_ event: ThumbnailDecoder.Event, by worker: Worker) {
        switch event {
        case .failed(let reason):
            broke(worker, reason)
        case .frame(let keyframe, let jpeg):
            ThumbnailStore.keep(path(keyframe), jpeg)
            worker.giveUp?.cancel()
            worker.giveUp = nil
            if let target = worker.target {
                // A seek lands after its position only before the file's first keyframe.
                learn(Span(from: min(keyframe, target), to: max(keyframe, target), keyframe: keyframe))
                if let ask = worker.ask, keyframe != ask.showing { answer(keyframe) }
                worker.target = nil
                worker.ask = nil
            } else {
                learn(Span(from: keyframe, to: keyframe, keyframe: keyframe))
            }
            pump()
        }
    }

    /// One mpv failed: the others carry on, and the file has none only once all have failed.
    private func broke(_ worker: Worker, _ reason: String) {
        let ask = worker.ask
        closeDecoder(worker)
        worker.broken = true
        guard !workers.allSatisfy({ $0.broken }) else { return fail(reason) }
        NSLog("[thumbnails] one of the decoders stopped: %@", reason)
        if let ask, wanted == nil { wanted = ask }
        pump()
    }

    private func fail(_ reason: String) {
        NSLog("[thumbnails] none for this file: %@", reason)
        none = true
        workers.forEach(closeDecoder)
        wanted = nil
        answer(nil)
    }

    /// Sends the keyframe's picture, or with nil, that the file has none.
    private func answer(_ keyframe: Int64?) {
        guard let url else { return }
        var message: Message = ["type": "player-thumbnail", "url": url, "src": NSNull()]
        if let keyframe {
            message["positionMs"] = Double(keyframe)
            message["src"] = path(keyframe)
        }
        DispatchQueue.main.async { [send] in send(message) }
    }

    private func path(_ keyframe: Int64) -> String {
        "\(ThumbnailStore.prefix)\(file)-\(keyframe).jpg"
    }

    private func learn(_ span: Span) {
        spans.append(span)
        if spans.count > Self.keptSpans { spans.removeFirst(spans.count - Self.keptSpans) }
    }

    /// A keyframe found before for `ms` whose picture is still kept.
    private func known(_ ms: Int64) -> Int64? {
        guard let span = spans.last(where: { $0.from <= ms && ms <= $0.to }),
              ThumbnailStore.has(path(span.keyframe))
        else { return nil }
        return span.keyframe
    }

    /// A paused mpv holds a connection and a decoder, so they close when the page stops asking.
    private func stayOpen() {
        idle?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.workers.allSatisfy({ $0.target == nil }) else { return }
            self.workers.forEach(self.closeDecoder)
        }
        idle = item
        queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: item)
    }

    private func closeDecoder(_ worker: Worker) {
        worker.decoder?.destroy()
        worker.decoder = nil
        worker.target = nil
        worker.ask = nil
        worker.giveUp?.cancel()
        worker.giveUp = nil
    }

    private func reset() {
        for worker in workers {
            closeDecoder(worker)
            worker.broken = false
        }
        url = nil
        headers = [:]
        none = false
        wanted = nil
        spans = []
        rowAsks = []
        skipped = []
    }

    private static let workerCount = 2
    /// How many steps either side of the row's latest ask are found ahead.
    private static let aheadSteps = 4
    /// The row's asks older than this belong to an earlier scrub.
    private static let rowWindow: TimeInterval = 10
    private static let minStep: Int64 = 1000
    private static let askTimeout: TimeInterval = 10
    private static let idleTimeout: TimeInterval = 45
    private static let keptSpans = 4096
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

/**
 * One file in a paused, silent mpv drawing through the software render API.
 * Each seek's keyframe comes back as a JPEG once mpv has both restarted
 * playback there and handed over a new frame. Used on the given queue only.
 */
private final class ThumbnailDecoder {
    enum Event {
        case frame(keyframe: Int64, jpeg: Data)
        case failed(String)
    }

    /// The picture's width; the page shows it about 224 points wide.
    private static let width = 384

    private let queue: DispatchQueue
    private let report: (Event) -> Void
    private var mpv: OpaquePointer?
    private var render: OpaquePointer?
    /// Keeps this alive for mpv's callbacks until both are gone.
    private var retained: Unmanaged<ThumbnailDecoder>?

    /// The first picture came, so seeks can go.
    private(set) var ready = false
    /// The file's length, once it's loaded.
    private(set) var durationMs: Int64?
    private var restarted = false
    private var fresh = false
    private var keyframeMs: Int64 = 0

    private var pixels: UnsafeMutableRawPointer?
    private var pixelBytes = 0
    private var width = 0
    private var height = 0
    // What mpv_render_context_render reads, kept for the decoder's life.
    private let swSize = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
    private let swStride = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private let swFormat = strdup("rgb0")!
    private let noBlock = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    init(url: String, headers: [String: String], startMs: Int64?, queue: DispatchQueue,
         report: @escaping (Event) -> Void) throws {
        self.queue = queue
        self.report = report
        guard let mpv = mpv_create() else { throw ProtocolError("libmpv could not start") }
        for (name, value) in Self.options {
            mpv_set_option_string(mpv, name, value)
        }
        mpv_request_log_messages(mpv, "error")
        guard mpv_initialize(mpv) >= 0 else {
            mpv_terminate_destroy(mpv)
            throw ProtocolError("libmpv could not start")
        }
        let api = strdup("sw")!  // MPV_RENDER_API_TYPE_SW
        defer { free(api) }
        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api)),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        var context: OpaquePointer?
        guard mpv_render_context_create(&context, mpv, &params) >= 0, let context else {
            mpv_terminate_destroy(mpv)
            throw ProtocolError("mpv's software renderer could not start")
        }
        self.mpv = mpv
        render = context

        let retained = Unmanaged.passRetained(self)
        self.retained = retained
        mpv_set_wakeup_callback(mpv, { opaque in
            guard let opaque else { return }
            let decoder = Unmanaged<ThumbnailDecoder>.fromOpaque(opaque).takeUnretainedValue()
            decoder.queue.async { decoder.drain() }
        }, retained.toOpaque())
        // mpv's own thread calls it, which must not call back into mpv.
        mpv_render_context_set_update_callback(context, { opaque in
            guard let opaque else { return }
            let decoder = Unmanaged<ThumbnailDecoder>.fromOpaque(opaque).takeUnretainedValue()
            decoder.queue.async { decoder.updated() }
        }, retained.toOpaque())

        var options: [String] = []
        if let startMs, startMs > 0 { options.append("start=\(Self.seconds(startMs))") }
        if let fields = MPVEngine.headerFields(headers) { options.append(fields) }
        run(["loadfile", url, "replace", "-1", options.joined(separator: ",")])
    }

    deinit {
        pixels?.deallocate()
        swSize.deallocate()
        swStride.deallocate()
        free(swFormat)
        noBlock.deallocate()
    }

    /// Ends mpv; nothing is reported after.
    func destroy() {
        guard let mpv else { return }
        // In this order: the render context goes before the mpv it renders.
        if let render {
            mpv_render_context_set_update_callback(render, nil, nil)
            mpv_render_context_free(render)
        }
        render = nil
        mpv_set_wakeup_callback(mpv, nil, nil)
        mpv_terminate_destroy(mpv)
        self.mpv = nil
        retained?.release()
        retained = nil
    }

    func seek(_ ms: Int64) {
        restarted = false
        fresh = false
        run(["seek", Self.seconds(ms), "absolute+keyframes"])
    }

    // MARK: mpv

    /// A paused, silent player that reads no more of the file than a keyframe needs.
    private static let options: [(String, String)] = [
        ("vo", "libmpv"),
        ("ao", "null"),
        ("aid", "no"),
        ("sid", "no"),
        ("audio-file-auto", "no"),
        ("sub-auto", "no"),
        ("pause", "yes"),
        ("idle", "yes"),
        ("keep-open", "always"),
        ("force-window", "no"),
        ("untimed", "yes"),
        // Keyframes only, so each seek is one decode.
        ("hr-seek", "no"),
        // Otherwise mpv decodes the frame after the keyframe too, and waits for the first to draw, before it restarts.
        ("video-latency-hacks", "yes"),
        // Frames come back to memory for the software renderer.
        ("hwdec", "videotoolbox-copy"),
        ("hwdec-codecs", "all"),
        ("hwdec-software-fallback", "yes"),
        ("vd-lavc-threads", "2"),
        // The playing video has the bandwidth; this reads around each seek only.
        ("cache", "no"),
        ("demuxer-readahead-secs", "0"),
        ("demuxer-max-bytes", "16MiB"),
        ("demuxer-max-back-bytes", "0"),
        ("demuxer-mkv-subtitle-preroll", "no"),
        ("network-timeout", "10"),
        ("stream-lavf-o", "reconnect=1,reconnect_on_http_error=%23%408,429,500,502,503,504,reconnect_delay_max=15"),
        ("sws-fast", "yes"),
        // The user's mpv.conf is for the player, not this.
        ("config", "no"),
        ("load-scripts", "no"),
        ("osd-level", "0"),
        ("input-default-bindings", "no"),
        ("input-vo-keyboard", "no"),
        ("osc", "no"),
        ("ytdl", "no"),
        ("terminal", "no"),
    ]

    private func run(_ args: [String]) {
        guard let mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for arg in cargs { free(UnsafeMutablePointer(mutating: arg)) } }
        let status = mpv_command(mpv, &cargs)
        if status < 0 { NSLog("[thumbnails] %@: %@", args.first ?? "", String(cString: mpv_error_string(status))) }
    }

    private func property(_ name: String) -> String? {
        guard let mpv, let value = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    private func drain() {
        while let mpv, let event = mpv_wait_event(mpv, 0) {
            let id = event.pointee.event_id
            if id == MPV_EVENT_NONE || id == MPV_EVENT_SHUTDOWN { break }
            handle(event.pointee)
        }
    }

    private func handle(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_FILE_LOADED:
            if property("current-tracks/video/id") == nil { return report(.failed("the file has no video")) }
            if let mpv {
                var duration = 0.0
                mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &duration)
                if duration > 0 { durationMs = Int64(duration * 1000) }
            }
        case MPV_EVENT_PLAYBACK_RESTART:
            guard let mpv else { return }
            var position = 0.0
            mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &position)
            keyframeMs = Int64((max(0, position) * 1000).rounded())
            restarted = true
            finish()
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            if end.reason == MPV_END_FILE_REASON_ERROR {
                report(.failed(String(cString: mpv_error_string(end.error))))
            }
        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.data else { return }
            let log = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            let prefix = log.prefix.map { String(cString: $0) } ?? ""
            let text = (log.text.map { String(cString: $0) } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("[thumbnails/%@] %@", prefix, text)
        default:
            break
        }
    }

    /// mpv has a frame to draw: a seek's new one, or the last one again.
    private func updated() {
        guard let render else { return }
        let flags = mpv_render_context_update(render)
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
        var info = mpv_render_frame_info()
        let got = withUnsafeMutablePointer(to: &info) { pointer in
            mpv_render_context_get_info(
                render, mpv_render_param(type: MPV_RENDER_PARAM_NEXT_FRAME_INFO, data: UnsafeMutableRawPointer(pointer))
            )
        }
        let present = UInt64(MPV_RENDER_FRAME_INFO_PRESENT.rawValue)
        let redraw = UInt64(MPV_RENDER_FRAME_INFO_REDRAW.rawValue)
        let isNew = got >= 0 && info.flags & present != 0 && info.flags & redraw == 0
        // Every update is drawn, or mpv's video output waits on it.
        guard draw() else { return }
        if isNew {
            fresh = true
            finish()
        }
    }

    /// Renders the frame at thumbnail size, in the video's shape.
    private func draw() -> Bool {
        guard let mpv, let render else { return false }
        var dw: Int64 = 0
        var dh: Int64 = 0
        mpv_get_property(mpv, "video-params/dw", MPV_FORMAT_INT64, &dw)
        mpv_get_property(mpv, "video-params/dh", MPV_FORMAT_INT64, &dh)
        let w = Self.width
        var h = w * 9 / 16
        if dw > 0, dh > 0 {
            h = Int((Double(w) * Double(dh) / Double(dw) / 2).rounded()) * 2
            h = min(max(h, 2), w * 2)
        }
        let stride = w * 4
        if pixels == nil || pixelBytes != stride * h {
            pixels?.deallocate()
            pixelBytes = stride * h
            pixels = UnsafeMutableRawPointer.allocate(byteCount: pixelBytes, alignment: 64)
        }
        width = w
        height = h
        swSize[0] = Int32(w)
        swSize[1] = Int32(h)
        swStride.pointee = stride
        noBlock.pointee = 0
        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(swSize)),
            mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(swFormat)),
            mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(swStride)),
            mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: pixels),
            mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(noBlock)),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        let status = mpv_render_context_render(render, &params)
        if status < 0 {
            NSLog("[thumbnails] render: %@", String(cString: mpv_error_string(status)))
            return false
        }
        return true
    }

    /// With the seek done and its frame drawn, the picture goes out.
    private func finish() {
        guard restarted, fresh, let pixels else { return }
        restarted = false
        fresh = false
        ready = true
        guard let jpeg = ThumbnailPicture.jpeg(
            pixels, width: width, height: height, stride: width * 4,
            gamma: property("video-params/gamma"), primaries: property("video-params/primaries")
        ) else {
            return NSLog("[thumbnails] the picture at %lld ms could not be encoded", keyframeMs)
        }
        report(.frame(keyframe: keyframeMs, jpeg: jpeg))
    }

    private static func seconds(_ ms: Int64) -> String { String(format: "%.3f", Double(ms) / 1000) }
}

/**
 * mpv's software renderer hands over RGB in the video's own transfer and
 * primaries (tvOS's libmpv has no zimg to convert them), so HDR pictures are
 * tone mapped to SDR here, as the official apps' thumbnails are.
 */
enum ThumbnailPicture {
    static let quality = 0.75

    static func jpeg(_ pixels: UnsafeRawPointer, width: Int, height: Int, stride: Int,
                     gamma: String?, primaries: String?) -> Data? {
        var bytes = [UInt8](UnsafeRawBufferPointer(start: pixels, count: stride * height))
        if gamma == "pq" || gamma == "hlg" {
            toSDR(&bytes, width: width, height: height, stride: stride, hlg: gamma == "hlg", wide: primaries == "bt.2020")
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        let properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// SDR white, in nits (BT.2408's HDR reference white).
    private static let white: Float = 203
    /// Below this, in SDR whites, light is kept as it is; above it rolls off towards white.
    private static let knee: Float = 0.75

    private static func toSDR(_ bytes: inout [UInt8], width: Int, height: Int, stride: Int, hlg: Bool, wide: Bool) {
        let linear: [Float] = (0..<256).map { code in
            let e = Float(code) / 255
            return (hlg ? hlgNits(e) : pqNits(e)) / white
        }
        let encode: [UInt8] = (0...1023).map { i in UInt8((srgb(Float(i) / 1023) * 255).rounded()) }
        for y in 0..<height {
            var i = y * stride
            for _ in 0..<width {
                var r = linear[Int(bytes[i])]
                var g = linear[Int(bytes[i + 1])]
                var b = linear[Int(bytes[i + 2])]
                if wide {
                    // BT.2020 to BT.709 primaries, in linear light.
                    let r709: Float = 1.6605 * r - 0.5876 * g - 0.0728 * b
                    let g709: Float = -0.1246 * r + 1.1329 * g - 0.0083 * b
                    let b709: Float = -0.0182 * r - 0.1006 * g + 1.1187 * b
                    r = max(0, r709)
                    g = max(0, g709)
                    b = max(0, b709)
                }
                // Scaling all three by the brightest keeps the hue.
                let peak = max(r, max(g, b))
                if peak > knee {
                    let scale = rollOff(peak) / peak
                    r *= scale
                    g *= scale
                    b *= scale
                }
                bytes[i] = encode[Int(min(r, 1) * 1023)]
                bytes[i + 1] = encode[Int(min(g, 1) * 1023)]
                bytes[i + 2] = encode[Int(min(b, 1) * 1023)]
                i += 4
            }
        }
    }

    /// Continuous with the identity at the knee, and never reaching past white.
    private static func rollOff(_ x: Float) -> Float {
        let room: Float = 1 - knee
        return knee + room * (1 - expf(-(x - knee) / room))
    }

    /// SMPTE ST 2084's EOTF.
    private static func pqNits(_ e: Float) -> Float {
        let p = powf(e, 1 / 78.84375)
        let num = max(p - 0.8359375, 0)
        let den: Float = 18.8515625 - 18.6875 * p
        return 10000 * powf(num / den, 1 / 0.1593017578125)
    }

    /// BT.2100 HLG's inverse OETF, then its OOTF on a 1000-nit display, per channel.
    private static func hlgNits(_ e: Float) -> Float {
        let a: Float = 0.17883277
        let b: Float = 0.28466892
        let c: Float = 0.55991073
        let scene: Float = e <= 0.5 ? e * e / 3 : (expf((e - c) / a) + b) / 12
        return 1000 * powf(scene, 1.2)
    }

    private static func srgb(_ l: Float) -> Float {
        l <= 0.0031308 ? 12.92 * l : 1.055 * powf(l, 1 / 2.4) - 0.055
    }
}
