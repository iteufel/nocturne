import UIKit

/// Dedicated opt-in device fixture. It has no network, files, permissions or
/// external actions. Each actual UIKit touch phase changes a known color.
@main
final class SimulatorTouchFixture: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = TouchScene.self
        return configuration
    }
}
final class TouchScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        controller.view = TouchCanvas(); window.rootViewController = controller
        window.makeKeyAndVisible(); self.window = window
    }
}
final class TouchCanvas: UIView {
    private let label = UILabel()
    private var downs = 0, moves = 0, ups = 0
    private var lastTouch: CGPoint?
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .red
        label.textColor = .black; label.textAlignment = .center; label.numberOfLines = 0
        label.font = .systemFont(ofSize: 22, weight: .bold); label.accessibilityIdentifier = "simulatorTouchCounts"
        addSubview(label); update()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews(); label.frame = CGRect(x: 20, y: safeAreaInsets.top + 30, width: bounds.width - 40, height: 110) }
    private func update() { label.text = "Nocturne touch fixture\nDown: \(downs) · Move: \(moves) · Up: \(ups)" }
    override func draw(_ rect: CGRect) {
        guard let point = lastTouch else { return }
        UIColor.white.setFill(); UIRectFill(CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
    }
    private func mark(_ touches: Set<UITouch>) { lastTouch = touches.first?.location(in: self); setNeedsDisplay() }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { downs += 1; backgroundColor = .green; mark(touches); update() }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { moves += 1; backgroundColor = .blue; mark(touches); update() }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { ups += 1; backgroundColor = .yellow; update() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { ups += 1; backgroundColor = .yellow; update() }
}
