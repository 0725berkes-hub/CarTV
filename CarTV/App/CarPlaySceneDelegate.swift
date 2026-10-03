import OSLog
import UIKit
import CarPlay
import SwiftUI

/// Delegate for `CPTemplateApplicationScene`. iOS calls exactly one of the two
/// `didConnect` variants: the one *with* a `CPWindow` when the car grants us a
/// drawable surface, otherwise the template-only variant. Both are handled.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    // MARK: Window variant (custom UI on the car screen)

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        Log.carplay.info("CarPlay connected WITH window \(window.bounds.debugDescription, privacy: .public)")
        MyTVService.warmRelay()
        Task { await MyTVService.refreshForCurrentNetwork(env: .shared) }
        AppEnvironment.shared.youtube.refreshTransientState()
        AppEnvironment.shared.carPlay.connect(
            interfaceController: interfaceController,
            window: window,
            scene: templateApplicationScene
        )
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        Log.carplay.info("CarPlay disconnected (window variant)")
        AppEnvironment.shared.carPlay.disconnect()
    }

    // MARK: Template-only variant

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        Log.carplay.info("CarPlay connected WITHOUT window (templates only)")
        AppEnvironment.shared.youtube.refreshTransientState()
        AppEnvironment.shared.carPlay.connect(
            interfaceController: interfaceController,
            window: nil,
            scene: templateApplicationScene
        )
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        Log.carplay.info("CarPlay disconnected (template variant)")
        AppEnvironment.shared.carPlay.disconnect()
    }

    // MARK: Style

    func sceneWillResignActive(_ scene: UIScene) {
        AppEnvironment.shared.browser.carSceneWillResignActive()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        AppEnvironment.shared.browser.carSceneDidBecomeActive()
    }

    func contentStyleDidChange(_ contentStyle: UIUserInterfaceStyle) {
        AppEnvironment.shared.carPlay.contentStyle = contentStyle
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for ctx in URLContexts {
            AppEnvironment.shared.library.enqueueExternalImport(ctx.url)
        }
    }
}

/// Delegate for `UIWindowSceneSessionRoleCarPlay` / external-display roles.
/// Some head units vend a plain window scene to video apps instead of (or in
/// addition to) the template scene. We treat it as another car surface.
final class CarWindowSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func sceneWillResignActive(_ scene: UIScene) {
        AppEnvironment.shared.browser.carSceneWillResignActive()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        AppEnvironment.shared.browser.carSceneDidBecomeActive()
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        Log.carplay.info("Car WINDOW scene connected role=\(session.role.rawValue, privacy: .public) size=\(windowScene.effectiveGeometry.coordinateSpace.bounds.debugDescription, privacy: .public)")

        let window = UIWindow(windowScene: windowScene)
        AppEnvironment.shared.carPlay.attachExternalWindow(window)
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        Log.carplay.info("Car WINDOW scene disconnected")
        AppEnvironment.shared.carPlay.detachExternalWindow()
        window = nil
    }
}
