import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let main = MainViewController()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Declared, not activated: the player activates it per video, so the HDMI route opens at full width.
        AudioOutput.declare()
        // Takes the remote before WebKit's content view, which is first responder.
        let window = AppWindow(frame: UIScreen.main.bounds)
        window.rootViewController = main
        window.remote = main
        window.backgroundColor = .black
        window.makeKeyAndVisible()
        self.window = window
        if let url = launchOptions?[.url] as? URL {
            launchURL = url
            main.receiveLink(url.absoluteString)
        }
        return true
    }

    /// The link the app was launched with, which UIKit then hands to `open` as well.
    private var launchURL: URL?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// `aiostreams://` links, such as an external player handing back where it stopped, or a Top Shelf title.
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        if url == launchURL {
            launchURL = nil
            return true
        }
        main.receiveLink(url.absoluteString)
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        main.appWillResignActive()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        launchURL = nil
        main.appDidBecomeActive()
    }

    /**
     * The page asks the server for Continue Watching and Next Up again 2 s
     * after it's hidden, once the pause sent on leaving has arrived, and
     * hands the answer on for the Top Shelf. A few seconds more awake let it.
     */
    func applicationDidEnterBackground(_ application: UIApplication) {
        endBackgroundTask()
        backgroundTask = application.beginBackgroundTask(withName: "top-shelf") { [weak self] in
            self?.endBackgroundTask()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.endBackgroundTask() }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
