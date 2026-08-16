// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalCommandCenter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CommandCenterCore", targets: ["CommandCenterCore"]),
        .executable(name: "CommandCenter", targets: ["CommandCenter"]),
    ],
    targets: [
        .target(
            name: "CommandCenterCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "CommandCenter",
            dependencies: ["CommandCenterCore"]
        ),
        .testTarget(
            name: "CommandCenterCoreTests",
            dependencies: ["CommandCenterCore"]
        ),
        .testTarget(
            name: "CommandCenterTests",
            dependencies: ["CommandCenter"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
