import SwiftUI
import NocturneKit

@main
final class DarkAppDelegate: AppDelegate {
    override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    override func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Nocturne", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = DarkSceneDelegate.self
        return configuration
    }
}

final class DarkSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func sceneDidBecomeActive(_ scene: UIScene) { ClientModel.shared.start() }
    func sceneDidEnterBackground(_ scene: UIScene) { ClientModel.shared.suspend() }
    func sceneDidDisconnect(_ scene: UIScene) { ClientModel.shared.suspend() }
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ClientRootView(model: ClientModel.shared))
        self.window = window
        (UIApplication.shared.delegate as? DarkAppDelegate)?.window = window
        window.makeKeyAndVisible()
    }
}
