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
        .testTarget(name: "BrickCoreTests", dependencies: ["BrickCore"]),
    ]
)
