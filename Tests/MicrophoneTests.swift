import XCTest
import Network
import AVFoundation
import NocturneKit
@testable import NocturneHostKit

private final class RecordingMicrophone: MicrophoneOutput {
    private let lock = NSLock()
    private var starts = 0, stops = 0
    private var frames: [Data] = []
    var failWrite = false
    var onStop: (() -> Void)?
    var snapshot: (starts: Int, stops: Int, frames: [Data]) {
        lock.lock(); defer { lock.unlock() }; return (starts, stops, frames)
    }
    func start() { lock.lock(); starts += 1; lock.unlock() }
    func write(_ pcm: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrite { throw NocturneError.disconnected }
        frames.append(pcm)
    }
    func stop() { lock.lock(); stops += 1; lock.unlock(); onStop?() }
}

final class MicrophoneTests: XCTestCase {
    func testActualAudioConverterResamplesMonoAndStereoRoutes() throws {
        for rate in [8_000.0, 16_000.0, 44_100.0, 48_000.0] {
            for channels: AVAudioChannelCount in [1, 2] {
                let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
                let converter = try MicrophonePCMConverter(input: format)
                var frames: [Data] = []
                // Uneven tap sizes force both the converter and packetizer to retain state.
                let count: AVAudioFrameCount = 513
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
                buffer.frameLength = count
                for channel in 0..<Int(channels) {
                    for sample in 0..<Int(count) { buffer.floatChannelData![channel][sample] = 0.25 }
                }
                for _ in 0..<40 { try converter.convert(buffer) { frames.append($0) } }
                let expectedFrames = Int(Double(count * 40) / rate * Double(MicrophoneFormat.sampleRate)) / MicrophoneFormat.samplesPerFrame
                XCTAssertGreaterThanOrEqual(frames.count, expectedFrames - 1, "\(rate) Hz / \(channels) channels")
                XCTAssertLessThanOrEqual(frames.count, expectedFrames)
                XCTAssertTrue(frames.allSatisfy { $0.count == MicrophoneFormat.bytesPerFrame })
                let samples = try XCTUnwrap(frames.last).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
                XCTAssertTrue(samples.allSatisfy { abs(Int($0) - 8192) <= 8 }, "Mono PCM amplitude / channel mix changed: \(rate), \(channels)")
            }
        }
    }
    func testFramerPreservesSamplesAcrossUnevenHardwareBuffers() throws {
        let pcm = Data((0..<(MicrophoneFormat.bytesPerFrame * 3 + 17)).map { UInt8($0 % 251) })
        var framer = MicrophoneFramer(), frames: [Data] = []
        for offset in stride(from: 0, to: pcm.count, by: 333) {
            framer.append(pcm.subdata(in: offset..<min(offset + 333, pcm.count))) { frames.append($0) }
        }
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.reduce(Data(), +), pcm.prefix(MicrophoneFormat.bytesPerFrame * 3))
        var packet = Packet(.microphoneAudio); packet.data = frames[0]; packet.offset = 123; packet.sessionID = "lease"
        let frame = try FrameCodec.encode(packet)
        let decoded = try JSONDecoder().decode(Packet.self, from: frame.dropFirst(4))
        XCTAssertEqual(decoded.data, frames[0]); XCTAssertEqual(decoded.offset, 123); XCTAssertEqual(decoded.sessionID, "lease")
    }
    func testLeaseOwnershipValidationExpiryAndOutputFailure() throws {
        let output = RecordingMicrophone()
        var now: TimeInterval = 100
        let session = MicrophoneSession(output: output, now: { now })
        let a = UUID(), b = UUID()
        let lease = try session.handle(Packet(.microphoneStart), connection: a).sessionID
        XCTAssertThrowsError(try session.handle(Packet(.microphoneStart), connection: b))
        var frame = Packet(.microphoneAudio); frame.data = Data(repeating: 0x12, count: MicrophoneFormat.bytesPerFrame); frame.offset = 0; frame.sessionID = lease
        XCTAssertThrowsError(try session.handle(frame, connection: b))
        XCTAssertNoThrow(try session.handle(frame, connection: a))
        XCTAssertThrowsError(try session.handle(frame, connection: a)) // Replayed sequence.
        frame.offset = 3 // Bounded client backpressure may drop intermediate frames.
        XCTAssertNoThrow(try session.handle(frame, connection: a))
        frame.offset = 4; frame.data = Data([1])
        XCTAssertThrowsError(try session.handle(frame, connection: a))
        var stop = Packet(.microphoneStop); stop.sessionID = lease
        _ = try session.handle(stop, connection: b); session.disconnected(b)
        XCTAssertEqual(output.snapshot.stops, 0)
        now += MicrophoneFormat.timeout; session.expire()
        XCTAssertEqual(output.snapshot.stops, 1)
        let nextLease = try session.handle(Packet(.microphoneStart), connection: b).sessionID
        XCTAssertNotEqual(lease, nextLease)
        _ = try session.handle(stop, connection: b) // Old lease on the current connection.
        XCTAssertEqual(output.snapshot.stops, 1)
        frame.sessionID = nextLease; frame.data = Data(repeating: 0, count: MicrophoneFormat.bytesPerFrame)
        output.failWrite = true
        XCTAssertThrowsError(try session.handle(frame, connection: b))
        XCTAssertEqual(output.snapshot.stops, 2)
        session.stop(); XCTAssertEqual(output.snapshot.stops, 2)
        XCTAssertEqual(output.snapshot.frames.count, 2)
    }
}

@MainActor
final class MicrophoneIntegrationTests: XCTestCase {
    func testAuthenticatedAudioRevocationDisconnectAndIndependentConnections() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let devices = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
        let output = RecordingMicrophone()
        let server = try WorkspaceServer(folder: root.appendingPathComponent("shared"), name: "Mac", devices: devices,
            permissions: .init(terminal: true), microphoneOutput: output)
        defer { server.stop() }
        let secret = try SecureStore.randomKey(), port = UInt16.random(in: 52_000..<60_000)
        let listening = expectation(description: "Listening"); var ready = false
        server.onStatus = { status, _ in if status == "Ready", !ready { ready = true; listening.fulfill() } }
        try server.start(secret: secret, port: port); await fulfillment(of: [listening], timeout: 5)

        // Possession of the TLS key alone must not permit audio injection.
        let rejected = expectation(description: "Unauthenticated microphone rejected")
        let raw = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: SecureTransport.parameters(secret: secret)))
        raw.onReady = { raw.send(Packet(.microphoneStart)) }
        raw.onPacket = { packet in XCTAssertNotNil(packet.error); rejected.fulfill() }
        raw.start(); await fulfillment(of: [rejected], timeout: 5); raw.cancel()
        XCTAssertEqual(output.snapshot.starts, 0)

        let identity = try TestDeviceIdentity()
        let workspace = WorkspaceConnection(identity: identity.identity())
        let media = workspace.mediaConnection(), other = WorkspaceConnection(identity: try TestDeviceIdentity().identity())
        defer { workspace.disconnect(); media.disconnect(); other.disconnect() }
        let link = try PairingInvitation(host: "127.0.0.1", port: port, name: "Mac", secret: secret, enrollmentToken: devices.createInvitation())
        try await workspace.connect(link); try await workspace.openTerminal()
        XCTAssertFalse(workspace.capabilities.contains(MicrophoneFormat.capability))
        do { _ = try await workspace.request(Packet(.microphoneStart)); XCTFail("Disabled microphone started") } catch {}
        server.updatePermissions(.init(terminal: true, microphone: true))
        try await media.connect(link, restoreTerminalSessions: false)
        XCTAssertTrue(media.terminals.isEmpty)
        XCTAssertTrue(media.capabilities.contains(MicrophoneFormat.capability))
        let lease = try await media.request(Packet(.microphoneStart)).sessionID
        var frame = Packet(.microphoneAudio); frame.sessionID = lease; frame.offset = 0
        frame.data = Data((0..<MicrophoneFormat.bytesPerFrame).map { UInt8($0 % 251) })
        _ = try await media.request(frame)
        XCTAssertEqual(output.snapshot.frames, [frame.data!])
        do { _ = try await workspace.request(frame); XCTFail("A second socket injected into the lease") } catch {}
        let otherLink = try PairingInvitation(host: "127.0.0.1", port: port, name: "Mac", secret: secret, enrollmentToken: devices.createInvitation())
        try await other.connect(otherLink)
        do { _ = try await other.request(Packet(.microphoneStart)); XCTFail("A second device stole the microphone") } catch {}
        server.updatePermissions(.init(terminal: true))
        _ = try await other.request(Packet(.ping)) // Barrier after server queue applies revocation.
        XCTAssertEqual(output.snapshot.stops, 1)
        frame.offset = 1
        do { _ = try await media.request(frame); XCTFail("Audio survived revocation") } catch {}
        XCTAssertEqual(workspace.terminals.count, 1)
        try await workspace.terminalInput(Data("printf microphone-test\\n\r".utf8))
        server.updatePermissions(.init(terminal: true, microphone: true))
        _ = try await media.request(Packet(.microphoneStart))
        let stopped = expectation(description: "Disconnect flushes microphone")
        output.onStop = { stopped.fulfill() }
        media.disconnect(); await fulfillment(of: [stopped], timeout: 5)
        output.onStop = nil
        XCTAssertEqual(output.snapshot.stops, 2)
        XCTAssertEqual(workspace.state, .connected)
        _ = try await workspace.request(Packet(.microphoneStart))
        server.disconnectDevice(identity.id)
        XCTAssertEqual(output.snapshot.stops, 3)
        _ = try await other.request(Packet(.ping))
        _ = try await other.request(Packet(.microphoneStart))
        server.stop(); XCTAssertEqual(output.snapshot.stops, 4)
    }
}
