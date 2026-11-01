import QuartzCore

/**
 * The layer mpv draws into, beneath the web view. MoltenVK may set a 1×1
 * drawable to finish a frame early, which would flicker and can stick.
 * See https://github.com/mpv-player/mpv/pull/13651; the fix is MPVKit's demo's.
 */
final class MetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}
