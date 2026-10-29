import XCTest
import NocturneKit
@testable import Nocturne

@MainActor
final class BrowserWorkspaceTests: XCTestCase {
    func testFailedMacNavigationClearsImageAndNeverSubstitutesAClientLoad() async {
        var commands: [Packet] = []
        let model = BrowserWorkspaceModel(isConnected: { true }) { packet, _ in
            commands.append(packet)
            if packet.browserCommand?.action == .navigate { throw NocturneError.disconnected }
            var reply = packet.reply()
            reply.browserFrame = .init(page: "fixture", url: "", title: "Mac fixture", canGoBack: false, canGoForward: false, loading: false)
            return reply
        }
        await model.send(.init(.open))
        let address = "http://localhost:8123/private"
        await model.send(.init(.navigate, value: address))
        XCTAssertEqual(commands.map(\.operation), [.browserCommand, .browserCommand])
        XCTAssertEqual(commands.last?.browserCommand?.value, address, "Loopback must reach the Mac unchanged")
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.image); XCTAssertNil(model.frame)
        XCTAssertFalse(model.busy)
        await model.stop()
        XCTAssertEqual(commands.last?.browserCommand?.action, .close)
        XCTAssertEqual(Set(commands.compactMap(\.sessionID)).count, 1)
    }
    func testCancelledViewStillSendsCloseOutsideCancelledTask() async {
        let opened = expectation(description: "Browser explicitly opened")
        var commands: [Packet] = []
        let model = BrowserWorkspaceModel(isConnected: { true }) { packet, _ in
            commands.append(packet)
            if packet.browserCommand?.action == .open { opened.fulfill() }
            if packet.browserCommand?.action == .close { XCTAssertFalse(Task.isCancelled, "Cleanup must survive SwiftUI task cancellation") }
            var reply = packet.reply()
            reply.browserFrame = .init(page: "fixture", url: "", title: "Fixture", canGoBack: false, canGoForward: false, loading: false)
            return reply
        }
        let task = Task { await model.run() }
        await fulfillment(of: [opened], timeout: 2)
        task.cancel(); await task.value
        XCTAssertEqual(commands.last?.browserCommand?.action, .close)
        XCTAssertEqual(Set(commands.compactMap(\.sessionID)).count, 1)
    }
}
