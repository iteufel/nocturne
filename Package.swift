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
        .target(name: "PTYBridge", path: "Sources/PTYBridge", publicHeadersPath: "include"),
        .target(name: "NocturneHostKit", dependencies: ["NocturneKit", "PTYBridge"], path: "Sources/HostKit"),
        .testTarget(name: "NocturneKitTests", dependencies: ["NocturneKit", "NocturneHostKit"], path: "Tests", exclude: ["Client"])
    ]
)
