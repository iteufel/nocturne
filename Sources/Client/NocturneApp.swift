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
    private(set) var appStream: AppWindowStreamModel?
    func sceneDidBecomeActive(_ scene: UIScene) {
        if let appStream { appStream.activate() }
        else { AppWindowScenes.libraryActive(scene.session.persistentIdentifier) }
    }
    func sceneDidEnterBackground(_ scene: UIScene) {
        if let appStream { appStream.deactivate() }
        else { AppWindowScenes.libraryInactive(scene.session.persistentIdentifier) }
    }
    func sceneDidDisconnect(_ scene: UIScene) {
        appStream?.deactivate()
        appStream = nil; window = nil
        AppWindowScenes.libraryInactive(scene.session.persistentIdentifier)
    }
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let activity = connectionOptions.userActivities.first(where: { AppWindowScenes.route($0) != nil }) ?? session.stateRestorationActivity
        if let activity, let route = AppWindowScenes.route(activity) {
            let stream = ClientModel.shared.makeAppWindowStream(route); appStream = stream
            scene.title = route.title; scene.userActivity = activity
            scene.activationConditions.canActivateForTargetContentIdentifierPredicate = NSPredicate(format: "self == %@", route.contentIdentifier)
            scene.activationConditions.prefersToActivateForTargetContentIdentifierPredicate = NSPredicate(format: "self == %@", route.contentIdentifier)
            scene.sizeRestrictions?.minimumSize = CGSize(width: 320, height: 280)
            window.rootViewController = UIHostingController(rootView: AppWindowWorkspace(stream: stream) {
                AppWindowScenes.close(session)
            })
        } else {
            scene.activationConditions.canActivateForTargetContentIdentifierPredicate = NSPredicate(value: false)
            window.rootViewController = UIHostingController(rootView: ClientRootView(model: ClientModel.shared))
            if (UIApplication.shared.delegate as? DarkAppDelegate)?.window == nil {
                (UIApplication.shared.delegate as? DarkAppDelegate)?.window = window
            }
        }
        self.window = window
        window.makeKeyAndVisible()
    }
    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? { scene.userActivity }
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard AppWindowScenes.route(userActivity) == appStream?.route else { return }
        scene.userActivity = userActivity; appStream?.activate()
    }
}

@MainActor
enum AppWindowScenes {
    static let activityType = "app.nocturne.app-window"
    private static var activeLibraries = Set<String>()
    static func activity(_ route: AppWindowRoute) -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType)
        activity.title = route.title; activity.targetContentIdentifier = route.contentIdentifier
        if let data = try? JSONEncoder().encode(route) { activity.userInfo = ["route": data] }
        return activity
    }
    static func route(_ activity: NSUserActivity) -> AppWindowRoute? {
        guard activity.activityType == activityType, let data = activity.userInfo?["route"] as? Data else { return nil }
        return try? JSONDecoder().decode(AppWindowRoute.self, from: data)
    }
    static func open(_ route: AppWindowRoute, failed: @escaping (Error) -> Void) {
        let existing = UIApplication.shared.openSessions.first { session in
            let activity = session.scene?.userActivity ?? session.stateRestorationActivity
            return activity.flatMap(Self.route)?.contentIdentifier == route.contentIdentifier
        }
        UIApplication.shared.requestSceneSessionActivation(existing, userActivity: activity(route), options: nil, errorHandler: failed)
    }
    static func disconnectAll() {
        for scene in UIApplication.shared.connectedScenes { (scene.delegate as? DarkSceneDelegate)?.appStream?.deactivate() }
    }
    static func close(_ session: UISceneSession, failed: ((Error) -> Void)? = nil) {
        (session.scene?.delegate as? DarkSceneDelegate)?.appStream?.deactivate()
        let options = UIWindowSceneDestructionRequestOptions(); options.windowDismissalAnimation = .standard
        UIApplication.shared.requestSceneSessionDestruction(session, options: options, errorHandler: failed)
    }
    static func libraryActive(_ id: String) { activeLibraries.insert(id); ClientModel.shared.start() }
    static func libraryInactive(_ id: String) {
        guard activeLibraries.remove(id) != nil, activeLibraries.isEmpty else { return }
        ClientModel.shared.suspend()
    }
}
