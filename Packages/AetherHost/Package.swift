// swift-tools-version: 6.1

import PackageDescription

/*
 * AetherEngine, for the app to link, pinned to one commit: the engine ships
 * its FFmpeg build with it, and the app is tested against one.
 *
 * The commit is on the app's fork (mickey2266/AetherEngine, branch
 * `aiostreams-7.56`): upstream 7.56.0 plus one fix. The engine's software
 * player (interlaced H.264 and the like) labelled 7.1 MPEG_7_1_C, which put
 * the side and rear surrounds in each other's speakers; it now labels it
 * WAVE_7_1 (Dolby's TrueHD 7.1 channel check on a Samsung HW-Q990F). The
 * AVPlayer route's FLAC bridge was right as upstream has it. Back to an
 * upstream version once that fix is released there.
 *
 * Its optional components (TrueHD Atmos and DTS:X object rendering, Dolby
 * Vision dual layer) stay off: the app plays TrueHD and DTS-HD as 7.1 PCM, as
 * Infuse does. To turn one on, add `traits: [...]` to the dependency here;
 * XcodeGen can't set a package's traits, which is why this package exists.
 */
let package = Package(
    name: "AetherHost",
    platforms: [.tvOS(.v18)],
    products: [
        .library(name: "AetherHost", targets: ["AetherHost"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mickey2266/AetherEngine", revision: "6de6385097104b0aa3fea11c92500ae0eaadc13c"),
    ],
    targets: [
        .target(
            name: "AetherHost",
            dependencies: [.product(name: "AetherEngine", package: "AetherEngine")]
        ),
    ]
)
