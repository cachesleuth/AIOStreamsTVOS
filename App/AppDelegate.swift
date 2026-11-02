import UIKit

/**
 * The app's one-time setup. The window and the app's comings and goings are
 * the scene's (`SceneDelegate`): apps built with the tvOS 27 SDK must use the
 * scene lifecycle, and UIKit stops one that doesn't at launch.
 */
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Declared, not activated: the player activates it per video, so the HDMI route opens at full width.
        AudioOutput.declare()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

/// The app's one window: the page, the player beneath it, and the remote.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let main = MainViewController()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        // Takes the remote before WebKit's content view, which is first responder.
        let window = AppWindow(windowScene: scene)
        window.rootViewController = main
        window.remote = main
        window.backgroundColor = .black
        window.makeKeyAndVisible()
        self.window = window
        // A link the app was launched with, such as a Top Shelf title.
        for context in connectionOptions.urlContexts {
            main.receiveLink(context.url.absoluteString)
        }
    }

    /// `aiostreams://` links, such as an external player handing back where it stopped, or a Top Shelf title.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            main.receiveLink(context.url.absoluteString)
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        main.appWillResignActive()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        main.appDidBecomeActive()
    }

    /**
     * The page asks the server for Continue Watching and Next Up again 2 s
     * after it's hidden, once the pause sent on leaving has arrived, and
     * hands the answer on for the Top Shelf. A few seconds more awake let it.
     */
    func sceneDidEnterBackground(_ scene: UIScene) {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "top-shelf") { [weak self] in
            self?.endBackgroundTask()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.endBackgroundTask() }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
