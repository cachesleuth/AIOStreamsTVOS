import AetherHost
import UIKit

/**
 * Subtitles over the video, in the page's style. AetherEngine decodes them
 * (text, ASS as styled runs, and PGS, DVB and DVD pictures) and leaves the
 * drawing to the app, where mpv's libass drew them before.
 *
 * Cues carry the source's own timestamps, so they're matched against the
 * engine's source clock, less the page's subtitle delay. The page's sizes are
 * mpv's, in units of a 720-line picture, and are scaled to the picture here.
 */
@MainActor
final class SubtitleOverlay: UIView {
    /// The rectangle the picture fills, in this view's coordinates.
    var videoRect: @MainActor () -> CGRect = { .zero }

    /// Seconds; positive shows them later, as mpv's `sub-delay`.
    var delay: Double = 0 {
        didSet { if delay != oldValue { refresh() } }
    }

    private var cues: [SubtitleCue] = []
    private var time: Double = 0
    private var look: SubtitleLook?
    private var cropped = false
    /// What's drawn now, so a tick that changes nothing draws nothing.
    private var drawn: (ids: [Int], rect: CGRect, bounds: CGRect)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    func setCues(_ cues: [SubtitleCue]) {
        self.cues = cues
        refresh()
    }

    func setTime(_ seconds: Double) {
        time = seconds
        refresh()
    }

    func setStyle(_ style: Style) {
        look = style.subtitles
        cropped = style.fit == .crop
        redraw()
    }

    func reset() {
        cues = []
        time = 0
        redraw()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refresh()
    }

    /// Draws again even if the same cues show, as after a style change.
    private func redraw() {
        drawn = nil
        refresh()
    }

    private func refresh() {
        let at = time - delay
        let active = cues
            .filter { $0.startTime <= at && at < $0.endTime }
            .sorted { $0.startTime < $1.startTime }
        let rect = videoRect()
        let ids = active.map(\.id)
        if let drawn, drawn.ids == ids, drawn.rect == rect, drawn.bounds == bounds { return }
        drawn = (ids, rect, bounds)
        subviews.forEach { $0.removeFromSuperview() }
        guard !active.isEmpty, rect.width > 0, rect.height > 0 else { return }

        var stacks: [Int: CGFloat] = [:]
        for cue in active {
            switch cue.body {
            case .image(let image):
                place(image, in: rect)
            case .text(let text):
                placeText(attributed([SubtitleRun(text: text)]), cue.placement, in: rect, stacks: &stacks)
            case .richText(let runs):
                placeText(attributed(runs.map { SubtitleRun($0) }), cue.placement, in: rect, stacks: &stacks)
            }
        }
    }

    // MARK: Pictures

    /**
     * A picture's position is a fraction of the source's canvas, which is laid
     * over the picture width-aligned and centred, so a cue lands where the disc
     * put it, the black bars included. Without a canvas, it's the picture.
     */
    private func place(_ image: SubtitleImage, in rect: CGRect) {
        var canvas = rect
        if image.canvasSize.width > 0, image.canvasSize.height > 0 {
            let scale = rect.width / image.canvasSize.width
            let height = image.canvasSize.height * scale
            canvas = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        }
        let view = UIImageView(image: UIImage(cgImage: image.cgImage))
        view.contentMode = .scaleToFill
        view.frame = CGRect(
            x: canvas.minX + image.position.minX * canvas.width,
            y: canvas.minY + image.position.minY * canvas.height,
            width: image.position.width * canvas.width,
            height: image.position.height * canvas.height
        )
        addSubview(view)
    }

    // MARK: Text

    /// A run of text, from a plain cue or one of a styled cue's runs.
    private struct SubtitleRun {
        var text: String
        var color: SubtitleColor?
        var bold = false
        var italic = false
        var underline = false
        var strike = false

        init(text: String) {
            self.text = text
        }

        init(_ run: SubtitleTextRun) {
            text = run.text
            color = run.color
            bold = run.isBold
            italic = run.isItalic
            underline = run.isUnderlined
            strike = run.isStruckThrough
        }
    }

    /// mpv's sizes at sub-scale 1, in units of a 720-line picture.
    private static let fontUnits: CGFloat = 55
    private static let marginUnits: CGFloat = 22

    private func units(_ rect: CGRect) -> CGFloat { rect.height / 720 }

    private func attributed(_ runs: [SubtitleRun]) -> NSAttributedString {
        let look = look
        let unit = units(videoRect())
        let size = max(12, Self.fontUnits * CGFloat(look?.scale ?? 1) * unit)
        let fill = look.flatMap { Self.parseColor($0.color) } ?? .white
        let outlineColor = look.flatMap { Self.parseColor($0.outlineColor) } ?? .black
        let outline = CGFloat(look?.outlineSize ?? 1.65) * unit
        let shadowSize = CGFloat(look?.shadowSize ?? 0) * unit
        let forced = look?.forceStyle == true

        let text = NSMutableAttributedString()
        for run in runs {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if run.bold || look?.bold == true { traits.insert(.traitBold) }
            if run.italic && !forced { traits.insert(.traitItalic) }
            var font = UIFont.systemFont(ofSize: size, weight: traits.contains(.traitBold) ? .bold : .medium)
            if traits.contains(.traitItalic), let italic = font.fontDescriptor.withSymbolicTraits(traits) {
                font = UIFont(descriptor: italic, size: size)
            }
            // The cue's own colour, unless the page's style overrides the file's.
            var color = fill
            if !forced, let own = run.color { color = Self.uiColor(own) }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            if outline > 0 {
                // A negative width fills and strokes; the stroke straddles the edge, so it's twice the outline.
                attributes[.strokeColor] = outlineColor
                attributes[.strokeWidth] = -min(30, 2 * outline / size * 100)
            }
            if shadowSize > 0 {
                let shadow = NSShadow()
                shadow.shadowColor = outlineColor
                shadow.shadowOffset = CGSize(width: shadowSize, height: shadowSize)
                shadow.shadowBlurRadius = 0
                attributes[.shadow] = shadow
            }
            if run.underline && !forced { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.strike && !forced { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            text.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return text
    }

    /**
     * Bottom-aligned cues stack upwards from the page's position, top-aligned
     * ones down from the top, as libass does. ASS placement: `\an` 7–9 top,
     * 4–6 middle, 1–3 bottom; 1, 4 and 7 left, 3, 6 and 9 right.
     */
    private func placeText(
        _ text: NSAttributedString, _ placement: SubtitleTextPlacement?, in picture: CGRect,
        stacks: inout [Int: CGFloat]
    ) {
        guard text.length > 0 else { return }
        // Cropped, the picture runs off the screen; the text stays on it.
        let rect = cropped ? picture.intersection(bounds) : picture
        let unit = units(picture)
        let margin = Self.marginUnits * unit
        let alignment = placement?.alignment ?? 2
        let row = (alignment - 1) / 3  // 0 bottom, 1 middle, 2 top
        let column = (alignment - 1) % 3  // 0 left, 1 centre, 2 right

        let aligned = NSMutableAttributedString(attributedString: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = column == 0 ? .left : column == 2 ? .right : .center
        paragraph.lineBreakMode = .byWordWrapping
        aligned.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: aligned.length))
        let label = UILabel()
        label.numberOfLines = 0
        label.attributedText = aligned
        let maxWidth = rect.width - 2 * margin
        var size = label.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        size.width = min(size.width, maxWidth)

        let box = UIView()
        let pad: CGFloat = look?.box == true ? 0.25 * Self.fontUnits * CGFloat(look?.scale ?? 1) * unit : 0
        if look?.box == true, let back = look.flatMap({ Self.parseColor($0.backColor) }) {
            box.backgroundColor = back
            box.layer.cornerRadius = pad / 2
        }
        let boxSize = CGSize(width: size.width + 2 * pad, height: size.height + pad)

        var origin = CGPoint.zero
        switch column {
        case 0: origin.x = rect.minX + margin
        case 2: origin.x = rect.maxX - margin - boxSize.width
        default: origin.x = rect.midX - boxSize.width / 2
        }
        if let anchor = placement?.position {
            // An explicit `\pos`, as a fraction of the picture, at the point the alignment names.
            let point = CGPoint(x: picture.minX + anchor.x * picture.width, y: picture.minY + anchor.y * picture.height)
            origin.x = point.x - CGFloat(column) / 2 * boxSize.width
            origin.y = point.y - CGFloat(2 - row) / 2 * boxSize.height
        } else {
            switch row {
            case 2:
                let top = stacks[alignment] ?? rect.minY + margin
                origin.y = top
                stacks[alignment] = top + boxSize.height
            case 1:
                origin.y = rect.midY - boxSize.height / 2
            default:
                let position = CGFloat(look?.position ?? 100) / 100
                let bottom = stacks[alignment] ?? min(rect.maxY, picture.minY + picture.height * position) - margin
                origin.y = bottom - boxSize.height
                stacks[alignment] = origin.y
            }
        }
        box.frame = CGRect(origin: origin, size: boxSize)
        label.frame = CGRect(x: pad, y: pad / 2, width: size.width, height: size.height)
        box.addSubview(label)
        addSubview(box)
    }

    /// `#AARRGGBB` or `#RRGGBB`, as mpv reads them.
    private static func parseColor(_ text: String) -> UIColor? {
        guard text.hasPrefix("#"), let value = UInt64(text.dropFirst(), radix: 16) else { return nil }
        let hex = text.count - 1
        let alpha = hex == 8 ? CGFloat((value >> 24) & 0xff) / 255 : 1
        return UIColor(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: alpha
        )
    }

    private static func uiColor(_ color: SubtitleColor) -> UIColor {
        UIColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }
}
