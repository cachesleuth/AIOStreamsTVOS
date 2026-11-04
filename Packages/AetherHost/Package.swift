// swift-tools-version: 6.1

import PackageDescription

/*
 * AetherEngine, for the app to link, pinned to one commit: the engine ships
 * its FFmpeg build with it, and the app is tested against one.
 *
 * The commit is on the app's fork (mickey2266/AetherEngine, branch
 * `aiostreams-7.56`): upstream 7.56.0 plus two fixes for 7.1, where tvOS
 * played the side and rear surrounds of TrueHD and DTS-HD from each other's
 * speakers (Dolby's TrueHD 7.1 channel check on a Samsung HW-Q990F): the FLAC
 * bridge (AVPlayer) writes 7.1 in CoreMedia's channel order, and the software
 * player labels its 7.1 as WAVE_7_1 instead of MPEG_7_1_C. Back to an
 * upstream version once those fixes are released there.
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
        .package(url: "https://github.com/mickey2266/AetherEngine", revision: "12589aada128474eb6deda7d503181782ca1b8df"),
    ],
    targets: [
        .target(
            name: "AetherHost",
            dependencies: [.product(name: "AetherEngine", package: "AetherEngine")]
        ),
    ]
)
