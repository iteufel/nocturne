// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Nocturne",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NocturneKit", targets: ["NocturneKit"]),
        .library(name: "NocturneHostKit", targets: ["NocturneHostKit"])
    ],
    targets: [
        .target(name: "NocturneKit", path: "Sources/Shared"),
        .target(name: "NocturneFiles", dependencies: ["NocturneKit"], path: "Sources/FileProvider"),
        .target(name: "PTYBridge", path: "Sources/PTYBridge", publicHeadersPath: "include"),
        .target(name: "DisplayBridge", path: "Sources/DisplayBridge", publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]),
        .target(name: "MicrophoneBridge", path: "Sources/MicrophoneBridge", publicHeadersPath: "include", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "NocturneHostKit", dependencies: ["NocturneKit", "PTYBridge", "DisplayBridge", "MicrophoneBridge"], path: "Sources/HostKit"),
        .testTarget(name: "NocturneKitTests", dependencies: ["NocturneKit", "NocturneHostKit", "NocturneFiles"], path: "Tests", exclude: ["Client"])
    ]
)
