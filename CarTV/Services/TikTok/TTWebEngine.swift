import Foundation
import WebKit
import Observation
import OSLog

/// TikTok's web app, running headless in a WKWebView, used as the signing engine.
///
/// TikTok's feed endpoints need `X-Gnarly` — a ChaCha20 signature over a canvas
/// fingerprint that rotates monthly. Nobody ports it; every maintained client lets
/// TikTok's own JS run in a real browser and captures the responses. WebKit is a
/// real browser and this is a real login, so the SDK signs correctly, forever.
///
/// We inject a script that wraps `fetch`/`XMLHttpRequest`, posts every
/// `/api/*item_list*` JSON body back to Swift, and expose two commands to the page:
/// scroll (to make it fetch the next batch) and navigate (For You ↔ Following).
@Observable
final class TTWebEngine: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    enum Feed: String { case forYou = "/foryou", following = "/following" }

    /// Captured pages, newest last. Consumers (TikTokService) drain these.
    var onItems: ((Feed, [TTVideo]) -> Void)?
    private(set) var isReady = false          // page loaded and hooks installed
    private(set) var currentFeed: Feed = .forYou
    private(set) var lastCaptureAt: Date?

    private var web: WKWebView?
    private var pendingScrolls = 0
    private var idleTimer: Task<Void, Never>?

    // MARK: Lifecycle

    /// Build (or reuse) the hidden web view. Call after sign-in; cheap to call again.
    @MainActor
    func start(feed: Feed = .forYou) {
        if web == nil {
            let cfg = WKWebViewConfiguration()
            cfg.websiteDataStore = .default()          // shares cookies with the login view
            cfg.mediaTypesRequiringUserActionForPlayback = .all   // never autoplay — we only want the JSON
            cfg.allowsInlineMediaPlayback = false
            let ucc = WKUserContentController()
            ucc.add(self, name: "tt")
            ucc.addUserScript(WKUserScript(source: Self.hookScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            cfg.userContentController = ucc
            let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: cfg)
            w.customUserAgent = TTSession.userAgent
            w.navigationDelegate = self
            w.isHidden = true
            // Must be in a window for WebKit to run timers/scroll at full speed.
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
               let window = scene.windows.first {
                w.alpha = 0.01; w.isUserInteractionEnabled = false
                window.insertSubview(w, at: 0)
            }
            web = w
        }
        load(feed)
    }

    @MainActor
    func load(_ feed: Feed) {
        guard let web else { return }
        currentFeed = feed
        isReady = false
        web.load(URLRequest(url: URL(string: "https://www.tiktok.com\(feed.rawValue)")!))
    }

    /// Ask the page for another batch. TikTok fetches on scroll; we scroll.
    @MainActor
    func requestMore() {
        guard let web, isReady else { pendingScrolls += 1; return }
        web.evaluateJavaScript("window.__cartvScroll && window.__cartvScroll()") { _, _ in }
    }

    @MainActor
    func stop() {
        web?.stopLoading()
        web?.removeFromSuperview()
        web = nil
        isReady = false
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            isReady = true
            Log.network.info("TikTok engine: \(webView.url?.path ?? "?", privacy: .public) loaded")
            // Kick a scroll so the first XHR fires even if SSR already painted a page.
            while pendingScrolls > 0 { pendingScrolls -= 1; requestMore() }
            requestMore()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Keep the engine on tiktok.com; if it tries to go to /login the session died.
        if let url = action.request.url, url.path.hasPrefix("/login") {
            Task { @MainActor in AppEnvironment.shared.tiktok.sessionExpired() }
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "tt", let dict = message.body as? [String: Any],
              let kind = dict["kind"] as? String else { return }
        switch kind {
        case "items":
            guard let url = dict["url"] as? String, let body = dict["body"] as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let raw = (json["itemList"] as? [[String: Any]]) ?? (json["item_list"] as? [[String: Any]]) ?? []
            let items = raw.compactMap(TTParser.video)
            let feed: Feed = url.contains("from_page=following") || currentFeed == .following ? .following : .forYou
            Task { @MainActor in
                lastCaptureAt = .now
                Log.network.info("TikTok engine: captured \(items.count) items from \(URL(string: url)?.path ?? url, privacy: .public)")
                onItems?(feed, items)
            }
        case "log":
            Log.network.debug("TikTok page: \(dict["msg"] as? String ?? "", privacy: .public)")
        default: break
        }
    }

    // MARK: Injected JS

    /// Wraps fetch + XHR, mirrors item_list bodies to Swift, exposes __cartvScroll.
    private static let hookScript = #"""
    (function () {
      if (window.__cartvHooked) return; window.__cartvHooked = true;
      const post = (o) => { try { window.webkit.messageHandlers.tt.postMessage(o); } catch (e) {} };
      const wanted = (u) => /\/api\/(recommend|post|challenge|search|explore)\/[^?]*item_list/.test(u) || /\/api\/search\/item/.test(u);

      // fetch
      const _fetch = window.fetch;
      window.fetch = async function (input, init) {
        const res = await _fetch.apply(this, arguments);
        try {
          const u = typeof input === 'string' ? input : (input && input.url) || '';
          if (wanted(u)) { res.clone().text().then(t => { if (t && t.length > 2) post({ kind: 'items', url: u, body: t }); }); }
        } catch (e) {}
        return res;
      };

      // XHR
      const _open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (m, u) { this.__cartvURL = u; return _open.apply(this, arguments); };
      const _send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function () {
        this.addEventListener('load', function () {
          try { if (wanted(this.__cartvURL || '') && this.responseText && this.responseText.length > 2)
                  post({ kind: 'items', url: this.__cartvURL, body: this.responseText }); } catch (e) {}
        });
        return _send.apply(this, arguments);
      };

      // Scroll to trigger the next page. TikTok's feed container varies; scroll every scrollable.
      window.__cartvScroll = function () {
        try {
          window.scrollTo(0, document.documentElement.scrollHeight);
          document.querySelectorAll('[class*="DivVideoFeed"], [data-e2e*="feed"], main, #main-content-homepage_hot')
            .forEach(el => { try { el.scrollTop = el.scrollHeight; } catch (e) {} });
          // Nudge via keyboard-style event too; some builds listen for wheel.
          window.dispatchEvent(new WheelEvent('wheel', { deltaY: 4000, bubbles: true }));
        } catch (e) {}
      };

      // Never let the page play video/audio — we only want the JSON.
      const mute = () => document.querySelectorAll('video').forEach(v => { try { v.muted = true; v.pause(); v.autoplay = false; } catch (e) {} });
      new MutationObserver(mute).observe(document.documentElement, { childList: true, subtree: true });
      post({ kind: 'log', msg: 'hooks installed' });
    })();
    """#
}
