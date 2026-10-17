// swift-tools-version: 5.9
import PackageDescription

// The Cross GUI. `./build.sh` turns the CrossApp executable into build/Cross.app.
let package = Package(
    name: "CrossApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "cross", path: "../cli"),
    ],
    targets: [
        .executableTarget(
            name: "CrossApp",
            dependencies: [.product(name: "CrossCore", package: "cross")],
            path: "Sources/CrossApp"
        ),
    ]
)
