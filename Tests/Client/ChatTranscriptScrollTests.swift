import XCTest
import SwiftUI
@testable import Nocturne

@MainActor
final class ChatTranscriptScrollTests: XCTestCase {
    func testLatestPrependManualReturnAndConversationSwitchUseActualContentGeometry() async throws {
        func content(_ count: Int) -> AnyView {
            AnyView(VStack(spacing: 16) {
                ForEach(0..<count, id: \.self) { index in
                    Text("Message \(index). " + String(repeating: "A multiline reply with enough text to wrap. ", count: 8)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(24))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = ChatTranscriptScrollController(content: content(40))
        window.rootViewController = controller; window.makeKeyAndVisible(); defer { window.isHidden = true }
        func update(_ count: Int, first: String = "m0", conversation: String = "chat", jump: Int = 0) {
            controller.update(content: content(count), conversationID: conversation, firstMessageID: first, jump: jump, canLoadEarlier: false, loadEarlier: {}, followingChanged: { _ in })
        }
        func layout() async throws { try await Task.sleep(nanoseconds: 150_000_000); controller.view.layoutIfNeeded() }
        let scroll = controller.scrollView
        func bottom() -> CGFloat { max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom) }
        update(40); try await layout()
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height * 2)
        XCTAssertEqual(scroll.contentOffset.y, bottom(), accuracy: 1)
        controller.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = 200; controller.scrollViewDidScroll(scroll)
        controller.scrollViewDidEndDragging(scroll, willDecelerate: false)
        XCTAssertFalse(controller.following)
        let offset = scroll.contentOffset.y, height = scroll.contentSize.height
        update(50, first: "older"); try await layout()
        XCTAssertEqual(scroll.contentOffset.y, offset + scroll.contentSize.height - height, accuracy: 2, "Prepending history preserves the text under the reader's finger")
        update(50, first: "older", jump: 1); try await layout()
        XCTAssertTrue(controller.following); XCTAssertEqual(scroll.contentOffset.y, bottom(), accuracy: 1)
        update(55, first: "older", jump: 1); try await layout()
        XCTAssertEqual(scroll.contentOffset.y, bottom(), accuracy: 1, "New content follows after tapping latest")
        controller.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = 100; controller.scrollViewDidScroll(scroll)
        scroll.contentOffset.y = bottom(); controller.scrollViewDidScroll(scroll)
        controller.scrollViewDidEndDragging(scroll, willDecelerate: false)
        XCTAssertTrue(controller.following, "Manually returning to the bottom restores following")
        controller.scrollViewWillBeginDragging(scroll); scroll.contentOffset.y = 100; controller.scrollViewDidScroll(scroll)
        update(20, conversation: "another", jump: 1); try await layout()
        XCTAssertTrue(controller.following); XCTAssertEqual(scroll.contentOffset.y, bottom(), accuracy: 1)
    }
}
