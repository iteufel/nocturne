import XCTest
import Darwin
import NocturneKit
import NocturneHostKit

@MainActor
final class TerminalPersistenceTests: XCTestCase {
    private var root: URL!
    private var store: WorkspaceDeviceStore!
    private var server: WorkspaceServer!
    private var key: Data!
    private var port: UInt16 = 0
    private var clients: [WorkspaceConnection] = []
    private var connectedDevices: Set<String> = []

    private func start() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Nocturne-terminal-" + UUID().uuidString)
        store = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
        key = try SecureStore.randomKey(); port = UInt16.random(in: 52_000..<60_000)
        server = try WorkspaceServer(folder: root.appendingPathComponent("shared"), name: "Mac", devices: store, permissions: .init(terminal: true))
        let ready = expectation(description: "Listener ready"); var signalled = false
        server.onStatus = { status, _ in if status == "Ready", !signalled { signalled = true; ready.fulfill() } }
        server.onDevices = { [weak self] devices in self?.connectedDevices = Set(devices.map(\.id)) }
        try server.start(secret: key, port: port)
        await fulfillment(of: [ready], timeout: 5)
    }
    private func cleanUp() {
        clients.forEach { $0.disconnect() }; clients = []; server?.stop()
        if let root { try? FileManager.default.removeItem(at: root) }
    }
    private func connect(_ identity: TestDeviceIdentity, enroll: Bool = false) async throws -> WorkspaceConnection {
        let client = WorkspaceConnection(identity: identity.identity()); clients.append(client)
        try await reconnect(client, enroll: enroll); return client
    }
    private func reconnect(_ client: WorkspaceConnection, enroll: Bool = false) async throws {
        try await client.connect(PairingInvitation(host: "127.0.0.1", port: port, name: "Mac", secret: key,
            enrollmentToken: enroll ? store.createInvitation() : nil))
    }
    private func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail(message); throw NocturneError.timeout
    }
    private func text(_ client: WorkspaceConnection, _ id: String) -> String {
        String(decoding: client.terminals.first(where: { $0.id == id })?.history ?? Data(), as: UTF8.self)
    }
    private func pid(_ client: WorkspaceConnection, _ id: String) async throws -> pid_t {
        try await client.terminalInput(Data("printf '\nnocturne-pid:%s\n' \"$$\"\r".utf8), sessionID: id)
        func value() -> pid_t? {
            let output = text(client, id)
            guard let range = output.range(of: "nocturne-pid:[0-9]+", options: .regularExpression) else { return nil }
            return pid_t(output[range].dropFirst("nocturne-pid:".count))
        }
        try await waitUntil("Shell PID missing") { value() != nil }; return try XCTUnwrap(value())
    }

    func testTabsKeepShellStateAndOfflineOutputAcrossNewClientAndCloseIndividually() async throws {
        try await start(); defer { cleanUp() }
        let identity = try TestDeviceIdentity(), client = try await connect(identity, enroll: true)
        let first = try await client.openTerminal(), second = try await client.openTerminal()
        XCTAssertNotEqual(first, second)
        let firstPID = try await pid(client, first), secondPID = try await pid(client, second)
        XCTAssertNotEqual(firstPID, secondPID)
        try await client.terminalInput(Data("cd '\(root.path)'; export NOCTURNE_TAB=first; printf '%s%s\n' 'first-' 'ready'\r".utf8), sessionID: first)
        try await waitUntil("First tab not ready") { text(client, first).contains("first-ready") }
        let finished = root.appendingPathComponent("completed-offline")
        try await client.terminalInput(Data("sleep 0.4; printf '%s%s\n' 'finished-' 'offline'; touch '\(finished.path)'\r".utf8), sessionID: second)
        client.disconnect()
        try await waitUntil("Disconnect did not release the network connection") { connectedDevices.isEmpty }
        try await waitUntil("Command did not finish while the client was disconnected") { FileManager.default.fileExists(atPath: finished.path) }
        XCTAssertEqual(kill(firstPID, 0), 0); XCTAssertEqual(kill(secondPID, 0), 0)

        // A fresh client models app termination/relaunch, with no in-memory tab cache.
        let restored = try await connect(identity)
        XCTAssertEqual(restored.terminals.map(\.id), [first, second])
        XCTAssertEqual(restored.terminals.map { $0.info.name }, ["Terminal 1", "Terminal 2"])
        XCTAssertTrue(text(restored, second).contains("finished-offline"))
        XCTAssertFalse(text(restored, first).contains("finished-offline"))
        let restoredPID = try await pid(restored, first); XCTAssertEqual(restoredPID, firstPID)
        restored.selectTerminal(first)
        try await restored.terminalInput(Data("printf '\nrestored-var:%s\nrestored-dir:%s\n' \"$NOCTURNE_TAB\" \"$PWD\"\r".utf8))
        try await waitUntil("Shell variables or working directory were lost") {
            text(restored, first).contains("restored-var:first") && text(restored, first).contains("restored-dir:" + root.path)
        }
        let before = text(restored, second)
        try await restored.restoreTerminals(); try await restored.restoreTerminals()
        XCTAssertEqual(text(restored, second), before, "Reattaching must not replay duplicate bytes")
        try await restored.closeTerminal(first)
        XCTAssertEqual(restored.terminals.map(\.id), [second]); XCTAssertEqual(restored.terminalID, second)
        try await waitUntil("Closed tab's shell is still running") { kill(firstPID, 0) == -1 && errno == ESRCH }
        XCTAssertEqual(kill(secondPID, 0), 0)
        restored.disconnect(); server.stop()
        try await waitUntil("Stopping the server left a detached shell running") { kill(secondPID, 0) == -1 && errno == ESRCH }
    }

    func testOwnershipLimitsAndDetachedRevocation() async throws {
        try await start(); defer { cleanUp() }
        let owner = try TestDeviceIdentity(), other = try TestDeviceIdentity()
        let a = try await connect(owner, enroll: true), b = try await connect(other, enroll: true)
        let aID = try await a.openTerminal(), bID = try await b.openTerminal()
        let aPID = try await pid(a, aID), bPID = try await pid(b, bID)
        XCTAssertEqual(b.terminals.map(\.id), [bID])
        for operation: NocturneKit.Operation in [.terminalAttach, .terminalInput, .terminalResize, .terminalClose] {
            var packet = Packet(operation); packet.sessionID = aID; packet.data = Data("exit\r".utf8)
            do { _ = try await b.request(packet); XCTFail("Another identity accessed a terminal with \(operation)") }
            catch { XCTAssertTrue(error.localizedDescription.contains("no longer available")) }
        }
        for _ in 1..<WorkspaceProtocol.maximumTerminals { try await a.openTerminal() }
        a.disconnect()
        let a2 = try await connect(owner)
        XCTAssertEqual(a2.terminals.count, WorkspaceProtocol.maximumTerminals)
        do { try await a2.openTerminal(); XCTFail("Reconnecting bypassed the per-device limit") }
        catch { XCTAssertTrue(error.localizedDescription.contains("eight terminal tabs")) }
        a2.disconnect()
        try store.remove(owner.id); server.disconnectDevice(owner.id); try store.finishRemoval(owner.id)
        try await waitUntil("Removing a disconnected device left its PTY running") { kill(aPID, 0) == -1 && errno == ESRCH }
        XCTAssertEqual(kill(bPID, 0), 0); XCTAssertEqual(b.state, .connected)
        // Re-enrollment must not resurrect a removed device's old tabs.
        let renewed = try await connect(owner, enroll: true); XCTAssertTrue(renewed.terminals.isEmpty)
        b.disconnect(); server.updatePermissions(.init())
        try await waitUntil("Disabling Terminal left a detached shell running") { kill(bPID, 0) == -1 && errno == ESRCH }
        server.updatePermissions(.init(terminal: true)); try await reconnect(b)
        XCTAssertTrue(b.terminals.isEmpty)
    }

    func testFinishedShellAndBoundedScrollbackAreRestored() async throws {
        try await start(); defer { cleanUp() }
        let identity = try TestDeviceIdentity(), client = try await connect(identity, enroll: true)
        let id = try await client.openTerminal()
        _ = try await pid(client, id)
        let originalTab = try XCTUnwrap(client.terminals.first)
        var resets = 0
        let subscription = originalTab.output.sink { update in if case .reset = update { resets += 1 } }
        defer { subscription.cancel() }
        // Disable PTY echo so the command cannot be mistaken for output. Exceed the
        // replay buffer and exit while detached; the final bytes must survive exit.
        let finished = root.appendingPathComponent("finished")
        try await client.terminalInput(Data("stty -echo; sleep 0.3; /usr/bin/yes history | /usr/bin/head -c 700000; printf '\\n%s%s\\n' 'final-' 'output'; touch '\(finished.path)'; exit\r".utf8), sessionID: id)
        client.disconnect()
        try await waitUntil("Detached shell did not finish") { FileManager.default.fileExists(atPath: finished.path) }
        try await reconnect(client)
        let restored = client
        let tab = try XCTUnwrap(restored.terminals.first)
        try await waitUntil("Exited tab was not retained") { !tab.info.running }
        XCTAssertEqual(tab.id, id); XCTAssertLessThanOrEqual(tab.history.count, WorkspaceProtocol.terminalHistoryLimit)
        XCTAssertTrue(tab === originalTab); XCTAssertEqual(resets, 1, "An expired replay offset must reset the renderer exactly once")
        XCTAssertGreaterThan(tab.offset, Int64(WorkspaceProtocol.terminalHistoryLimit))
        XCTAssertTrue(text(restored, id).contains("final-output"))
        let previousOffset = tab.offset, previousHistory = tab.history
        try await restored.restoreTerminals()
        XCTAssertEqual(tab.offset, previousOffset); XCTAssertEqual(tab.history, previousHistory)
        try await restored.closeTerminal(id); XCTAssertTrue(restored.terminals.isEmpty)
    }
}
