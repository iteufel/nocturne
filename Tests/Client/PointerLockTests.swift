import SwiftUI
import XCTest
@testable import Nocturne
import NocturneKit

@MainActor
final class PointerLockTests: XCTestCase {
    private func session() -> StreamSession {
        let session = StreamSession(host: StreamingHost(["id": "pointer-fixture"]),
            app: StreamingApp(["id": "1", "name": "Desktop"]), preferences: .init())
        session.controller = UIViewController(); session.videoReady = true
        return session
    }
    func testPresentedHostRequestsLockOnlyWhileVideoOwnsInput() async throws {
        let model = ClientModel(); model.mouseConnected = true
        let session = session()
        let host = StreamHostingController(model: model, session: session)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await waitUntil { host.prefersPointerLocked }
        XCTAssertTrue(host.prefersPointerLocked, "The outer hosting controller must expose the lock request to UIKit")
        host.workspace.showControls = true
        XCTAssertFalse(host.prefersPointerLocked)
        host.workspace.showControls = false
        XCTAssertTrue(host.prefersPointerLocked)
        host.workspace.showTools = true
        XCTAssertFalse(host.prefersPointerLocked)
        host.workspace.showTools = false
        host.workspace.lockPointer = false
        XCTAssertFalse(host.prefersPointerLocked)
        host.workspace.lockPointer = true
        model.mouseConnected = false
        XCTAssertFalse(host.prefersPointerLocked)
        model.mouseConnected = true
        session.videoReady = false
        XCTAssertFalse(host.prefersPointerLocked)
        session.videoReady = true
        XCTAssertTrue(host.prefersPointerLocked)
        host.releasePointerCapture()
        XCTAssertFalse(host.prefersPointerLocked)
    }
    func testReleaseShortcutIsScopedToTheStreamingWindow() throws {
        let model = ClientModel(); model.mouseConnected = true
        let host = StreamHostingController(model: model, session: session())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let command = try XCTUnwrap(host.keyCommands?.first)
        XCTAssertEqual(command.input, "m"); XCTAssertEqual(command.modifierFlags, [.command, .shift])
        NotificationCenter.default.post(name: .NocturneStreamControlsRequested, object: UIWindow())
        XCTAssertFalse(host.workspace.showControls)
        NotificationCenter.default.post(name: .NocturneStreamControlsRequested, object: window)
        XCTAssertTrue(host.workspace.showControls)
        XCTAssertFalse(host.prefersPointerLocked)
    }
    func testNativePresentationReusesHostAcrossResizeAndReplacesOnlyTheSession() async throws {
        let model = ClientModel(); model.mouseConnected = true
        let presenter = StreamPresentationController(model: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = presenter; window.makeKeyAndVisible()
        let animations = UIView.areAnimationsEnabled; UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animations); window.isHidden = true; window.rootViewController = nil }
        let first = session()
        presenter.update(session: first)
        try await waitUntil { presenter.presentedViewController is StreamHostingController }
        let host = try XCTUnwrap(presenter.stream)
        XCTAssertTrue(presenter.presentedViewController === host)
        XCTAssertEqual(host.modalPresentationStyle, .fullScreen)
        try await waitUntil { host.prefersPointerLocked }
        first.controller = UIViewController()
        presenter.update(session: first)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(presenter.stream === host, "Resizing must preserve the native host and its controls")
        let second = session()
        presenter.update(session: second)
        try await waitUntil { presenter.stream?.session === second && presenter.presentedViewController === presenter.stream }
        presenter.update(session: nil)
        try await waitUntil { presenter.stream == nil && presenter.presentedViewController == nil }
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Presentation did not settle")
    }
}
