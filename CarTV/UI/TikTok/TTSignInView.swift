import SwiftUI
import WebKit

/// Log into tiktok.com in an in-app browser. When `sessionid` appears in the cookie
/// store, the session adopts the cookies and we dismiss. No password touches the app.
struct TTSignInView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var progress: Double = 0
    @State private var done = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                TTLoginWebView(progress: $progress) { store in
                    Task { @MainActor in
                        await env.tiktok.session.adopt(from: store)
                        if env.tiktok.session.isSignedIn, !done {
                            done = true
                            env.tiktok.didSignIn()
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            dismiss()
                        }
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                if progress < 1 {
                    ProgressView(value: progress).tint(Theme.accent).frame(height: 2)
                }
            }
            .navigationTitle("Sign in to TikTok")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .interactiveDismissDisabled()
    }
}

private struct TTLoginWebView: UIViewRepresentable {
    @Binding var progress: Double
    let onSessionCookie: (WKHTTPCookieStore) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // persistent, so a 2FA flow survives a relaunch
        config.applicationNameForUserAgent = nil
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = TTSession.userAgent    // desktop UA → desktop login page, no app-download nag
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        context.coordinator.observe(web)
        config.websiteDataStore.httpCookieStore.add(context.coordinator)
        web.load(URLRequest(url: URL(string: "https://www.tiktok.com/login")!))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        let parent: TTLoginWebView
        private var observation: NSKeyValueObservation?
        init(parent: TTLoginWebView) { self.parent = parent }

        func observe(_ web: WKWebView) {
            observation = web.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
                DispatchQueue.main.async { self?.parent.progress = w.estimatedProgress }
            }
        }

        // Fires on every cookie change; we check for the session cookie.
        func cookiesDidChange(in store: WKHTTPCookieStore) {
            Task { @MainActor in
                let all = await store.allCookies()
                if all.contains(where: { $0.name == "sessionid" && $0.domain.hasSuffix("tiktok.com") && !$0.value.isEmpty }) {
                    parent.onSessionCookie(store)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Landing on the feed/profile after login also means we're in.
            if let host = webView.url?.host, host.contains("tiktok.com"),
               let path = webView.url?.path, path == "/" || path.hasPrefix("/foryou") || path.hasPrefix("/@") {
                cookiesDidChange(in: webView.configuration.websiteDataStore.httpCookieStore)
            }
        }
    }
}
