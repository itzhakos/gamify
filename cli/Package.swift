// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "cross",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cross", targets: ["cross"]),
        // bottle/runtime/Steam logic shared with the GUI in app/
        .library(name: "CrossCore", targets: ["CrossCore"]),
    ],
    targets: [
        .target(
            name: "CrossCore",
            path: "Sources/CrossCore"
        ),
        .executableTarget(
            name: "cross",
            dependencies: ["CrossCore"],
            path: "Sources/cross"
        ),
    ]
)
