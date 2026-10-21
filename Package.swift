// swift-tools-version: 6.0
import PackageDescription

let mainQueueOnly: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "HomeAwake",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "HomeAwakeCore"),
        .executableTarget(name: "homeawake-agent", dependencies: ["HomeAwakeCore"], swiftSettings: mainQueueOnly),
        .executableTarget(name: "HomeAwake", dependencies: ["HomeAwakeCore"], swiftSettings: mainQueueOnly),
        .testTarget(name: "HomeAwakeCoreTests", dependencies: ["HomeAwakeCore"]),
    ]
)
