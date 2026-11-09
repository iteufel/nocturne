import XCTest
import UIKit
import UIKit.UIGestureRecognizerSubclass
import Network
import NocturneKit
@testable import Nocturne

@MainActor
final class SimulatorClientTests: XCTestCase {
    func testTouchBackpressureCoalescesMovesAndPreservesReleaseOverTLS() async throws {
        let peer = try SimulatorPeer(); try await peer.start()
        let client = connection(), model = SimulatorPreviewModel(connection: client)
        defer { model.stop(); client.disconnect(); peer.stop() }
        try await client.connect(peer.invitation()); await model.load()
        await model.start(try XCTUnwrap(model.devices.first))
        try await wait { model.touchEnabled }
        model.touch(.down, x: 0.2, y: 0.3)
        try await wait { peer.touches.count == 1 }
        for index in 0..<100 { model.touch(.move, x: Double(index) / 100, y: 0.4) }
        model.touch(.up, x: 0.99, y: 0.4)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(peer.touches.count, 1, "A slow host must not receive an unbounded touch queue")
        peer.releaseDown()
        try await wait { peer.touches.count == 3 }
        XCTAssertEqual(peer.touches.map(\.phase), [.down, .move, .up])
        XCTAssertEqual(peer.touches.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(Set(peer.touches.map(\.gestureID)).count, 1)
        XCTAssertEqual(Set(peer.touches.map(\.frameRevision)).count, 1)
        XCTAssertEqual(peer.touches[1].x, 0.99)
        model.stop(); try await wait { peer.closes == 1 }
    }

    func testStopDuringHeldDownDropsPendingInputAndLateReplies() async throws {
        let peer = try SimulatorPeer(); try await peer.start()
        let client = connection(), model = SimulatorPreviewModel(connection: client)
        defer { model.stop(); client.disconnect(); peer.stop() }
        try await client.connect(peer.invitation()); await model.load()
        await model.start(try XCTUnwrap(model.devices.first)); try await wait { model.touchEnabled }
        model.touch(.down, x: 0.2, y: 0.3); try await wait { peer.touches.count == 1 }
        model.touch(.move, x: 0.6, y: 0.7); model.stop()
        try await wait { peer.closes == 1 }; peer.releaseDown()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(peer.touches.count, 1)
        XCTAssertNil(model.image); XCTAssertNil(model.selected); XCTAssertFalse(model.touchEnabled)
    }

    func testOldPreviewHostNeverReceivesInput() async throws {
        let peer = try SimulatorPeer(input: false); try await peer.start()
        let client = connection(), model = SimulatorPreviewModel(connection: client)
        defer { model.stop(); client.disconnect(); peer.stop() }
        try await client.connect(peer.invitation()); await model.load()
        await model.start(try XCTUnwrap(model.devices.first)); try await wait { model.image != nil }
        model.touch(.down, x: 0.2, y: 0.3)
        XCTAssertFalse(model.touchEnabled); XCTAssertTrue(peer.touches.isEmpty)
    }

    func testTouchSurfaceRejectsLetterboxAndCancelsWhenRemoved() throws {
        let view = SimulatorTouchImageView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        view.image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 200)).image { _ in UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 100, height: 200)) }
        XCTAssertFalse(view.point(inside: CGPoint(x: 20, y: 200), with: nil))
        XCTAssertTrue(view.point(inside: CGPoint(x: 200, y: 200), with: nil))
        let gesture = try XCTUnwrap(view.gestureRecognizers?.first), touch = SimulatorTestTouch()
        let scroll = UIScrollView(); scroll.addSubview(view)
        XCTAssertFalse(gesture.canBePrevented(by: scroll.panGestureRecognizer))
        var phases: [SimulatorTouch.Phase] = [], coordinates: [CGPoint] = []
        view.send = { phases.append($0); coordinates.append(CGPoint(x: $1, y: $2)) }
        touch.point = CGPoint(x: 150, y: 100)
        gesture.touchesBegan([touch], with: UIEvent())
        touch.point = CGPoint(x: 250, y: 300)
        gesture.touchesMoved([touch], with: UIEvent())
        view.cancelTouch()
        XCTAssertEqual(phases, [.down, .move, .cancel])
        XCTAssertEqual(coordinates, [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.75), CGPoint(x: 0.75, y: 0.75)])
    }

    private func connection() -> WorkspaceConnection {
        let engine = NocturneStreamingService()
        return WorkspaceConnection(identity: WorkspaceIdentity(certificate: engine.workspaceCertificate(), name: "Simulator test") { engine.signWorkspaceChallenge($0) })
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw NocturneError.timeout
    }
}

private final class SimulatorTestTouch: UITouch {
    var point = CGPoint.zero
    override func location(in view: UIView?) -> CGPoint { point }
}

@MainActor
private final class SimulatorPeer {
    let device = RemoteSimulator(id: UUID().uuidString, name: "Fixture simulator", runtime: "iOS", state: "Booted")
    let session = UUID().uuidString
    let input: Bool
    var touches: [SimulatorTouch] = []
    var closes = 0
    private let key: Data, listener: NWListener, jpeg: Data
    private var channels: [UUID: SecureChannel] = [:]
    private var held: (SecureChannel, Packet)?
    init(input: Bool = true) throws {
        self.input = input; key = try SecureStore.randomKey()
        listener = try NWListener(using: SecureTransport.parameters(secret: key), on: .any)
        jpeg = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 200)).jpegData(withCompressionQuality: 0.7) { _ in
            UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 100, height: 200))
        }
    }
    func invitation() throws -> PairingInvitation { try .init(host: "127.0.0.1", port: XCTUnwrap(listener.port).rawValue, name: "Simulator Mac", secret: key) }
    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            var finished = false
            listener.stateUpdateHandler = { state in
                guard !finished else { return }
                if case .ready = state { finished = true; completion.resume() }
                if case .failed(let error) = state { finished = true; completion.resume(throwing: error) }
            }; listener.start(queue: .main)
        }
    }
    private func accept(_ connection: NWConnection) {
        let id = UUID(), channel = SecureChannel(connection: connection, queue: .main), nonce = Data(repeating: 87, count: 32)
        channels[id] = channel; var authenticated = false
        channel.onPacket = { [weak self, weak channel] packet in
            guard let self, let channel else { return }; var reply = packet.reply()
            do {
                guard authenticated || [.hello, .authenticate].contains(packet.operation) else { throw NocturneError.permissionDenied }
                switch packet.operation {
                case .hello: reply.version = WorkspaceProtocol.version; reply.data = nonce
                case .authenticate:
                    _ = try WorkspaceIdentity.verify(certificate: XCTUnwrap(packet.certificate), signature: XCTUnwrap(packet.signature), challenge: channel.boundChallenge(nonce))
                    authenticated = true; reply.capabilities = [SimulatorStreaming.capability] + (self.input ? [SimulatorStreaming.inputCapability] : [])
                case .simulatorList: reply.simulators = [self.device]
                case .simulatorOpen: reply.sessionID = self.session; reply.simulatorID = self.device.id
                case .simulatorFrame:
                    reply.sessionID = self.session; reply.simulatorID = self.device.id
                    reply.simulatorFrame = .init(pixelWidth: 100, pixelHeight: 200, jpeg: self.jpeg,
                        geometry: self.input ? .init(id: self.device.id, width: 100, height: 200, scale: 1, rotation: 0, target: 1) : nil)
                case .simulatorInput:
                    let touch = try XCTUnwrap(packet.simulatorTouch); self.touches.append(touch)
                    if touch.phase == .down { self.held = (channel, reply); return }
                case .simulatorClose: self.closes += 1
                case .ping: break
                default: throw NocturneError.invalidFrame
                }
            } catch { reply.error = error.localizedDescription }
            channel.send(reply)
        }
        channel.onClose = { [weak self] _ in self?.channels.removeValue(forKey: id) }; channel.start()
    }
    func releaseDown() { if let held { held.0.send(held.1) }; held = nil }
    func stop() { held = nil; listener.cancel(); Array(channels.values).forEach { $0.cancel() }; channels = [:] }
}
