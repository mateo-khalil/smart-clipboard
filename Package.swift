// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SmartClipboard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SmartClipboard", targets: ["SmartClipboard"]),
        .executable(name: "clipbench", targets: ["clipbench"]),
        .executable(name: "cliphelper", targets: ["cliphelper"]),
    ],
    targets: [
        // No AppKit below this line: the core stays testable with `swift test`.
        .target(name: "ClipCore"),
        .target(name: "ClipStore", dependencies: ["ClipCore"]),
        // AppKit from here on.
        .target(name: "ClipPlatform", dependencies: ["ClipCore"]),
        .target(name: "ClipUI", dependencies: ["ClipCore", "ClipStore", "ClipPlatform"]),
        .executableTarget(name: "SmartClipboard", dependencies: ["ClipUI"]),
        .executableTarget(name: "clipbench", dependencies: ["ClipCore", "ClipStore"]),
        .executableTarget(name: "cliphelper", dependencies: ["ClipCore", "ClipPlatform"]),
        .testTarget(name: "ClipCoreTests", dependencies: ["ClipCore"]),
        .testTarget(name: "ClipStoreTests", dependencies: ["ClipCore", "ClipStore"]),
        .testTarget(name: "ClipPlatformTests", dependencies: ["ClipPlatform"]),
    ]
)
