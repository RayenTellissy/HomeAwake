// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HomeAwake",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "HomeAwakeCore"),
        .executableTarget(name: "homeawake-agent", dependencies: ["HomeAwakeCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "HomeAwake", dependencies: ["HomeAwakeCore"]),
        .testTarget(name: "HomeAwakeCoreTests", dependencies: ["HomeAwakeCore"]),
    ]
)
