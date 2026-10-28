import SwiftUI
import UIKit

/// Own the scroll geometry in one place: no estimated lazy-row offsets or competing scrollTo calls.
struct ChatTranscriptScrollView<Content: View>: UIViewControllerRepresentable {
    let conversationID: String
    let firstMessageID: String?
    let jump: Int
    let canLoadEarlier: Bool
    let loadEarlier: () -> Void
    let followingChanged: (Bool) -> Void
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> ChatTranscriptScrollController<Content> {
        ChatTranscriptScrollController(content: content())
    }
    func updateUIViewController(_ controller: ChatTranscriptScrollController<Content>, context: Context) {
        controller.update(content: content(), conversationID: conversationID, firstMessageID: firstMessageID,
                          jump: jump, canLoadEarlier: canLoadEarlier, loadEarlier: loadEarlier, followingChanged: followingChanged)
    }
}

final class ChatTranscriptScrollController<Content: View>: UIViewController, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    private let host: UIHostingController<Content>
    private var observation: NSKeyValueObservation?
    private var conversationID: String?
    private var firstMessageID: String?
    private var jump = 0
    private(set) var following = true
    private var canLoadEarlier = false
    private var loadingEarlierRequested = false
    private var userScrolling = false
    private var adjusting = false
    private var prependOffset: CGFloat?
    private var prependHeight: CGFloat?
    private var loadEarlier: (() -> Void)?
    private var followingChanged: ((Bool) -> Void)?

    init(content: Content) { host = UIHostingController(rootView: content); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrollView.backgroundColor = .clear; scrollView.delegate = self
        scrollView.keyboardDismissMode = .interactive; scrollView.alwaysBounceVertical = true
        scrollView.accessibilityIdentifier = "chatTranscriptScroll"
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        addChild(host); scrollView.addSubview(host.view); host.didMove(toParent: self)
        host.view.backgroundColor = .clear; host.view.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = .intrinsicContentSize
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor), scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            host.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
        observation = scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in self?.contentSizeChanged() }
    }
    func update(content: Content, conversationID: String, firstMessageID: String?, jump: Int, canLoadEarlier: Bool,
                loadEarlier: @escaping () -> Void, followingChanged: @escaping (Bool) -> Void) {
        loadViewIfNeeded()
        self.loadEarlier = loadEarlier; self.followingChanged = followingChanged
        if self.conversationID != conversationID {
            self.conversationID = conversationID; following = true; userScrolling = false
            loadingEarlierRequested = false; prependOffset = nil; prependHeight = nil
        } else if let firstMessageID, let oldFirst = self.firstMessageID, oldFirst != firstMessageID, !following {
            prependOffset = scrollView.contentOffset.y; prependHeight = scrollView.contentSize.height
        }
        self.firstMessageID = firstMessageID
        self.canLoadEarlier = canLoadEarlier
        if !canLoadEarlier { loadingEarlierRequested = false }
        if self.jump != jump { self.jump = jump; jumpToLatest() }
        host.rootView = content
        host.view.invalidateIntrinsicContentSize(); view.setNeedsLayout()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        contentSizeChanged()
    }
    private var bottomOffset: CGFloat {
        max(-scrollView.adjustedContentInset.top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
    }
    private func contentSizeChanged() {
        guard !adjusting, scrollView.bounds.height > 0 else { return }
        adjusting = true
        if following { scrollView.contentOffset.y = bottomOffset }
        else if let offset = prependOffset, let height = prependHeight, scrollView.contentSize.height != height {
            scrollView.contentOffset.y = max(-scrollView.adjustedContentInset.top, min(bottomOffset, offset + scrollView.contentSize.height - height))
            prependOffset = nil; prependHeight = nil
        }
        adjusting = false
        publishFollowing()
    }
    func jumpToLatest() {
        following = true; userScrolling = false; prependOffset = nil; prependHeight = nil
        view.layoutIfNeeded()
        adjusting = true; scrollView.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: false); adjusting = false
        publishFollowing()
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userScrolling = true; following = false; prependOffset = nil; prependHeight = nil
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !adjusting, userScrolling else { return }
        following = bottomOffset - scrollView.contentOffset.y <= 36
        publishFollowing()
        if scrollView.contentOffset.y + scrollView.adjustedContentInset.top < 100, canLoadEarlier, !loadingEarlierRequested {
            loadingEarlierRequested = true
            loadEarlier?()
        }
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { userScrolling = false }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { userScrolling = false }
    private func publishFollowing() {
        let value = following
        // Avoid publishing SwiftUI state while UIKit lays out a representable update.
        DispatchQueue.main.async { [weak self] in self?.followingChanged?(value) }
    }
}
