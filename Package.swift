// swift-tools-version: 6.0
import PackageDescription

// The executables are single-threaded on the main queue, and the C callback APIs they use carry no
// concurrency annotations, so Swift 6 isolation checking would only add wrappers.
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
