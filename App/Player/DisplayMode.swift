import AVFoundation
import AVKit
import CoreMedia
import UIKit

/// What the video is, as mpv reports it in `video-params`.
struct VideoFormat: Equatable {
    /// mpv's names: `bt.2020`, `bt.709`, …
    let primaries: String
    /// mpv's names: `pq`, `hlg`, `bt.1886`, …
    let gamma: String
    let fps: Double
    /// 5, 7 or 8 for a Dolby Vision track; nil otherwise.
    let dolbyVisionProfile: Int?

    enum Range {
        case sdr, hdr10, hlg
    }

    /**
     * The range the TV should switch to. Dolby Vision plays as HDR10: profiles
     * 7 and 8 carry an HDR10 base layer, and the decoder hands on that layer
     * without the Dolby Vision metadata, which the TV couldn't use from here.
     */
    var range: Range {
        if gamma == "hlg" { return .hlg }
        if gamma == "pq" || primaries.hasPrefix("bt.2020") || dolbyVisionProfile != nil { return .hdr10 }
        return .sdr
    }

    /// Profile 5 has no HDR10 base layer: without Dolby Vision processing its colours come out wrong.
    var needsDolbyVisionProcessing: Bool { dolbyVisionProfile == 5 }
}

/**
 * Asks tvOS for the TV mode the video wants: HDR10, HLG or SDR, at its frame
 * rate. tvOS applies it where Match Content (Dynamic Range and Frame Rate) is
 * on in Settings → Video and Audio. As the working aiostreams-tvos project does.
 */
enum DisplayMode {
    static func apply(_ format: VideoFormat, in window: UIWindow?) {
        guard let manager = window?.avDisplayManager else { return }
        let fps = format.fps > 0 ? format.fps : 24
        var extensions: [String: Any] = [kCMFormatDescriptionExtension_FullRangeVideo as String: false]
        switch format.range {
        case .sdr:
            extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
            extensions[kCMFormatDescriptionExtension_TransferFunction as String] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case .hdr10, .hlg:
            extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            extensions[kCMFormatDescriptionExtension_TransferFunction as String] = format.range == .hlg
                ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
                : kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        }
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: 3840,
            height: 2160,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else { return }
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: Float(fps), formatDescription: description)
    }

    /// Back to the TV's own mode once nothing plays.
    static func reset(in window: UIWindow?) {
        window?.avDisplayManager.preferredDisplayCriteria = nil
    }
}
