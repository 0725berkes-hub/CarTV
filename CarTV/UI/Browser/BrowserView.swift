import SwiftUI
import WebKit

struct BrowserView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(\.scenePhase) private var scenePhase
    @Environment(CarKeyboardPresentation.self) private var carKeyboard: CarKeyboardPresentation?
    let session: BrowserSession
    var isCar = false
    var editOnOpen = false
    var onClose: () -> Void = {}
    var onSites: () -> Void = {}
    var tabs: BrowserTabs?
    @State private var address = ""
    @State private var visible = false
    @State private var chromeVisible = true
    @State private var keyboardTarget: KeyboardTarget?
    @State private var keyboardText = ""
    @State private var showsTabs = false
    @State private var controlsInteraction = 0
    @FocusState private var editingAddress: Bool

    private enum KeyboardTarget: Equatable { case address, website }

    var body: some View {
        VStack(spacing: 0) {
            if chromeVisible || editingAddress || keyboardTarget != nil || showsTabs {
                controls
                    .simultaneousGesture(TapGesture().onEnded { controlsInteraction += 1 })
                    .padding(.horizontal, Theme.s2)
                    .padding(.vertical, 2)
                    .background(Theme.surface)
                    // Preserve the source viewport while WebKit animates the webpage
                    // into its fullscreen window; removing chrome here resizes it twice.
                    .opacity(session.isPageFullscreen ? 0 : 1)
                    .allowsHitTesting(!session.isPageFullscreen)
            }
            if let message = session.errorMessage {
                HStack {
                    Text(message).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    Button { session.reconnectPlayer() } label: { Text("Reconnect").padding(.horizontal, Theme.s2).frame(minHeight: 44).contentShape(Rectangle()) }
                    Button { session.errorMessage = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .accessibilityLabel("Dismiss error")
                }
                .padding(Theme.s2).background(Theme.raised)
            }
            BrowserSurface(session: session)
                .id(session.generation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if session.isLoading {
                        ProgressView(value: session.progress).tint(Theme.accent)
                            .accessibilityLabel("Loading webpage")
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if !session.isPageFullscreen && !chromeVisible {
                        Button { chromeVisible = true; controlsInteraction += 1 } label: {
                            Image(systemName: "chevron.down").font(.system(size: 18, weight: .bold))
                                .frame(width: 44, height: 40)
                        }
                        .buttonStyle(CarPressStyle())
                        .glassEffect(.regular.interactive(), in: Capsule())
                        .padding(Theme.s2)
                        .accessibilityLabel("Show browser controls")
                    }
                }
        }
        .background(Theme.ground)
        .overlay(alignment: .bottom) {
            if isCar, carKeyboard == nil, let keyboardTarget {
                CarBrowserKeyboard(
                    text: $keyboardText,
                    placeholder: keyboardTarget == .address ? "Website or search" : (session.keyboardRequest?.placeholder ?? "Type here"),
                    secure: keyboardTarget == .website && (session.keyboardRequest?.secure ?? false),
                    onGo: submitKeyboard,
                    onDone: dismissKeyboard
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.ground)
            }
        }
        .overlay {
            if showsTabs, let tabs {
                BrowserTabPicker(tabs: tabs, onDone: { showsTabs = false })
                    .padding(isCar ? Theme.s5 : Theme.s4)
                    .background(Theme.ground.opacity(0.97))
            }
        }
        .onAppear {
            visible = true
            session.setDisplayed(true)
            address = session.url.absoluteString
            if env.browser.isContinuingCarBrowserAudio { env.browser.returnFromPlayer() }
            if playback.isActive, !env.browser.isPresentingBrowserVideo { playback.stop(deactivateAudio: false) }
            env.browser.activate(session)
            if editOnOpen, session.takeInitialAddressFocus() { editAddress() }
        }
        .onDisappear {
            guard !session.isFullscreenActive else { return }
            let continuingAudio = !session.isPictureInPicture && isCar && session.continueYouTubeAudioOnCar()
            visible = false; session.setDisplayed(false); dismissKeyboard()
            guard !session.isPictureInPicture else { return }
            if !continuingAudio { session.suspend() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Phone activation must not steal playback from the car window. Transient
            // inactive states (menus and system overlays) aren't a reason to suspend video.
            guard !isCar, visible else { return }
            if phase == .active && !playback.isActive { env.browser.resumeIfActive(session) }
            else if phase == .background { dismissKeyboard(); if !session.isPictureInPicture { session.suspend() } }
        }
        .onChange(of: session.url) { old, url in
            if old.host != url.host || old.path != url.path || old.query != url.query {
                editingAddress = false
                session.dismissKeyboard()
            }
            if !editingAddress && keyboardTarget != .address { address = url.absoluteString }
        }
        .onChange(of: session.submissionID) { _, _ in
            editingAddress = false
            keyboardTarget = nil
            keyboardText = ""
        }
        .onChange(of: session.keyboardRequest?.id, initial: true) { _, id in
            if id != nil, let request = session.keyboardRequest {
                if isCar {
                    keyboardText = request.value
                    keyboardTarget = .website
                    chromeVisible = true
                } else if request.searchDestination != nil {
                    address = request.value
                    editingAddress = true
                }
            } else {
                if keyboardTarget == .website {
                    keyboardTarget = nil
                    keyboardText = ""
                }
            }
        }
        .onChange(of: keyboardTarget) { _, target in
            guard isCar, let carKeyboard else { return }
            guard let target else { carKeyboard.dismiss(); return }
            carKeyboard.show(text: $keyboardText,
                placeholder: target == .address ? "Website or search" : (session.keyboardRequest?.placeholder ?? "Type here"),
                secure: target == .website && (session.keyboardRequest?.secure ?? false),
                onGo: submitKeyboard, onDone: dismissKeyboard)
        }
        .onChange(of: keyboardText) { _, text in
            if keyboardTarget == .website { session.updateWebInput(text) }
        }
        .onChange(of: session.wantsHiddenControls) { _, hidden in
            guard !editingAddress, keyboardTarget == nil, !showsTabs else { return }
            chromeVisible = !hidden
        }
        .onChange(of: chromeVisible) { _, visible in
            session.setControlsHidden(!visible)
        }
        .task(id: controlsAutoHideState) {
            guard controlsAutoHideState.canHide else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled, controlsAutoHideState.canHide else { return }
            chromeVisible = false
        }
        .onChange(of: playback.isActive) { _, active in
            if active { dismissKeyboard(); session.suspend() }
        }
    }

    private struct ControlsAutoHideState: Hashable {
        let canHide: Bool
        let interaction: Int
        let page: URL
    }

    private var controlsAutoHideState: ControlsAutoHideState {
        ControlsAutoHideState(canHide: visible && (isCar || scenePhase == .active) && chromeVisible &&
            !editingAddress && keyboardTarget == nil && !showsTabs &&
            !session.isLoading && !session.isFullscreenActive,
            interaction: controlsInteraction, page: session.url)
    }

    private var controls: some View {
        HStack(spacing: Theme.s1) {
            control("Back", symbol: "chevron.left") {
                dismissKeyboard()
                if session.canGoBack { session.goBack() } else { onSites() }
            }
            control("Choose a website", symbol: "square.grid.2x2", action: onSites)
            if isCar || !editingAddress {
                Button(action: editAddress) {
                    HStack(spacing: 7) {
                        Image(systemName: "globe").foregroundStyle(Theme.accent)
                        Text(session.url.host?.replacingOccurrences(of: "www.", with: "") ?? "Browse")
                            .font(.system(size: 15, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        if isCar { Image(systemName: "keyboard").foregroundStyle(Theme.inkMuted) }
                    }
                    .padding(.horizontal, Theme.s3).frame(maxWidth: .infinity, minHeight: 40)
                    .background(Theme.raised, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(CarPressStyle()).accessibilityLabel("Enter a website or search")
            } else {
                TextField(session.keyboardRequest?.placeholder ?? "Website or search", text: $address)
                    .keyboardType(.webSearch).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().submitLabel(.go).focused($editingAddress)
                    .font(.system(size: 15))
                    .onSubmit { submitAddress() }
                    .padding(.horizontal, Theme.s3).frame(minHeight: 44)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusS))
                    .accessibilityLabel("Website address or search")
            }
            Button { session.reloadOrStop() } label: {
                Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(CarPressStyle())
            .accessibilityLabel(session.isLoading ? "Stop loading" : "Refresh page")
            .contextMenu {
                Button { session.goBack() } label: { Label("Back", systemImage: "chevron.left") }.disabled(!session.canGoBack)
                Button { session.goForward() } label: { Label("Forward", systemImage: "chevron.right") }.disabled(!session.canGoForward)
                Button { session.load(session.destination.homeURL) } label: { Label("Website home", systemImage: "house") }
                Button { session.reconnectPlayer() } label: { Label("Reconnect web player", systemImage: "arrow.triangle.2.circlepath") }
                Toggle("Block ads", isOn: Binding(get: { session.blocksAds }, set: { session.setAdBlocking($0) }))
            }
            if let tabs {
                Button { dismissKeyboard(); showsTabs = true } label: {
                    Image(systemName: "square.on.square").overlay {
                        Text("\(tabs.sessions.count)").font(.system(size: 10, weight: .bold)).offset(y: 1)
                    }
                    .font(.system(size: 22)).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(CarPressStyle()).accessibilityLabel("Browser tabs")
            }
            if isCar {
                control("Hide controls", symbol: "arrow.up.left.and.arrow.down.right") {
                    dismissKeyboard()
                    chromeVisible = false
                }
            }
        }
        .foregroundStyle(Theme.ink)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private func control(_ label: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(CarPressStyle()).accessibilityLabel(Text(label))
    }

    private func editAddress() {
        if isCar {
            session.dismissKeyboard()
            keyboardText = ""
            keyboardTarget = .address
            chromeVisible = true
        } else {
            address = ""
            editingAddress = true
        }
    }

    private func submitAddress() {
        if session.keyboardRequest?.searchDestination != nil {
            session.updateWebInput(address)
            session.submitWebInput()
        } else { session.open(address) }
        editingAddress = false
        address = session.url.absoluteString
    }

    private func submitKeyboard() {
        if keyboardTarget == .address { session.open(keyboardText) }
        else { session.updateWebInput(keyboardText); session.submitWebInput() }
        dismissKeyboard()
    }

    private func dismissKeyboard() {
        carKeyboard?.dismiss()
        session.dismissKeyboard()
        keyboardTarget = nil
        keyboardText = ""
    }
}

/// Keep SwiftUI's view mounted while WebKit temporarily hosts the webpage in
/// its fullscreen window. A plain autoresizing child tolerates WebKit reparenting.
private struct BrowserSurface: UIViewRepresentable {
    let session: BrowserSession
    func makeUIView(context: Context) -> BrowserContainerView { BrowserContainerView(webView: session.webView) }
    func updateUIView(_ uiView: BrowserContainerView, context: Context) {}
    static func dismantleUIView(_ uiView: BrowserContainerView, coordinator: ()) { uiView.endEditing(true) }
}

private final class BrowserContainerView: UIView {
    private weak var webView: WKWebView?
    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.frame = bounds
        addSubview(webView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let webView, webView.superview === self, webView.frame != bounds {
            webView.frame = bounds
        }
    }
}

private struct BrowserLauncher: View {
    var isCar = false
    @Environment(\.carMetrics) private var metrics
    let open: (BrowserDestination) -> Void

    var body: some View {
        if isCar {
            ScrollView {
                CarShelf(title: "Websites") {
                    ForEach(BrowserDestination.allCases) { site in
                        Button { open(site) } label: {
                            VStack(alignment: .leading, spacing: Theme.s2) {
                                BrowserSiteIcon(site: site)
                                    .frame(maxWidth: .infinity).frame(height: metrics.tileWidth * 9 / 16)
                                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusM))
                                Text(site.title).font(Theme.Font.tile).foregroundStyle(Theme.ink)
                                Text(site == .browse ? "Websites & search" : site == .youtube ? "Videos & music" : "Short videos")
                                    .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
                            }
                            .frame(width: metrics.tileWidth).padding(6)
                            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusM))
                        }
                        .buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Theme.radiusM))
                    }
                }
                .padding(.top, Theme.s2)
                .padding(.bottom, metrics.gutter)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    Text("Websites").font(Theme.Font.title2).foregroundStyle(Theme.ink)
                    LazyVGrid(columns: [GridItem(.flexible())], spacing: Theme.s3) {
                        ForEach(BrowserDestination.allCases) { site in
                            Button { open(site) } label: {
                                HStack(spacing: Theme.s3) {
                                    BrowserSiteIcon(site: site)
                                        .frame(width: 48, height: 48)
                                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusS))
                                    VStack(alignment: .leading, spacing: Theme.s1) {
                                        Text(site.title).font(Theme.Font.headline).foregroundStyle(Theme.ink)
                                        Text(site == .browse ? "Websites & search" : site == .youtube ? "Videos & music" : "Short videos")
                                            .font(.caption).foregroundStyle(Theme.inkMuted)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.inkFaint)
                                }
                                .padding(Theme.s4)
                                .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM))
                                .contentShape(RoundedRectangle(cornerRadius: Theme.radiusM))
                            }
                            .buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
                        }
                    }
                }
                .padding(Theme.s4)
            }
            .background(Theme.ground)
        }
    }
}

struct BrowserSiteIcon: View {
    let site: BrowserDestination
    var body: some View {
        switch site {
        case .youtube:
            Image("YouTubeMark").resizable().scaledToFit().padding(8)
        case .tiktok:
            Image("TikTokMark").resizable().scaledToFit().padding(5)
        case .browse:
            Image(systemName: "globe").font(.system(size: 27, weight: .medium)).foregroundStyle(Theme.accent)
        }
    }
}

struct PhoneBrowserView: View {
    @Environment(AppEnvironment.self) private var env
    private var site: BrowserDestination? { env.browser.phoneDestination }
    var body: some View {
        NavigationStack {
            Group {
                if let site {
                    let session = env.browser.session(for: site, isCar: false)
                    BrowserView(session: session, editOnOpen: site == .browse, onSites: { env.browser.phoneDestination = nil },
                                tabs: site == .browse ? env.browser.phoneTabs : nil)
                        .id(session.id)
                } else {
                    BrowserLauncher { site in
                        env.browser.open(site, isCar: false)
                    }
                }
            }
            .navigationTitle("Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(site == nil ? .visible : .hidden, for: .navigationBar)
            .toolbar(site == nil ? .visible : .hidden, for: .tabBar)
            .toolbar { ToolbarItem(placement: .topBarLeading) { MoreToolbarMenu() } }
        }
    }
}

struct CarBrowserView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(CarPlayCoordinator.self) private var car
    let onClose: () -> Void
    var onWebsiteOpenChanged: (Bool) -> Void = { _ in }
    private var site: BrowserDestination? { env.browser.carDestination }
    var body: some View {
        Group {
            if !car.supportsVideoPlayback {
                VStack {
                    Button("Back to CarTV", action: onClose).padding(Theme.s3)
                    CarEmptyState(symbol: "globe", title: "Browser unavailable", message: "The browser is available when your car allows video playback.")
                }
            } else if let site {
                let session = env.browser.session(for: site, isCar: true)
                BrowserView(session: session, isCar: true, editOnOpen: site == .browse,
                            onClose: onClose, onSites: { env.browser.carDestination = nil }, tabs: site == .browse ? env.browser.carTabs : nil)
                    .id(session.id)
            } else {
                VStack(spacing: 0) {
                    BrowserLauncher(isCar: true) { site in
                        env.browser.open(site, isCar: true)
                    }
                }
                .background(Theme.ground)
            }
        }
        .onChange(of: site, initial: true) { _, value in onWebsiteOpenChanged(value != nil) }
        .onDisappear { onWebsiteOpenChanged(false) }
        .onChange(of: car.supportsVideoPlayback) { _, supported in
            if !supported {
                let session = env.browser.session(for: site ?? .browse, isCar: true)
                session.dismissKeyboard(); session.suspend()
            }
        }
    }
}
