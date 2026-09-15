import SwiftData
import OSLog
import UIKit
import CarPlay
import SwiftUI
import Combine

/// Single source of truth for "is a car connected, and what can it show?".
/// Hosts the SwiftUI car UI in a `CPWindow` (preferred) or a plain window scene,
/// and falls back to CarPlay templates when no drawable surface is granted.
@Observable
final class CarPlayCoordinator: NSObject {

    enum Surface: Equatable {
        case none
        case window          // CPWindow or UIWindowSceneSessionRoleCarPlay
        case templatesOnly   // CPInterfaceController without a window
    }

    private(set) var surface: Surface = .none
    private(set) var supportsVideoPlayback = true
    var contentStyle: UIUserInterfaceStyle = .dark {
        didSet { hostingController?.overrideUserInterfaceStyle = contentStyle == .light ? .light : .dark }
    }
    /// Size of the car display in points (for layout decisions in SwiftUI).
    private(set) var carScreenSize: CGSize = .zero

    var isConnected: Bool { surface != .none }

    private let playback: PlaybackController
    private var interfaceController: CPInterfaceController?
    private var sessionConfiguration: CPSessionConfiguration?
    private weak var carWindow: UIWindow?
    private weak var externalWindow: UIWindow?
    private var hostingController: UIHostingController<AnyView>?
    private var templateBuilder: CarTemplateFallback?

    init(playback: PlaybackController) {
        self.playback = playback
        super.init()
    }

    // MARK: Template scene

    func connect(interfaceController: CPInterfaceController, window: CPWindow?, scene: CPTemplateApplicationScene) {
        self.interfaceController = interfaceController
        contentStyle = scene.contentStyle

        let session = CPSessionConfiguration(delegate: self)
        sessionConfiguration = session
        if #available(iOS 26.4, *) {
            supportsVideoPlayback = session.supportsVideoPlayback
        }
        Log.carplay.info("supportsVideoPlayback=\(self.supportsVideoPlayback)")

        if let window {
            carWindow = window
            carScreenSize = window.bounds.size
            install(in: window)
            surface = .window
            // Keep a lightweight root template so the system has something to show behind our window.
            let placeholder = CPListTemplate(title: "CarTV", sections: [])
            interfaceController.setRootTemplate(placeholder, animated: false, completion: nil)
        } else if externalWindow != nil {
            // Window scene already arrived — templates are secondary.
            surface = .window
            let placeholder = CPListTemplate(title: "CarTV", sections: [])
            interfaceController.setRootTemplate(placeholder, animated: false, completion: nil)
        } else {
            surface = .templatesOnly
            let builder = CarTemplateFallback(interfaceController: interfaceController, playback: playback)
            templateBuilder = builder
            builder.installRoot()
        }
        playback.carIsConnected = true
    }

    func disconnect() {
        interfaceController = nil
        sessionConfiguration = nil
        templateBuilder = nil
        if externalWindow == nil {
            tearDownHosting()
            surface = .none
            playback.carIsConnected = false
        }
    }

    // MARK: Window scene

    func attachExternalWindow(_ window: UIWindow) {
        externalWindow = window
        carScreenSize = window.bounds.size
        install(in: window)
        surface = .window
        playback.carIsConnected = true
        // If templates were already the fallback, the window supersedes them.
        templateBuilder = nil
    }

    func detachExternalWindow() {
        externalWindow = nil
        if carWindow == nil {
            tearDownHosting()
            surface = interfaceController == nil ? .none : .templatesOnly
            if surface == .templatesOnly, let ic = interfaceController {
                let builder = CarTemplateFallback(interfaceController: ic, playback: playback)
                templateBuilder = builder
                builder.installRoot()
            }
            playback.carIsConnected = surface != .none
        }
    }

    // MARK: Hosting

    private func install(in window: UIWindow) {
        let env = AppEnvironment.shared
        let root = AnyView(
            CarRootView()
                .environment(env)
                .environment(env.playback)
                .environment(env.settings)
                .environment(self)
                .modelContainer(env.modelContainer)
        )
        let host = UIHostingController(rootView: root)
        host.overrideUserInterfaceStyle = contentStyle == .light ? .light : .dark
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.tintColor = UIColor(Theme.accent)
        hostingController = host
    }

    private func tearDownHosting() {
        hostingController = nil
        carWindow?.rootViewController = nil
        carWindow = nil
    }

    /// Bring the app to the car's foreground when the user starts playback on the phone.
    func showOnCarScreen() {
        // Nothing to do for a window surface (always visible while app is frontmost in CarPlay).
        templateBuilder?.presentNowPlaying()
    }
}

extension CarPlayCoordinator: CPSessionConfigurationDelegate {
    func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration, contentStyleChanged contentStyle: CPContentStyle) {
        self.contentStyle = contentStyle == .light ? .light : .dark
    }

    func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration, limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface) {
        Log.carplay.info("Limited UI changed: \(limitedUserInterfaces.rawValue)")
    }
}
