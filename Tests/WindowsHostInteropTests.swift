import XCTest
import Foundation
import NocturneKit

@MainActor
final class WindowsHostInteropTests: XCTestCase {
    func testSwiftClientAuthenticatesWithWindowsProtocolAndReconnects() async throws {
        guard let host = ProcessInfo.processInfo.environment["NOCTURNE_WINDOWS_TEST_HOST"],
              let dotnet = ProcessInfo.processInfo.environment["NOCTURNE_DOTNET"] else {
            throw XCTSkip("Set NOCTURNE_WINDOWS_TEST_HOST and NOCTURNE_DOTNET to run the .NET interoperability fixture.")
        }
        let secret = try SecureStore.randomKey()
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: dotnet); process.arguments = [host]
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
        XCTAssertEqual(client.capabilities, [])
        _ = try await client.request(Packet(.ping))
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
