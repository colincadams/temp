// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BrickCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "BrickCore", targets: ["BrickCore"]),
    ],
    targets: [
        .target(name: "BrickCore"),
        // Plays a rendered sweep (ml/render_sweep.py) through the scan pipeline and scores it: `swift run brick-replay <folder>`.
        .executableTarget(name: "brick-replay", dependencies: ["BrickCore"], path: "Sources/BrickReplay"),
        .testTarget(name: "BrickCoreTests", dependencies: ["BrickCore"]),
    ]
)
