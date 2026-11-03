// swift-tools-version: 6.1

import PackageDescription

/*
 * AetherEngine, for the app to link, pinned to one release: the engine ships
 * its FFmpeg build with it, and the app is tested against one.
 *
 * Upstream, without the app's fork (mickey2266/AetherEngine, branch
 * `aiostreams`), which wrote 7.1 FLAC in CoreMedia's channel order (f98f3bdb)
 * and then lossless surround as labelled 24-bit PCM (bab5795d, d9dde0cf).
 * Upstream writes 7.1 FLAC in FFmpeg's order, which measured with the side and
 * rear surrounds swapped; back to the fork if that shows again.
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
        .package(url: "https://github.com/superuser404notfound/AetherEngine", exact: "7.56.0"),
    ],
    targets: [
        .target(
            name: "AetherHost",
            dependencies: [.product(name: "AetherEngine", package: "AetherEngine")]
        ),
    ]
)
