// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Nocturne",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NocturneKit", targets: ["NocturneKit"]),
        .library(name: "NocturneHostKit", targets: ["NocturneHostKit"]),
        .library(name: "NocturneMacClient", targets: ["NocturneMacClient"])
    ],
    targets: [
        .binaryTarget(name: "NocturneRemote", path: "Vendor/NocturneRemote.xcframework"),
        .target(name: "NocturneKit", dependencies: ["NocturneRemote"], path: "Sources/Shared",
            linkerSettings: [.linkedFramework("SystemConfiguration"), .linkedFramework("Security"),
                .linkedFramework("CoreWLAN", .when(platforms: [.macOS])), .linkedLibrary("resolv")]),
        .target(name: "NocturneFiles", dependencies: ["NocturneKit"], path: "Sources/FileProvider"),
        .target(name: "PTYBridge", path: "Sources/PTYBridge", publicHeadersPath: "include"),
        .target(name: "DisplayBridge", path: "Sources/DisplayBridge", publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]),
        .target(name: "MicrophoneBridge", path: "Sources/MicrophoneBridge", publicHeadersPath: "include", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "NocturneHostKit", dependencies: ["NocturneKit", "PTYBridge", "DisplayBridge", "MicrophoneBridge"], path: "Sources/HostKit"),
        .target(name: "NocturneMacClient", dependencies: ["NocturneKit"], path: "Sources/MacClient"),
        // Compile the app model for host lifecycle integration tests without launching the UI.
        .target(name: "NocturneServerModel", dependencies: ["NocturneKit", "NocturneHostKit"], path: "Sources/Server",
            exclude: ["NocturneServerApp.swift", "ServerView.swift", "ServerOnboardingView.swift", "MacComputersView.swift", "MacDesktopWorkspace.swift", "MacAppsWorkspace.swift"]),
        .testTarget(name: "NocturneKitTests", dependencies: ["NocturneKit", "NocturneHostKit", "NocturneFiles", "NocturneServerModel", "NocturneMacClient"], path: "Tests", exclude: ["Client"])
    ]
)
