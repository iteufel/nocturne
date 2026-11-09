import SwiftUI
import UIKit.UIGestureRecognizerSubclass
import NocturneKit

/// UIKit preserves down/move/up and cancellation, which a completed SwiftUI tap
/// or drag cannot. Only the image content consumes input, never its letterbox.
struct SimulatorTouchSurface: UIViewRepresentable {
    let image: UIImage
    let enabled: Bool
    let send: (SimulatorTouch.Phase, Double, Double) -> Void
    func makeUIView(context: Context) -> SimulatorTouchImageView { SimulatorTouchImageView(frame: .zero) }
    func updateUIView(_ view: SimulatorTouchImageView, context: Context) {
        if view.image?.size != image.size || !enabled { view.cancelTouch() }
        view.image = image; view.send = send; view.isUserInteractionEnabled = enabled
    }
    static func dismantleUIView(_ view: SimulatorTouchImageView, coordinator: ()) { view.cancelTouch() }
}

final class SimulatorTouchImageView: UIImageView {
    var send: ((SimulatorTouch.Phase, Double, Double) -> Void)?
    private let touchGesture = SimulatorTouchGesture()
    override init(frame: CGRect) {
        super.init(frame: frame); contentMode = .scaleAspectFit; isUserInteractionEnabled = true
        isMultipleTouchEnabled = false; accessibilityTraits = [.image, .allowsDirectInteraction]
        touchGesture.normalized = { [weak self] in self?.normalized($0) }
        touchGesture.send = { [weak self] in self?.send?($0, $1, $2) }
        addGestureRecognizer(touchGesture)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func normalized(_ location: CGPoint) -> CGPoint? {
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
        let ratio = min(bounds.width / image.size.width, bounds.height / image.size.height)
        guard ratio.isFinite, ratio > 0 else { return nil }
        let width = image.size.width * ratio, height = image.size.height * ratio
        let x = (location.x - (bounds.width - width) / 2) / width
        let y = (location.y - (bounds.height - height) / 2) / height
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { normalized(point) != nil }
    func cancelTouch() { touchGesture.cancelTouch() }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { cancelTouch() } }
}

/// Begin immediately so the enclosing ScrollView cannot steal a simulator drag
/// after its pan threshold. Scrolling still works outside the display content.
private final class SimulatorTouchGesture: UIGestureRecognizer {
    var normalized: ((CGPoint) -> CGPoint?)?
    var send: ((SimulatorTouch.Phase, Double, Double) -> Void)?
    private var contact: UITouch?
    private var last = CGPoint.zero
    private var heartbeat: Timer?
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard contact == nil, let touch = touches.first, let point = normalized?(touch.location(in: view)) else { return }
        state = .began; contact = touch; last = point; send?(.down, point.x, point.y)
        // Keep a stationary long press alive; the host releases an abandoned
        // contact independently even while preview frames continue arriving.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.contact != nil else { return }
            self.send?(.move, self.last.x, self.last.y)
        }
        heartbeat = timer; RunLoop.main.add(timer, forMode: .common)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let contact, touches.contains(contact) else { return }
        guard let point = normalized?(contact.location(in: view)) else { cancelTouch(); return }
        state = .changed; last = point; send?(.move, point.x, point.y)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let contact, touches.contains(contact) else { return }
        if let point = normalized?(contact.location(in: view)) { last = point }
        send?(.up, last.x, last.y); clear(); state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelTouch() }
    func cancelTouch() {
        if contact != nil { send?(.cancel, last.x, last.y); state = .cancelled }
        clear()
    }
    private func clear() { contact = nil; heartbeat?.invalidate(); heartbeat = nil }
    override func reset() { clear(); super.reset() }
}
