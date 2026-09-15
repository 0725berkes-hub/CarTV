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

    enum Feed: Hashable {
        case forYou, following, profile(handle: String)
        /// Your own profile tabs. TikTok's web app fetches these via
        /// user/favorite_item_list and favorite/item_list once the tab is selected.
        case saved(handle: String), liked(handle: String)
        var path: String {
            switch self {
            case .forYou: "/foryou"
            case .following: "/following"
            case .profile(let h): "/@\(h)"
            case .saved(let h): "/@\(h)?tab=favorites"
            case .liked(let h): "/@\(h)?tab=liked"
            }
        }
    }

    /// Who the page thinks is logged in (uniqueId). nil → guest.
    private(set) var pageUser: String?

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
        web.load(URLRequest(url: URL(string: "https://www.tiktok.com\(feed.path)")!))
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
            // Who does the page think we are? Proves the feed is personalised (or not).
            if let who = try? await webView.evaluateJavaScript(Self.whoAmIScript) as? String {
                pageUser = who.isEmpty ? nil : who
                Log.network.info("TikTok engine: page user = \(who.isEmpty ? "GUEST" : who, privacy: .public)")
            }
            // Profile sub-tabs are client-side; select the one we want.
            switch currentFeed {
            case .saved: _ = try? await webView.evaluateJavaScript("window.__cartvTab && window.__cartvTab('favorites')")
            case .liked: _ = try? await webView.evaluateJavaScript("window.__cartvTab && window.__cartvTab('liked')")
            default: break
            }
            // Kick a scroll so the first XHR fires even if SSR already painted a page.
            while pendingScrolls > 0 { pendingScrolls -= 1; requestMore() }
            requestMore()
        }
    }

    private static let whoAmIScript = #"""
    (function(){ try {
      const el = document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__');
      if (el) { const d = JSON.parse(el.textContent); const u = d?.__DEFAULT_SCOPE__?.['webapp.app-context']?.user; if (u && u.uniqueId) return u.uniqueId; }
      const a = document.querySelector('[data-e2e="profile-icon"] img, [data-e2e="nav-profile"] img');
      return a ? (a.getAttribute('alt') || '') : '';
    } catch (e) { return ''; } })()
    """#

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
            // Route by what the page asked for, not by what we think we loaded — the
            // For You page also prefetches other lists.
            let feed: Feed
            if url.contains("/api/user/collect/item_list") || url.contains("favorite_item_list"), case .saved = currentFeed { feed = currentFeed }
            else if url.contains("/api/favorite/item_list") || url.contains("/api/user/favorite"), case .liked = currentFeed { feed = currentFeed }
            else if url.contains("/api/post/item_list"), case .profile = currentFeed { feed = currentFeed }
            else if url.contains("from_page=following") { feed = .following }
            else if url.contains("/api/recommend/") { feed = .forYou }
            else { feed = currentFeed }
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
      window.__cartvCaptures = 0;
      const post = (o) => { try { if (o.kind === 'items') window.__cartvCaptures++; window.webkit.messageHandlers.tt.postMessage(o); } catch (e) {} };
      const wanted = (u) => /\/api\/(recommend|post|challenge|search|explore|favorite|user\/collect|user\/favorite)\/[^?]*item_list/.test(u)
                         || /\/api\/search\/item/.test(u) || /favorite_item_list/.test(u);

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
      // The web FYP snaps one video per step and only fetches more near the end of
      // what it holds. So advance like a user: ArrowDown / wheel, several times, with
      // pauses, until a new item_list lands (or we give up).
      let advancing = false;
      window.__cartvScroll = function () {
        if (advancing) return; advancing = true;
        const before = window.__cartvCaptures || 0;
        let steps = 0;
        const step = () => {
          steps++;
          try {
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', code: 'ArrowDown', keyCode: 40, which: 40, bubbles: true }));
            const feed = document.querySelector('[data-e2e="recommend-list-item-container"], [class*="DivVideoFeed"], main') || document.scrollingElement;
            feed.dispatchEvent(new WheelEvent('wheel', { deltaY: 600, bubbles: true, cancelable: true }));
            window.scrollBy(0, window.innerHeight);
          } catch (e) {}
          const got = (window.__cartvCaptures || 0) > before;
          if (got || steps >= 12) { advancing = false; post({ kind: 'log', msg: 'advance ' + (got ? 'captured' : 'gave up') + ' after ' + steps }); return; }
          setTimeout(step, 350);
        };
        step();
      };

      // Select a profile tab by data-e2e ("favorites" / "liked").
      window.__cartvTab = function (name) {
        const sel = { favorites: '[data-e2e="favorites-tab"], [data-e2e="user-favorites-tab"]', liked: '[data-e2e="liked-tab"], [data-e2e="user-liked-tab"]' }[name];
        const el = sel && document.querySelector(sel);
        if (el) { el.click(); post({ kind: 'log', msg: 'clicked tab ' + name }); return true; }
        post({ kind: 'log', msg: 'tab not found ' + name }); return false;
      };

      // Never let the page play video/audio — we only want the JSON.
      const mute = () => document.querySelectorAll('video').forEach(v => { try { v.muted = true; v.pause(); v.autoplay = false; } catch (e) {} });
      new MutationObserver(mute).observe(document.documentElement, { childList: true, subtree: true });
      post({ kind: 'log', msg: 'hooks installed' });
    })();
    """#
}
