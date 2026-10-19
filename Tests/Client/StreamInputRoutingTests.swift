import SwiftUI
import XCTest
@testable import Nocturne
import NocturneKit

@MainActor
final class StreamInputRoutingTests: XCTestCase {
    func testScreenFitUpdatesLiveSessionAndPersists() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: "streamPreferences")
        defer { defaults.set(saved, forKey: "streamPreferences") }
        let model = ClientModel()
        let session = StreamSession(host: StreamingHost(["id": "display-fixture"]),
            app: StreamingApp(["id": "1"]), preferences: .init())
        let video = UIViewController()
        session.controller = video
        model.session = session
        defer { model.session = nil }
        for fill in [true, false] {
            model.setFillEntireScreen(fill)
            XCTAssertEqual(session.preferences.fillEntireScreen, fill)
            XCTAssertTrue(session.controller === video)
            let stored = try XCTUnwrap(defaults.data(forKey: "streamPreferences"))
            XCTAssertEqual(try JSONDecoder().decode(StreamPreferences.self, from: stored).fillEntireScreen, fill)
        }
    }
    func testSafeAreaAndFullScreenFramesWithToolsAndRotation() {
        let cases: [(CGSize, EdgeInsets)] = [
            (CGSize(width: 402, height: 754), EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)),
            (CGSize(width: 750, height: 381), EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62)),
            (CGSize(width: 1024, height: 1322), EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)),
            (CGSize(width: 320, height: 600), EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0))
        ]
        for (size, insets) in cases {
            let safeBounds = CGRect(origin: .zero, size: size)
            for showTools in [false, true] {
                let safe = StreamWorkspaceLayout(size: size, insets: insets, fillEntireScreen: false, showTools: showTools)
                XCTAssertTrue(safeBounds.contains(safe.video))
                let full = StreamWorkspaceLayout(size: size, insets: insets, fillEntireScreen: true, showTools: showTools)
                XCTAssertEqual(full.video.minX, -insets.leading)
                XCTAssertEqual(full.video.minY, -insets.top)
                if showTools {
                    XCTAssertTrue(safeBounds.contains(safe.tools))
                    XCTAssertFalse(safe.video.intersects(safe.tools))
                    XCTAssertFalse(full.video.intersects(full.tools))
                } else {
                    XCTAssertEqual(safe.video, safeBounds)
                    XCTAssertEqual(full.video.maxX, size.width + insets.trailing)
                    XCTAssertEqual(full.video.maxY, size.height + insets.bottom)
                }
            }
        }
    }
    func testControlsGestureDetachesWhenStreamIsRemoved() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let view = StreamControlsGestureView(open: {})
        window.addSubview(view)
        XCTAssertEqual(window.gestureRecognizers?.filter { $0.name == "Nocturne stream controls" }.count, 1)
        view.removeFromSuperview()
        XCTAssertFalse(window.gestureRecognizers?.contains { $0.name == "Nocturne stream controls" } ?? false)
    }
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
        for fill in [false, true] { try checkVideoSurface(fillEntireScreen: fill) }
    }
    private func checkVideoSurface(fillEntireScreen: Bool) throws {
        let model = ClientModel()
        let session = StreamSession(host: StreamingHost(["id": "input-fixture", "name": "Test Mac"]),
            app: StreamingApp(["id": "1", "name": "Desktop"]), preferences: .init())
        session.preferences.fillEntireScreen = fillEntireScreen
        let video = UIViewController()
        video.view = UIView()
        session.controller = video
        let host = UIHostingController(rootView: StreamWorkspace(model: model, session: session))
        host.additionalSafeAreaInsets = UIEdgeInsets(top: 32, left: 24, bottom: 20, right: 24)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        XCTAssertEqual(window.gestureRecognizers?.filter { $0.name == "Nocturne stream controls" }.count, 1,
            "A rendered stream must install its hidden-controls gesture")
        let safeFrame = host.view.safeAreaLayoutGuide.layoutFrame
        let videoFrame = video.view.convert(video.view.bounds, to: host.view)
        XCTAssertEqual(videoFrame, fillEntireScreen ? host.view.bounds : safeFrame,
            "The embedded video must use the selected bounds, including the native safe-area insets")
        for point in [CGPoint(x: 512, y: 384), CGPoint(x: 200, y: 150), CGPoint(x: 900, y: 650)] {
            let target = try XCTUnwrap(window.hitTest(point, with: nil))
            XCTAssertTrue(target === video.view || target.isDescendant(of: video.view),
                "A tap at \(point) must reach the video surface, but hit \(type(of: target))")
        }
    }
}
