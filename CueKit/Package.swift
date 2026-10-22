// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CueKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CueKit", targets: ["CueKit"])],
    targets: [
        .target(name: "CueKit", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "CueKitTests", dependencies: ["CueKit"], resources: [.copy("Fixtures")]),
    ]
)
