import OSLog
import UIKit
import AVFoundation
import CarPlay

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppEnvironment.shared.bootstrap()
        return true
    }

    // MARK: Scenes

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let role = connectingSceneSession.role
        Log.app.info("Scene requested for role \(role.rawValue, privacy: .public)")

        switch role {
        case .carTemplateApplication:
            let config = UISceneConfiguration(name: "CarPlay Configuration", sessionRole: role)
            config.sceneClass = CPTemplateApplicationScene.self
            config.delegateClass = CarPlaySceneDelegate.self
            return config

        case .windowApplication:
            let config = UISceneConfiguration(name: "Default Configuration", sessionRole: role)
            config.delegateClass = PhoneSceneDelegate.self
            return config

        default:
            // UIWindowSceneSessionRoleCarPlay / external display — the car hands us a real window.
            let config = UISceneConfiguration(name: "CarPlay Window", sessionRole: role)
            config.delegateClass = CarWindowSceneDelegate.self
            return config
        }
    }
}
