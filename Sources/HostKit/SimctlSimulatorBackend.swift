import Foundation
import ImageIO
import UniformTypeIdentifiers
import NocturneKit

/// Uses Apple's shipped CLI for the framebuffer, never ScreenCaptureKit/window capture.
/// Only lists devices and screenshots an explicitly selected, already booted UDID.
/// No boot/shutdown/install/erase/spawn, private frameworks, or permission prompts.
public struct SimctlSimulatorBackend: SimulatorBackend {
    private let run: DeveloperCommand.Run
    public init() { run = DeveloperCommand.run }
    init(run: @escaping DeveloperCommand.Run) { self.run = run }
    public func devices() async throws -> [RemoteSimulator] {
        let result = try await run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"], FileManager.default.temporaryDirectory, nil)
        guard result.code == 0, !result.truncated else { throw Self.unavailable }
        return try Self.decodeDevices(result.data)
    }
    static func decodeDevices(_ data: Data) throws -> [RemoteSimulator] {
        struct Device: Decodable { let udid: String; let name: String; let state: String; let isAvailable: Bool? }
        struct List: Decodable { let devices: [String: [Device]] }
        guard data.count <= 4_194_304 else { throw NocturneError.invalidFrame }
        let list = try JSONDecoder().decode(List.self, from: data)
        let devices = list.devices.filter { $0.key.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-") }
            .flatMap { runtime, devices in devices.filter { $0.isAvailable == true && UUID(uuidString: $0.udid) != nil }.map {
                RemoteSimulator(id: $0.udid, name: $0.name, runtime: runtime, state: $0.state)
            } }.sorted { ($0.runtime, $0.name, $0.id) < ($1.runtime, $1.name, $1.id) }
        guard devices.count <= SimulatorStreaming.maximumDevices else { throw NocturneError.invalidFrame }
        return devices
    }
    public func frame(device: String) async throws -> SimulatorFrame {
        guard UUID(uuidString: device) != nil else { throw NocturneError.invalidFrame }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nocturne-simulator-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("frame.png")
        let result = try await run("/usr/bin/xcrun", ["simctl", "io", device, "screenshot", "--type=png", file.path], directory, nil)
        try Task.checkCancellation()
        guard result.code == 0, !result.truncated else { throw Self.unavailable }
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize, (1...33_554_432).contains(count) else { throw NocturneError.invalidFrame }
        return try Self.encodeFrame(Data(contentsOf: file, options: .mappedIfSafe))
    }
    static func encodeFrame(_ data: Data) throws -> SimulatorFrame {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              (1...8192).contains(width), (1...8192).contains(height), width * height <= 33_554_432,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1280,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw NocturneError.invalidFrame }
        for quality in [0.7, 0.4, 0.2] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw NocturneError.invalidFrame }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw NocturneError.invalidFrame }
            let frame = SimulatorFrame(pixelWidth: width, pixelHeight: height, jpeg: output as Data)
            if frame.isValid { return frame }
        }
        throw NocturneError.remote("Simulator frame exceeds the preview size limit.")
    }
    private static var unavailable: NocturneError {
        .remote("Simulator unavailable. Select Xcode's developer tools and start an iOS simulator on your Mac. This host may restrict access to CoreSimulator.")
    }
}
