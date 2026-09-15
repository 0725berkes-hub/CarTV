import SwiftData
import UIKit
import SwiftUI

final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let env = AppEnvironment.shared

        let root = PhoneRootView()
            .environment(env)
            .environment(env.playback)
            .environment(env.settings)
            .modelContainer(env.modelContainer)

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: root)
        window.tintColor = UIColor(Theme.accent)
        window.makeKeyAndVisible()
        self.window = window

        handle(urlContexts: connectionOptions.urlContexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        handle(urlContexts: URLContexts)
    }

    /// Accept .m3u / .m3u8 files and http(s) links handed to us by the system.
    private func handle(urlContexts: Set<UIOpenURLContext>) {
        for ctx in urlContexts {
            AppEnvironment.shared.library.enqueueExternalImport(ctx.url)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        AppEnvironment.shared.playback.phoneIsForeground = true
    }

    func sceneWillResignActive(_ scene: UIScene) {
        AppEnvironment.shared.playback.phoneIsForeground = false
    }
}
