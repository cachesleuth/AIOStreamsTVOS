import AVFoundation
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let main = MainViewController()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        setUpAudio()
        // Takes the remote before WebKit's content view, which is first responder.
        let window = AppWindow(frame: UIScreen.main.bounds)
        window.rootViewController = main
        window.remote = main
        window.backgroundColor = .black
        window.makeKeyAndVisible()
        self.window = window
        if let url = launchOptions?[.url] as? URL { main.receiveLink(url.absoluteString) }
        return true
    }

    /// `aiostreams://` links, such as an external player handing back where it stopped.
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        main.receiveLink(url.absoluteString)
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        main.appWillResignActive()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        main.appDidBecomeActive()
    }

    /// Movie playback, with as many channels as the TV's output takes.
    private func setUpAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            try session.setPreferredOutputNumberOfChannels(session.maximumOutputNumberOfChannels)
        } catch {
            NSLog("[app] audio session: %@", error.localizedDescription)
        }
    }
}
