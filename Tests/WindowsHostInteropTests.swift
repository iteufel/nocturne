import XCTest
import Foundation
import NocturneKit
@testable import NocturneHostKit

@MainActor
final class WindowsHostInteropTests: XCTestCase {
    func testSwiftClientAuthenticatesWithWindowsProtocolAndReconnects() async throws {
        for media in [false, true] { try await verify(media: media) }
    }
    func testWindowsReceiverAuthenticatesToMacHostAndReceivesDesktopMedia() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["NOCTURNE_WINDOWS_TEST_HOST"],
              let dotnet = ProcessInfo.processInfo.environment["NOCTURNE_DOTNET"] else { throw XCTSkip("Set the .NET interoperability fixture environment.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let devices = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
        let desktop = InteropDesktop(), manager = DesktopSessionManager(host: desktop)
        let server = try WorkspaceServer(folder: root, name: "Mac fixture", devices: devices, desktop: manager)
        let ready = expectation(description: "Mac host ready")
        var started = false
        server.onStatus = { status, _ in Task { @MainActor in if status == "Ready", !started { started = true; ready.fulfill() } } }
        let secret = try SecureStore.randomKey(), port = UInt16.random(in: 50_000...60_000)
        try server.start(secret: secret, port: port); defer { server.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let invitation = try PairingInvitation(host: "127.0.0.1", port: port, name: "Mac", secret: secret, enrollmentToken: devices.createInvitation())
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: dotnet); process.arguments = [fixture, "--client"]
        process.standardInput = input; process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        try input.fileHandleForWriting.write(contentsOf: Data((invitation.url.absoluteString + "\n").utf8))
        try input.fileHandleForWriting.close()
        let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        await Task.detached { process.waitUntilExit() }.value
        XCTAssertEqual(process.terminationStatus, 0)
        struct Result: Decodable { let authenticated: Bool; let videoBytes: Int; let audioFrames: Int }
        let result = try JSONDecoder().decode(Result.self, from: data)
        XCTAssertTrue(result.authenticated); XCTAssertEqual(result.videoBytes, 6); XCTAssertEqual(result.audioFrames, 960)
        XCTAssertEqual(desktop.capture?.inputs.first?.text, "Windows to Mac")
        XCTAssertEqual(desktop.capture?.resizes.count, 1); XCTAssertEqual(desktop.capture?.stops, 1)
    }
    private func verify(media: Bool) async throws {
        guard let host = ProcessInfo.processInfo.environment["NOCTURNE_WINDOWS_TEST_HOST"],
              let dotnet = ProcessInfo.processInfo.environment["NOCTURNE_DOTNET"] else {
            throw XCTSkip("Set NOCTURNE_WINDOWS_TEST_HOST and NOCTURNE_DOTNET to run the .NET interoperability fixture.")
        }
        let secret = try SecureStore.randomKey()
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: dotnet); process.arguments = [host] + (media ? ["--media"] : [])
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        var completed = false
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
            if !completed, !diagnostics.isEmpty { print("Windows fixture: " + String(decoding: diagnostics, as: UTF8.self)) }
        }
        try input.fileHandleForWriting.write(contentsOf: Data((secret.base64EncodedString() + "\n").utf8))
        struct Ready: Decodable { let port: UInt16; let token: Data }
        let ready = try JSONDecoder().decode(Ready.self, from: output.fileHandleForReading.availableData)
        let invitation = try PairingInvitation(host: "127.0.0.1", port: ready.port, name: "Windows", secret: secret, enrollmentToken: ready.token)
        let identity = try TestDeviceIdentity()
        let client = WorkspaceConnection(identity: identity.identity())
        defer { client.disconnect() }
        do { try await client.connect(invitation) }
        catch { XCTFail("Windows connection failed: \(client.lastError ?? error.localizedDescription)"); throw error }
        XCTAssertEqual(client.name, "Windows interop host")
        XCTAssertEqual(Set(client.capabilities), media ? Set(["display", MicrophoneFormat.capability, AppStreaming.capability, DesktopStreaming.capability]) : [])
        _ = try await client.request(Packet(.ping))
        if media {
            let desktopList = try await client.request(Packet(.desktopList)); XCTAssertEqual(desktopList.displays?.first?.id, 7)
            var desktop = Packet(.desktopOpen); desktop.sessionID = UUID().uuidString; desktop.displayID = 7; desktop.viewport = .init(width: 800, height: 600, scale: 1)
            let openedDesktop = try await client.request(desktop); XCTAssertEqual(openedDesktop.display?.width, 800)
            var closeDesktop = Packet(.desktopClose); closeDesktop.sessionID = desktop.sessionID; _ = try await client.request(closeDesktop)
            let apps = try await client.request(Packet(.appList))
            XCTAssertEqual(apps.applications?.first?.id, "fixture-app")
            XCTAssertEqual(apps.windows?.first?.applicationID, "fixture-app")
            var open = Packet(.appOpen); open.sessionID = UUID().uuidString; open.applicationID = "fixture-app"; open.windowID = 1
            open.viewport = AppWindowViewport(width: 640, height: 480, scale: 2)
            let opened = try await client.request(open)
            XCTAssertEqual(opened.window?.title, "Fixture Window"); XCTAssertEqual(opened.display?.width, 1280)
            var resize = Packet(.appResize); resize.sessionID = open.sessionID; resize.viewport = .init(width: 800, height: 600, scale: 2)
            let resized = try await client.request(resize); XCTAssertEqual(resized.display?.width, 1600)
            var input = Packet(.appInput); input.sessionID = open.sessionID; input.input = AppWindowInput(.text); input.input?.text = "Hello from Swift"
            _ = try await client.request(input)
            var close = Packet(.appClose); close.sessionID = open.sessionID; _ = try await client.request(close)
            var display = Packet(.displayPrepare); display.sessionID = UUID().uuidString; display.display = .init(width: 1920, height: 1080, frameRate: 60)
            let prepared = try await client.request(display); XCTAssertEqual(prepared.display, display.display)
            var release = Packet(.displayRelease); release.sessionID = display.sessionID; _ = try await client.request(release)
            let microphone = try await client.request(Packet(.microphoneStart)); XCTAssertNotNil(microphone.sessionID)
            var audio = Packet(.microphoneAudio); audio.sessionID = microphone.sessionID; audio.offset = 0; audio.data = Data(repeating: 0, count: MicrophoneFormat.bytesPerFrame)
            _ = try await client.request(audio)
            var stop = Packet(.microphoneStop); stop.sessionID = microphone.sessionID; _ = try await client.request(stop)
        }
        client.disconnect()
        try await client.connect(PairingInvitation(host: "127.0.0.1", port: ready.port, name: "Windows", secret: secret))
        _ = try await client.request(Packet(.ping))
        let uninvited = WorkspaceConnection(identity: try TestDeviceIdentity().identity())
        defer { uninvited.disconnect() }
        do { try await uninvited.connect(invitation); XCTFail("Consumed Windows enrollment token authorized another device") } catch {}
        XCTAssertEqual(client.state, .connected)
        completed = true
    }
}

@MainActor private final class InteropDesktop: DesktopHosting {
    var capture: InteropCapture?
    func displays() -> [RemoteDesktopDisplay] { [.init(id: 7, name: "Main", width: 1920, height: 1080, isMain: true)] }
    func capture(displayID: UInt32?, viewport: AppWindowViewport, send: @escaping AppWindowSend, ended: @escaping (Error) -> Void) async throws -> DesktopCapture {
        let capture = InteropCapture(); self.capture = capture
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            let data = Data([0, 0, 0, 2, 0x65, 1])
            for offset in [0, 3] {
                var frame = Packet(.desktopVideo); frame.transferID = "fixture"; frame.offset = Int64(offset); frame.size = 6
                frame.video = .init(data: data.subdata(in: offset..<(offset + 3)), parameterSets: [Data([0x67]), Data([0x68])], timestamp: 1)
                send(frame) { _ in }
            }
            var audio = Packet(.desktopAudio); audio.audio = .init(data: Data(repeating: 0, count: 960 * 8), frames: 960); send(audio) { _ in }
        }
        return capture
    }
}
@MainActor private final class InteropCapture: DesktopCapture {
    var display = StreamDisplaySize(width: 640, height: 480, frameRate: 60)
    var displayID: UInt32 = 7
    var inputs: [AppWindowInput] = [], resizes: [AppWindowViewport] = []
    var stops = 0
    func resize(_ viewport: AppWindowViewport) { resizes.append(viewport) }
    func input(_ input: AppWindowInput) { inputs.append(input) }
    func stop() { stops += 1 }
}
