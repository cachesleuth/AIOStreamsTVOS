// swift-tools-version: 6.1

import PackageDescription

/*
 * AetherEngine, for the app to link, pinned to one commit: the engine ships
 * its FFmpeg build with it, and the app is tested against one.
 *
 * The commit is on the app's fork (mickey2266/AetherEngine, branch
 * `aiostreams-7.57`): upstream 7.57.0 plus one fix. The engine's software
 * player (interlaced H.264 and the like) labelled 7.1 MPEG_7_1_C, which put
 * the side and rear surrounds in each other's speakers; it now labels it
 * WAVE_7_1 (Dolby's TrueHD 7.1 channel check on a Samsung HW-Q990F). The
 * AVPlayer route's FLAC bridge was right as upstream has it. Back to an
 * upstream version once that fix is released there.
 *
 * TrueHD Atmos and DTS:X object rendering (`TrueHDObjectAudio`,
 * `DTSXObjectAudio`) are built in, for the page's Object audio switch (off by
 * default, `AetherPlayer.options`); TrueHD brings LibTrueHD with it. Without
 * the switch the app plays TrueHD and DTS-HD as 7.1 PCM, as Infuse does. The
 * other optional components (Dolby Vision dual layer, still reshaping) stay
 * off. XcodeGen can't set a package's traits, which is why this package exists.
 */
let package = Package(
    name: "AetherHost",
    platforms: [.tvOS(.v18)],
    products: [
        .library(name: "AetherHost", targets: ["AetherHost"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mickey2266/AetherEngine", revision: "053d4e4e05b43d1e83fe8346c92555dbc8690d27",
                 traits: ["TrueHDObjectAudio", "DTSXObjectAudio"]),
    ],
    targets: [
        .target(
            name: "AetherHost",
            dependencies: [.product(name: "AetherEngine", package: "AetherEngine")]
        ),
    ]
)
