import NocturneKit
import SwiftUI
import Combine

@MainActor
final class StreamWorkspaceState: ObservableObject {
    @Published var showControls = false { didSet { captureChanged?() } }
    @Published var showTools = false { didSet { captureChanged?() } }
    @Published var lockPointer = true { didSet { captureChanged?() } }
    var captureChanged: (() -> Void)?
}

/// UIKit consults the presented controller, not the video controller embedded
/// inside SwiftUI. Present this host directly so its lock preference is visible.
final class StreamHostingController: UIHostingController<StreamWorkspace> {
    let session: StreamSession
    let workspace: StreamWorkspaceState
    private let model: ClientModel
    private var observers = Set<AnyCancellable>()
    private weak var captureController: UIViewController?
    private var visible = false
    private var sceneActive = true
    private var closing = false
    var onDismiss: (() -> Void)?

    init(model: ClientModel, session: StreamSession) {
        self.model = model; self.session = session
        let workspace = StreamWorkspaceState(); self.workspace = workspace
        super.init(rootView: StreamWorkspace(model: model, session: session, workspace: workspace))
        modalPresentationStyle = .fullScreen
        isModalInPresentation = true
        workspace.captureChanged = { [weak self] in self?.updatePointerCapture() }
        session.objectWillChange.merge(with: model.$mouseConnected.map { _ in () })
            .receive(on: RunLoop.main).sink { [weak self] in self?.updatePointerCapture() }.store(in: &observers)
        NotificationCenter.default.publisher(for: .NocturneStreamControlsRequested)
            .sink { [weak self] note in
                guard let self, let window = note.object as? UIWindow, window === self.viewIfLoaded?.window else { return }
                self.openControls()
            }.store(in: &observers)
        for name in [UIScene.willDeactivateNotification, UIScene.didActivateNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] note in
                guard let self, let scene = note.object as? UIScene, scene === self.viewIfLoaded?.window?.windowScene else { return }
                self.sceneActive = name == UIScene.didActivateNotification
                self.updatePointerCapture()
            }.store(in: &observers)
        }
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersPointerLocked: Bool {
        visible && sceneActive && !closing && session.videoReady && session.controller != nil && model.mouseConnected
            && workspace.lockPointer && !workspace.showControls && !workspace.showTools
    }
    override var prefersStatusBarHidden: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        let command = UIKeyCommand(title: L("Release pointer and open stream controls"), action: #selector(openControls),
            input: "m", modifierFlags: [.command, .shift])
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }
    @objc func openControls() { workspace.showControls = true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); visible = true; updatePointerCapture()
    }
    override func viewWillDisappear(_ animated: Bool) {
        visible = false; updatePointerCapture(); super.viewWillDisappear(animated)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { onDismiss?() }
    }
    func releasePointerCapture() { closing = true; updatePointerCapture() }

    private func updatePointerCapture() {
        if captureController !== session.controller, let old = captureController {
            model.engine.setPointerCapture(false, controller: old)
        }
        captureController = session.controller
        if let controller = captureController { model.engine.setPointerCapture(prefersPointerLocked, controller: controller) }
        setNeedsUpdateOfPrefersPointerLocked()
    }
}

struct StreamPresentation: UIViewControllerRepresentable {
    @ObservedObject var model: ClientModel
    func makeUIViewController(context: Context) -> StreamPresentationController { StreamPresentationController(model: model) }
    func updateUIViewController(_ controller: StreamPresentationController, context: Context) { controller.update(session: model.session) }
    static func dismantleUIViewController(_ controller: StreamPresentationController, coordinator: ()) { controller.update(session: nil) }
}

final class StreamPresentationController: UIViewController {
    private let model: ClientModel
    private var targetSession: StreamSession?
    private(set) var stream: StreamHostingController?
    private var transitioning = false

    init(model: ClientModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); synchronize() }
    func update(session: StreamSession?) {
        targetSession = session
        DispatchQueue.main.async { [weak self] in self?.synchronize() }
    }
    private func synchronize() {
        guard !transitioning else { return }
        if let stream {
            guard stream.session !== targetSession else { return }
            transitioning = true
            stream.releasePointerCapture()
            stream.dismiss(animated: true) { [weak self] in
                guard let self else { return }
                self.stream = nil; self.transitioning = false; self.synchronize()
            }
        } else if let session = targetSession, viewIfLoaded?.window != nil {
            // SwiftUI may still be dismissing the app library. Wait for that
            // transition instead of presenting over another sheet or alert.
            var presenter: UIViewController = self
            while let parent = presenter.parent { presenter = parent }
            if let presented = presenter.presentedViewController {
                presented.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in self?.synchronize() }
                return
            }
            let host = StreamHostingController(model: model, session: session)
            host.onDismiss = { [weak self, weak session] in
                guard let self, let session, self.model.session === session else { return }
                self.model.endStream()
            }
            stream = host; transitioning = true
            presenter.present(host, animated: true) { [weak self] in
                self?.transitioning = false; self?.synchronize()
            }
        }
    }
}
