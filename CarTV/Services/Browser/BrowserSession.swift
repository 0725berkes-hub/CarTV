import Foundation
import Observation
import OSLog
import UIKit
import WebKit

/// Separate navigation stacks for the two displays, sharing persistent website cookies.
@MainActor
@Observable
final class BrowserStore {
    static let dataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "E8AE90BA-5DC6-4939-9905-D9B5C551A1F7")!)
    let phoneTabs = BrowserTabs()
    let carTabs = BrowserTabs(usesCarKeyboard: true)
    var phone: BrowserSession { phoneTabs.selected }
    var car: BrowserSession { carTabs.selected }
    private let phoneYouTube = BrowserSession()
    private let phoneTikTok = BrowserSession()
    private let carYouTube = BrowserSession(usesCarKeyboard: true)
    private let carTikTok = BrowserSession(usesCarKeyboard: true)
    private var allSessions: [BrowserSession] { phoneTabs.sessions + carTabs.sessions + [phoneYouTube, phoneTikTok, carYouTube, carTikTok] }
    @ObservationIgnored private weak var activeSession: BrowserSession?
    @ObservationIgnored private var playerReturn: PlayerReturn?
    var phoneDestination: BrowserDestination?
    var carDestination: BrowserDestination?

    private struct PlayerReturn {
        let session: BrowserSession
        let pageURL: URL
        let ref: PlayableRef
        let position: Double
        let isCar: Bool
        let backgroundAudio: Bool
    }

    var isPresentingBrowserVideo: Bool { playerReturn != nil }
    var isPresentingPhoneBrowserVideo: Bool { playerReturn?.isCar == false }
    var isContinuingCarBrowserAudio: Bool { playerReturn?.backgroundAudio == true }

    func playVideo(_ item: PlayableItem, from session: BrowserSession, position: Double, isCar: Bool, backgroundAudio: Bool = false) {
        guard playerReturn == nil else { return }
        let playback = AppEnvironment.shared.playback
        playerReturn = PlayerReturn(session: session, pageURL: session.url, ref: item.ref, position: position, isCar: isCar, backgroundAudio: backgroundAudio)
        session.suspend()
        playback.play(item, queue: [item], origin: isCar ? .car : .phone, resume: false,
                      presentPlayer: !backgroundAudio, startPosition: position, continueInBackground: backgroundAudio)
        if isCar, !backgroundAudio { playback.requestCarPlayer() }
    }

    func carSceneWillResignActive() {
        activeSession?.continueYouTubeAudioOnCar()
    }

    func carSceneDidBecomeActive() {
        activeSession?.cancelBackgroundCapture()
        guard let saved = playerReturn, saved.backgroundAudio, saved.session.isDisplayed else { return }
        returnFromPlayer()
    }

    func restoreCarBrowserAudio(for session: BrowserSession) {
        guard let saved = playerReturn, saved.backgroundAudio, saved.session === session else { return }
        returnFromPlayer()
    }

    func ownsPlayback(_ session: BrowserSession) -> Bool { activeSession === session }

    /// Closing browser fullscreen returns to the same mounted website, not a native watch page.
    @discardableResult
    func returnFromPlayer() -> Bool {
        guard let saved = playerReturn else { return false }
        playerReturn = nil // Clear before stop triggers either display's dismissal callback.
        let playback = AppEnvironment.shared.playback
        guard let current = playback.current else {
            if saved.session.url == saved.pageURL {
                saved.session.restoreInlineVideo(position: saved.position, resume: false)
            }
            return true
        }
        let nextYouTubeVideo = current.ref != saved.ref && current.ref.kind == .youtube && saved.ref.kind == .youtube
            ? YouTubeService.videoID(from: current.ref.id) : nil
        guard current.ref == saved.ref || nextYouTubeVideo != nil else { return false }
        let state = playback.snapshot.state
        let waitingForFirstFrame: Bool
        switch state {
        case .loading: waitingForFirstFrame = true
        case .failed: waitingForFirstFrame = playback.snapshot.position == 0
        default: waitingForFirstFrame = false
        }
        let position = waitingForFirstFrame && nextYouTubeVideo == nil ? saved.position : playback.snapshot.position
        let resume = state == .playing || state == .buffering || state == .loading && saved.backgroundAudio
        playback.stop(deactivateAudio: false)
        if saved.session.url == saved.pageURL {
            if let nextYouTubeVideo, let target = URL(string: "https://www.youtube.com/watch?v=\(nextYouTubeVideo)") {
                saved.session.restoreInlineVideo(position: position, resume: resume, target: target)
            } else {
                saved.session.restoreInlineVideo(position: position, resume: resume)
            }
        }
        return true
    }

    func open(_ destination: BrowserDestination, isCar: Bool) {
        let session = session(for: destination, isCar: isCar)
        session.destination = destination
        if session.webView.url == nil && !session.isLoading { session.load(destination.homeURL) }
        if isCar { carDestination = destination } else { phoneDestination = destination }
    }

    func activate(_ session: BrowserSession) {
        guard !isPresentingBrowserVideo else { return }
        // Transfer ownership only when the display actually changes.
        if activeSession !== session {
            for other in allSessions where other !== session {
                other.suspend()
            }
        }
        activeSession = session
        session.start()
    }

    func resumeIfActive(_ session: BrowserSession) {
        if !isPresentingBrowserVideo, activeSession === session { session.start() }
    }

    func handleAudioSession(_ event: AudioSessionController.Event) {
        for session in allSessions { session.handleAudioSession(event) }
    }

    func clear() {
        if isPresentingBrowserVideo { playerReturn = nil; AppEnvironment.shared.playback.stop() }
        activeSession = nil
        phoneDestination = nil; carDestination = nil
        phoneTabs.reset()
        carTabs.reset()
        [phoneYouTube, phoneTikTok, carYouTube, carTikTok].forEach { $0.reset() }
        Self.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    func session(for destination: BrowserDestination, isCar: Bool) -> BrowserSession {
        switch destination {
        case .browse: isCar ? car : phone
        case .youtube: isCar ? carYouTube : phoneYouTube
        case .tiktok: isCar ? carTikTok : phoneTikTok
        }
    }
}

@MainActor
@Observable
final class BrowserSession: NSObject, WKNavigationDelegate, WKUIDelegate, Identifiable {
    let id = UUID()
    static let homeURL = URL(string: "https://www.youtube.com")!
    private(set) var url: URL = BrowserSession.homeURL
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress = 0.0
    private(set) var generation = 0
    var errorMessage: String?
    var destination: BrowserDestination = .youtube
    private(set) var keyboardRequest: BrowserKeyboardRequest?
    private(set) var submissionID = 0
    private(set) var isPageFullscreen = false
    private(set) var isPictureInPicture = false
    private(set) var blocksAds = true
    private(set) var pageTitle = ""
    private(set) var wantsHiddenControls = false

    @ObservationIgnored private let usesCarKeyboard: Bool
    @ObservationIgnored private let pagePreferences = WKPreferences()
    @ObservationIgnored private var keyboardFrame: WKFrameInfo?

    @ObservationIgnored private var storedWebView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    @ObservationIgnored private var reportedMediaFullscreen = false
    @ObservationIgnored private var backgroundCaptureID: UUID?
    @ObservationIgnored private var pendingPlayerReturn: (position: Double, resume: Bool)?
    @ObservationIgnored private var rulesInstalled = false
    @ObservationIgnored private var displayed = false
    @ObservationIgnored private var mediaSuspended = false
    @ObservationIgnored private var isPlaying = false
    @ObservationIgnored private var resumeOnReturn = false
    @ObservationIgnored private var resumeAfterReload = false
    @ObservationIgnored private var processRecoveryAttempted = false
    @ObservationIgnored private var searchText = ""
    @ObservationIgnored private var recoveryURL: URL?
    @ObservationIgnored private var recoveryPosition = 0.0
    @ObservationIgnored private var needsInitialAddressFocus = false

    init(usesCarKeyboard: Bool = false) {
        self.usesCarKeyboard = usesCarKeyboard
        super.init()
    }

    var webView: WKWebView {
        if let storedWebView { return storedWebView }
        let configuration = WKWebViewConfiguration()
        configurePagePreferences(for: url)
        configuration.preferences = pagePreferences
        configuration.websiteDataStore = BrowserStore.dataStore
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(WKUserScript(
            source: "window.__carTVBlockAds = \(blocksAds ? "true" : "false"); window.__carTVUsesCarKeyboard = \(usesCarKeyboard ? "true" : "false");",
            injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
        configuration.userContentController.add(BrowserPageBridge(session: self), name: "carTVPage")
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserPageBridge.searchScript, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserPageBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
        if usesCarKeyboard {
            configuration.userContentController.add(CarBrowserKeyboardBridge(session: self), name: "carTVKeyboard")
            configuration.userContentController.addUserScript(WKUserScript(
                source: CarBrowserKeyboardBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: false
            ))
        }
        let web = BrowserWebView(frame: .zero, configuration: configuration)
        web.hidesCarScrollIndicators = usesCarKeyboard
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        // Web pages need ordinary touch behavior, rather than CarPlay's focus-only
        // web controls and automatic scroll chevrons. The hosting car scene stays unchanged.
        if usesCarKeyboard { web.traitOverrides.userInterfaceIdiom = .pad }
        web.onYouTubeSearch = { [weak self] in self?.openYouTubeSearch() }
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        web.scrollView.isDirectionalLockEnabled = true
        // SwiftUI already gives this view the usable screen area; don't inset it a second time.
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        web.scrollView.bounces = false
        web.scrollView.keyboardDismissMode = .onDrag
        web.tintColor = .label
        storedWebView = web
        observations = [
            web.observe(\.url, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            web.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            web.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            web.observe(\.fullscreenState, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            web.observe(\.title, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() }
        ]
        return web
    }

    private func configurePagePreferences(for target: URL) {
        let host = target.host?.lowercased() ?? ""
        let isYouTube = host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
        // WebKit's small-screen YouTube quirk hides the element Fullscreen API,
        // even when enabled below. Disable it for YouTube's desktop player only;
        // the website still owns fullscreen, exit, controls and the video element.
        pagePreferences.isSiteSpecificQuirksModeEnabled = !isYouTube
        pagePreferences.isElementFullscreenEnabled = true
    }

    nonisolated private func scheduleUpdate() {
        Task { @MainActor [weak self] in self?.updateState() }
    }

    private func updateState() {
        guard let web = storedWebView else { return }
        if let current = web.url, ["http", "https"].contains(current.scheme?.lowercased() ?? "") { url = current }
        canGoBack = web.canGoBack
        canGoForward = web.canGoForward
        isLoading = web.isLoading
        progress = web.estimatedProgress
        pageTitle = web.title ?? ""
        let fullscreen = reportedMediaFullscreen || web.fullscreenState != .notInFullscreen
        if isPageFullscreen != fullscreen {
            isPageFullscreen = fullscreen
            if fullscreen { (web as? BrowserWebView)?.setYouTubeSearchTarget(nil) }
        }
    }

    func start() {
        let web = webView
        let shouldResume = resumeOnReturn
        resumeOnReturn = false
        if mediaSuspended {
            mediaSuspended = false
            web.setAllMediaPlaybackSuspended(false) { [weak self, weak web] in
                Task { @MainActor in
                    guard let self, self.storedWebView === web, self.displayed, !self.mediaSuspended else { return }
                    self.resumeAfterSuspension(shouldResume: shouldResume)
                }
            }
        } else {
            resumeAfterSuspension(shouldResume: shouldResume)
        }
        if web.url == nil && !isLoading { load(url) }
    }

    func setDisplayed(_ displayed: Bool) {
        self.displayed = displayed
    }
    var isDisplayed: Bool { displayed }

    /// WebKit can suspend offscreen video. Continue its audio through our native
    /// engine without presenting a player over the home screen.
    @discardableResult
    func continueYouTubeAudioOnCar() -> Bool {
        let env = AppEnvironment.shared
        if backgroundCaptureID != nil { return true }
        let host = url.host?.lowercased() ?? ""
        guard usesCarKeyboard, isPlaying, !mediaSuspended, !isPictureInPicture,
              host == "youtube.com" || host.hasSuffix(".youtube.com"),
              env.browser.ownsPlayback(self), !env.playback.isActive, let web = storedWebView else { return false }
        let expectedURL = url
        let requestID = UUID()
        backgroundCaptureID = requestID
        web.evaluateJavaScript("window.__carTVCaptureMedia?.();") { [weak self, weak web] result, _ in
            guard let self, self.backgroundCaptureID == requestID else { return }
            self.backgroundCaptureID = nil
            guard self.url == expectedURL, self.storedWebView === web,
                  env.browser.ownsPlayback(self), !env.playback.isActive,
                  let body = result as? [String: Any] else { self.suspend(); return }
            self.startBackgroundYouTubeAudio(body)
            if !env.browser.isContinuingCarBrowserAudio { self.suspend() }
        }
        return true
    }

    func cancelBackgroundCapture() {
        guard backgroundCaptureID != nil else { return }
        backgroundCaptureID = nil
        if displayed, !AppEnvironment.shared.playback.isActive {
            resumeOnReturn = true
            AppEnvironment.shared.browser.resumeIfActive(self)
        }
    }

    private func resumeAfterSuspension(shouldResume: Bool) {
        if let returned = pendingPlayerReturn {
            guard !isLoading else { return } // A native Next/Previous selection may be loading a new watch page.
            pendingPlayerReturn = nil
            storedWebView?.evaluateJavaScript("window.__carTVRestoreMedia?.(\(returned.position), \(returned.resume ? "true" : "false"));", completionHandler: nil)
        } else if shouldResume { resumeWebPlayback() }
    }

    func restoreInlineVideo(position: Double, resume: Bool, target: URL? = nil) {
        if let target { load(target) }
        pendingPlayerReturn = (position.isFinite ? max(0, position) : 0, resume)
        resumeOnReturn = false
        if displayed { AppEnvironment.shared.browser.resumeIfActive(self) }
    }

    private func startBackgroundYouTubeAudio(_ body: [String: Any]) {
        let env = AppEnvironment.shared
        guard usesCarKeyboard, !mediaSuspended, !env.playback.isActive,
              let page = body["pageURL"] as? String, let pageURL = URL(string: page),
              ["https", "http"].contains(pageURL.scheme?.lowercased() ?? ""),
              let host = pageURL.host?.lowercased(), host == "youtube.com" || host.hasSuffix(".youtube.com"),
              let videoID = YouTubeService.videoID(from: page), videoID.count == 11 else { return }
        updateState()
        let rawPosition = body["position"] as? Double ?? 0
        let position = rawPosition.isFinite ? max(0, rawPosition) : 0
        let rawDuration = body["duration"] as? Double ?? 0
        let duration = rawDuration.isFinite ? max(0, rawDuration) : 0
        let title = (body["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? pageTitle
        let isLive = body["isLive"] as? Bool ?? false
        let item = PlayableItem(ref: PlayableRef(id: YouTubeService.uuid(for: videoID), kind: .youtube),
            title: title, subtitle: nil, url: URL(string: "https://www.youtube.com/watch?v=\(videoID)")!,
            artworkURL: URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"), headers: [:], genre: nil,
            isLive: isLive, duration: duration, streamKind: .hls)
        errorMessage = nil
        env.browser.playVideo(item, from: self, position: position, isCar: true, backgroundAudio: true)
    }
    var isFullscreenActive: Bool {
        isPageFullscreen || (storedWebView?.fullscreenState ?? .notInFullscreen) != .notInFullscreen
    }

    func suspend() {
        dismissKeyboard()
        if !mediaSuspended { resumeOnReturn = isPlaying }
        isPlaying = false
        resumeAfterReload = false
        storedWebView?.evaluateJavaScript("window.__carTVPauseMedia?.();", completionHandler: nil)
        if !mediaSuspended { storedWebView?.setAllMediaPlaybackSuspended(true); mediaSuspended = true }
    }

    func search(_ text: String, on destination: BrowserDestination) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        var components = URLComponents(url: destination.searchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: destination.searchParameter, value: query)]
        if let target = components.url { load(target) }
    }

    func open(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let target: URL?
        if text.contains("://") {
            target = URL(string: text)
        } else if !text.contains(where: \.isWhitespace), text.contains(".") || text.hasPrefix("localhost") {
            target = URL(string: "https://" + text)
        } else {
            var components = URLComponents(url: destination.searchURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: destination.searchParameter, value: text)]
            target = components.url
        }
        guard let target, let host = target.host, !host.isEmpty,
              ["http", "https"].contains(target.scheme?.lowercased() ?? "") else {
            errorMessage = String(localized: "Enter a website address or search.")
            return
        }
        load(target)
    }

    func load(_ target: URL, resumePlayback: Bool = false) {
        backgroundCaptureID = nil
        pendingPlayerReturn = nil; reportedMediaFullscreen = false
        (storedWebView as? BrowserWebView)?.setYouTubeSearchTarget(nil)
        resumeOnReturn = false
        resumeAfterReload = resumePlayback
        isPlaying = false
        isPageFullscreen = false
        wantsHiddenControls = false
        if destination == .browse, target == BrowserDestination.browse.homeURL { needsInitialAddressFocus = true }
        dismissKeyboard()
        errorMessage = nil
        url = target
        configurePagePreferences(for: target)
        navigationTask?.cancel()
        isLoading = true
        let web = webView
        navigationTask = Task { @MainActor [weak self, weak web] in
            guard let self, let web else { return }
            let rules = self.blocksAds ? await BrowserContentBlocker.shared.rules() : nil
            guard !Task.isCancelled, self.storedWebView === web else { return }
            if self.blocksAds, !self.rulesInstalled, let rules {
                web.configuration.userContentController.add(rules)
                self.rulesInstalled = true
            }
            web.load(URLRequest(url: target))
        }
    }

    func goBack() { dismissKeyboard(); errorMessage = nil; storedWebView?.goBack() }
    func goForward() { dismissKeyboard(); errorMessage = nil; storedWebView?.goForward() }
    func reloadOrStop() {
        dismissKeyboard()
        if isLoading { navigationTask?.cancel(); storedWebView?.stopLoading(); isLoading = false }
        else {
            errorMessage = nil
            if webView.url == url { webView.reload() } else { load(url) }
        }
    }

    func setAdBlocking(_ enabled: Bool) {
        guard enabled != blocksAds else { return }
        blocksAds = enabled
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        rulesInstalled = false
        // The last document-start setting wins on subsequent navigations as well.
        controller.addUserScript(WKUserScript(source: "window.__carTVBlockAds = \(enabled ? "true" : "false");",
                                             injectionTime: .atDocumentStart, forMainFrameOnly: false))
        load(url)
    }

    func reset() {
        backgroundCaptureID = nil
        pendingPlayerReturn = nil; reportedMediaFullscreen = false
        navigationTask?.cancel()
        storedWebView?.stopLoading()
        storedWebView?.setAllMediaPlaybackSuspended(true)
        storedWebView?.navigationDelegate = nil
        storedWebView?.uiDelegate = nil
        observations.removeAll()
        storedWebView = nil
        url = Self.homeURL
        canGoBack = false
        canGoForward = false
        isLoading = false
        progress = 0
        errorMessage = nil
        generation += 1
        keyboardRequest = nil
        keyboardFrame = nil
        destination = .youtube
        resumeOnReturn = false
        mediaSuspended = false
        isPlaying = false
        resumeAfterReload = false
        processRecoveryAttempted = false
        recoveryURL = nil
        recoveryPosition = 0
        isPageFullscreen = false
        isPictureInPicture = false
        rulesInstalled = false
        displayed = false
        wantsHiddenControls = false
        pageTitle = ""
        needsInitialAddressFocus = false
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        // Keep app links in the browser; never launch YouTube over the car UI.
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" || scheme == "about" else {
            decisionHandler(.cancel, preferences)
            return
        }
        if navigationAction.targetFrame?.isMainFrame != false {
            preferences.preferredContentMode = .desktop
            if let target = navigationAction.request.url { configurePagePreferences(for: target) }
            if let incoming = navigationAction.request.url, incoming.host?.lowercased() == "m.youtube.com",
               var components = URLComponents(url: incoming, resolvingAgainstBaseURL: false) {
                components.host = "www.youtube.com"
                if let desktop = components.url {
                    decisionHandler(.cancel, preferences)
                    load(desktop)
                    return
                }
            }
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        reportedMediaFullscreen = false
        (webView as? BrowserWebView)?.setYouTubeSearchTarget(nil)
        isPageFullscreen = false
        isPictureInPicture = false
        wantsHiddenControls = false
        dismissKeyboard()
        errorMessage = nil
        updateState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        updateState()
        if pendingPlayerReturn != nil, displayed, !mediaSuspended { resumeAfterSuspension(shouldResume: false) }
        if resumeAfterReload {
            resumeAfterReload = false
            resumeWebPlayback()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isPageFullscreen = false
        if displayed, !processRecoveryAttempted {
            processRecoveryAttempted = true
            let resume = isPlaying
            reconnectPlayer(resume: resume)
        } else {
            errorMessage = String(localized: "The webpage stopped responding. Reload to continue.")
        }
        updateState()
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        errorMessage = error.localizedDescription
        updateState()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let target = navigationAction.request.url,
           ["http", "https"].contains(target.scheme?.lowercased() ?? "") {
            if destination == .browse {
                let tabs = usesCarKeyboard ? AppEnvironment.shared.browser.carTabs : AppEnvironment.shared.browser.phoneTabs
                tabs.add(url: target)
            } else { load(target) }
        }
        return nil
    }

    func ownsWebView(_ webView: WKWebView?) -> Bool { storedWebView === webView }

    func takeInitialAddressFocus() -> Bool {
        defer { needsInitialAddressFocus = false }
        return needsInitialAddressFocus
    }

    func updateYouTubeSearchTarget(_ rect: [String: Double]?) {
        guard usesCarKeyboard, let web = storedWebView as? BrowserWebView else { return }
        guard let rect, let x = rect["x"], let y = rect["y"], let width = rect["width"], let height = rect["height"],
              [x, y, width, height].allSatisfy({ $0.isFinite }), width > 0, height > 0,
              x < 1, y < 1, x + width > 0, y + height > 0 else {
            web.setYouTubeSearchTarget(nil)
            return
        }
        web.setYouTubeSearchTarget(CGRect(x: x, y: y, width: width, height: height))
    }

    func openYouTubeSearch() {
        guard displayed, !isPageFullscreen else { return }
        searchText = ""
        keyboardFrame = nil
        keyboardRequest = BrowserKeyboardRequest(value: "", placeholder: "Search YouTube", secure: false, searchDestination: .youtube)
    }

    func requestKeyboard(_ request: BrowserKeyboardRequest, frame: WKFrameInfo) {
        keyboardFrame = frame
        searchText = request.value
        keyboardRequest = request
    }

    func updateWebInput(_ text: String) {
        guard let request = keyboardRequest else { return }
        if request.searchDestination != nil { searchText = text; return }
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let literal = String(data: data, encoding: .utf8) else { return }
        // JSON encoding keeps quotes, backslashes and Unicode inside a JS string literal.
        let script = "window.__carTVSetInput(\(literal)[0]);"
        storedWebView?.evaluateJavaScript(script, in: keyboardFrame, in: .page, completionHandler: nil)
    }

    func submitWebInput() {
        if let destination = keyboardRequest?.searchDestination {
            search(searchText, on: destination)
            submissionID += 1
            return
        }
        storedWebView?.evaluateJavaScript("window.__carTVSubmitInput();", in: keyboardFrame, in: .page, completionHandler: nil)
        keyboardRequest = nil
        keyboardFrame = nil
    }

    func dismissKeyboard() {
        keyboardRequest = nil
        keyboardFrame = nil
        storedWebView?.endEditing(true)
    }

    func setControlsHidden(_ hidden: Bool) {
        wantsHiddenControls = hidden
        storedWebView?.evaluateJavaScript("window.__carTVSetChromeHidden?.(\(hidden ? "true" : "false"));", completionHandler: nil)
    }

    func handlePageEvent(_ event: String) {
        switch event {
        case "chrome-hide": wantsHiddenControls = true
        case "chrome-show": wantsHiddenControls = false
        case "submit": submissionID += 1; dismissKeyboard()
        case "youtube-search":
            openYouTubeSearch()
        case "pip-enter": isPictureInPicture = true
        case "pip-exit": isPictureInPicture = false
        case "fullscreen-enter":
            reportedMediaFullscreen = true
            isPageFullscreen = true
            (storedWebView as? BrowserWebView)?.setYouTubeSearchTarget(nil)
        case "fullscreen-exit": reportedMediaFullscreen = false; updateState()
        case "play", "play-request":
            guard displayed, !AppEnvironment.shared.playback.isActive else { return }
            if usesCarKeyboard && !AppEnvironment.shared.carPlay.supportsVideoPlayback { return }
            AppEnvironment.shared.browser.activate(self)
        case "playing":
            guard displayed, !mediaSuspended else { return }
            isPlaying = true
            processRecoveryAttempted = false
            errorMessage = nil
        case "pause": isPlaying = false
        case "media-error":
            errorMessage = String(localized: "Video playback failed. Reconnect the web player to retry.")
        default: break
        }
    }

    private func resumeWebPlayback() {
        let position = recoveryPosition.isFinite ? max(0, recoveryPosition) : 0
        storedWebView?.evaluateJavaScript("window.__carTVResumeMedia?.(\(position));", completionHandler: nil)
        recoveryPosition = 0
    }

    func reportMediaFailure(_ reason: String, position: Double, readyState: Int, errorCode: Int) {
        guard displayed, !mediaSuspended, !AppEnvironment.shared.playback.isActive else { return }
        Log.network.error("Web player failure: \(reason, privacy: .public), readyState=\(readyState), mediaError=\(errorCode)")
        // Recover once for this page; repeated failures stay reviewable, never reload in a loop.
        if recoveryURL != url {
            recoveryURL = url
            reconnectPlayer(position: position, resume: true)
        } else {
            errorMessage = String(localized: "Video playback is unavailable. Reconnect the web player to retry.")
        }
    }

    /// Recreate WebKit's media context without requiring an app restart or clearing sign-in.
    func reconnectPlayer(position: Double = 0, resume: Bool = true) {
        let target = url
        navigationTask?.cancel()
        storedWebView?.pauseAllMediaPlayback(completionHandler: nil)
        storedWebView?.stopLoading()
        storedWebView?.navigationDelegate = nil
        storedWebView?.uiDelegate = nil
        observations.removeAll()
        storedWebView = nil
        rulesInstalled = false
        mediaSuspended = false
        keyboardFrame = nil
        keyboardRequest = nil
        isPageFullscreen = false
        recoveryPosition = position.isFinite ? max(0, position) : 0
        generation += 1
        load(target, resumePlayback: resume)
    }

    func handleAudioSession(_ event: AudioSessionController.Event) {
        // WebKit handles phone/Siri interruptions itself. Host AVAudioSession
        // notifications belong to the native player and must not lock HTML playback.
        if case .mediaServicesReset = event, displayed, !mediaSuspended {
            reconnectPlayer(resume: isPlaying)
        }
    }

}

enum BrowserDestination: String, CaseIterable, Identifiable {
    case youtube, tiktok, browse
    var id: Self { self }
    var title: String { switch self { case .youtube: "YouTube"; case .tiktok: "TikTok"; case .browse: "Browse" } }
    var symbol: String { switch self { case .youtube: "play.rectangle.fill"; case .tiktok: "music.note"; case .browse: "globe" } }
    var homeURL: URL {
        switch self {
        case .youtube: BrowserSession.homeURL
        case .tiktok: URL(string: "https://www.tiktok.com")!
        case .browse: URL(string: "https://www.google.com")!
        }
    }
    var searchURL: URL {
        switch self {
        case .youtube: BrowserSession.homeURL.appendingPathComponent("results")
        case .tiktok: homeURL.appendingPathComponent("search")
        case .browse: homeURL.appendingPathComponent("search")
        }
    }
    var searchParameter: String { switch self { case .youtube: "search_query"; case .tiktok, .browse: "q" } }
}

/// CarPlay decorates scroll indicators with chevrons. Hide indicators on both the
/// page and its overflow regions without removing native views or disabling scrolling.
@MainActor
private final class BrowserWebView: WKWebView {
    var hidesCarScrollIndicators = false
    var onYouTubeSearch: (() -> Void)?
    private var searchTarget: CGRect?
    private var searchButton: UIButton?

    /// Normalized CSS viewport coordinates remain correct when the car canvas scales.
    func setYouTubeSearchTarget(_ rect: CGRect?) {
        guard rect != searchTarget else { return }
        searchTarget = rect
        if rect != nil, searchButton == nil {
            let button = UIButton(type: .custom)
            button.accessibilityLabel = String(localized: "Search YouTube")
            button.addAction(UIAction { [weak self] _ in self?.onYouTubeSearch?() }, for: .touchUpInside)
            // Match the site's search icon while supplying a full native tap target.
            button.setImage(UIImage(systemName: "magnifyingglass"), for: .normal)
            button.tintColor = .white
            button.backgroundColor = .black
            button.layer.cornerRadius = 22
            addSubview(button)
            searchButton = button
        }
        searchButton?.isHidden = rect == nil
        setNeedsLayout()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // WebKit's content/focus views must not intercept the native search target.
        if let searchButton, !searchButton.isHidden, searchButton.isUserInteractionEnabled,
           searchButton.frame.contains(point) {
            return searchButton
        }
        return super.hitTest(point, with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // WebKit owns the fullscreen hierarchy and its animation. Avoid traversing
        // that hierarchy or repositioning page overlays on every animation layout.
        guard fullscreenState == .notInFullscreen else { return }
        if let rect = searchTarget, let searchButton {
            let width = min(bounds.width, max(44, min(52, rect.width * bounds.width)))
            let height = min(bounds.height, max(44, min(52, rect.height * bounds.height)))
            searchButton.frame = CGRect(
                x: min(max(0, rect.midX * bounds.width - width / 2), bounds.width - width),
                y: min(max(0, rect.midY * bounds.height - height / 2), bounds.height - height),
                width: width, height: height)
            if subviews.last !== searchButton { bringSubviewToFront(searchButton) }
        }
        guard hidesCarScrollIndicators else { return }
        hideIndicators(in: self)
    }

    private func hideIndicators(in view: UIView) {
        if let scroll = view as? UIScrollView {
            if scroll.showsVerticalScrollIndicator { scroll.showsVerticalScrollIndicator = false }
            if scroll.showsHorizontalScrollIndicator { scroll.showsHorizontalScrollIndicator = false }
        }
        for child in view.subviews { hideIndicators(in: child) }
    }
}
