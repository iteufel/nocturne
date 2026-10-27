// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Nocturne",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NocturneKit", targets: ["NocturneKit"]),
        .library(name: "NocturneHostKit", targets: ["NocturneHostKit"]),
        .library(name: "NocturneVoice", targets: ["NocturneVoice"])
    ],
    dependencies: [.package(url: "https://github.com/stasel/WebRTC.git", exact: "155.0.0")],
    targets: [
        .binaryTarget(name: "NocturneRemote", path: "Vendor/NocturneRemote.xcframework"),
        .target(name: "NocturneKit", dependencies: ["NocturneRemote"], path: "Sources/Shared",
            linkerSettings: [.linkedFramework("SystemConfiguration"), .linkedFramework("Security"),
                .linkedFramework("CoreWLAN", .when(platforms: [.macOS])), .linkedLibrary("resolv")]),
        .target(name: "NocturneFiles", dependencies: ["NocturneKit"], path: "Sources/FileProvider"),
        .target(name: "NocturneVoice", dependencies: ["NocturneKit", .product(name: "WebRTC", package: "WebRTC")], path: "Sources/Voice"),
        .target(name: "PTYBridge", path: "Sources/PTYBridge", publicHeadersPath: "include"),
        .target(name: "DisplayBridge", path: "Sources/DisplayBridge", publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]),
        .target(name: "MicrophoneBridge", path: "Sources/MicrophoneBridge", publicHeadersPath: "include", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "NocturneHostKit", dependencies: ["NocturneKit", "PTYBridge", "DisplayBridge", "MicrophoneBridge"], path: "Sources/HostKit"),
        .testTarget(name: "NocturneKitTests", dependencies: ["NocturneKit", "NocturneHostKit", "NocturneFiles", "NocturneVoice"], path: "Tests", exclude: ["Client"])
    ]
)
