// swift-tools-version: 6.1

import PackageDescription

/*
 * AetherEngine, for the app to link, pinned to one commit: the engine ships
 * its FFmpeg build with it, and the app is tested against one.
 *
 * The commit is on the app's fork, branch `aiostreams`: upstream 7.54.0 plus
 * 7.1 FLAC written in CoreMedia's channel order, so the side and rear
 * surrounds of TrueHD and DTS-HD 7.1 reach their own speakers (measured with
 * Dolby's TrueHD 7.1 channel check on a Samsung HW-Q990F). Back to an upstream
 * version once that fix is released there.
 *
 * Not the fork's next commit (bab5795d), which sends lossless surround as
 * 24-bit PCM with a labelled channel layout: it didn't widen the HDMI link
 * (the app's Dolby primer does that, `AudioOutput.startPrimer`), and on that
 * soundbar 7.1 TrueHD played each side surround and its rear surround alike.
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
        .package(url: "https://github.com/mickey2266/AetherEngine", revision: "f98f3bdb6117674f87380912d0a5f70863ae3612"),
    ],
    targets: [
        .target(
            name: "AetherHost",
            dependencies: [.product(name: "AetherEngine", package: "AetherEngine")]
        ),
    ]
)
