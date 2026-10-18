import SwiftUI
import XCTest
@testable import Nocturne
import NocturneKit

@MainActor
final class StreamInputRoutingTests: XCTestCase {
    func testInputModeUpdatesLiveSessionAndPersistsWithoutReplacingController() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: "streamPreferences")
        defer { defaults.set(saved, forKey: "streamPreferences") }
        let model = ClientModel()
        let session = StreamSession(host: StreamingHost(["id": "input-fixture"]),
            app: StreamingApp(["id": "1"]), preferences: .init())
        let video = UIViewController()
        session.controller = video
        model.session = session
        defer { model.session = nil }
        for mode in [StreamInputMode.touch, .trackpad] {
            model.setInputMode(mode)
            XCTAssertEqual(session.preferences.inputMode, mode)
            XCTAssertTrue(model.session === session)
            XCTAssertTrue(session.controller === video)
            let stored = try XCTUnwrap(defaults.data(forKey: "streamPreferences"))
            XCTAssertEqual(try JSONDecoder().decode(StreamPreferences.self, from: stored).inputMode, mode)
        }
    }
    func testStreamWorkspaceDeliversTapsToVideoSurface() throws {
        let model = ClientModel()
        let session = StreamSession(host: StreamingHost(["id": "input-fixture", "name": "Test Mac"]),
            app: StreamingApp(["id": "1", "name": "Desktop"]), preferences: .init())
        let video = UIViewController()
        video.view = UIView()
        session.controller = video
        let host = UIHostingController(rootView: StreamWorkspace(model: model, session: session))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        for point in [CGPoint(x: 512, y: 384), CGPoint(x: 200, y: 150), CGPoint(x: 900, y: 650)] {
            let target = try XCTUnwrap(window.hitTest(point, with: nil))
            XCTAssertTrue(target === video.view || target.isDescendant(of: video.view),
                "A tap at \(point) must reach the video surface, but hit \(type(of: target))")
        }
    }
}
