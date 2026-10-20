import XCTest
import Foundation
import NocturneKit

@MainActor
final class WindowsHostInteropTests: XCTestCase {
    func testSwiftClientAuthenticatesWithWindowsProtocolAndReconnects() async throws {
        for media in [false, true] { try await verify(media: media) }
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
        XCTAssertEqual(Set(client.capabilities), media ? Set(["display", MicrophoneFormat.capability, AppStreaming.capability]) : [])
        _ = try await client.request(Packet(.ping))
        if media {
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
