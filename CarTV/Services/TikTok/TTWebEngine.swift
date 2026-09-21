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
            cfg.allowsInlineMediaPlayback = true                    // inline (not fullscreen) so it can't grab the session
            cfg.allowsAirPlayForMediaPlayback = false
            cfg.allowsPictureInPictureMediaPlayback = false
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
        let kind: String
        switch currentFeed {
        case .forYou, .following: kind = "fyp"
        case .profile: kind = "post"
        case .saved: kind = "saved"
        case .liked: kind = "liked"
        }
        web.evaluateJavaScript("window.__cartvMore ? window.__cartvMore('\(kind)') : 'no-hook'") { [weak self] r, _ in
            let result = (r as? String) ?? "nil"
            if result == "no-url" {
                if kind == "saved" || kind == "liked" {
                    // Tab hasn't taken yet — click it again; scrolling now would only load more of your posts.
                    self?.web?.evaluateJavaScript("window.__cartvTab && window.__cartvTab('\(kind == "saved" ? "favorites" : "liked")')") { _, _ in }
                } else {
                    // Page hasn't fired its first request yet — nudge it.
                    self?.web?.evaluateJavaScript("window.__cartvScroll && window.__cartvScroll()") { _, _ in }
                }
            } else if result == "end", let self {
                // List exhausted: deliver an empty page so the consumer clears its loading state.
                Task { @MainActor in self.onItems?(self.currentFeed, []) }
            }
            Log.network.debug("TikTok engine: more(\(kind, privacy: .public)) → \(result, privacy: .public)")
        }
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
            case .saved, .liked:
                let name = { if case .saved = currentFeed { return "favorites" } else { return "liked" } }()
                // The SPA renders the tab bar late; retry until the click lands.
                var clicked = false
                for _ in 0..<12 {
                    if let ok = try? await webView.evaluateJavaScript("window.__cartvTab ? window.__cartvTab('\(name)') : false") as? Bool, ok { clicked = true; break }
                    try? await Task.sleep(for: .milliseconds(400))
                }
                Log.network.info("TikTok engine: \(name, privacy: .public) tab \(clicked ? "selected" : "NOT FOUND", privacy: .public)")
                pendingScrolls = 0
                return   // the tab click fires the first list request itself
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

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Keep the engine on tiktok.com; if it tries to go to /login the session died.
        if let url = navigationAction.request.url, url.path.hasPrefix("/login") {
            Task { @MainActor in AppEnvironment.shared.tiktok.sessionExpired() }
            decisionHandler(.cancel)
            return
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
            // Route strictly by endpoint. The profile page opens on its Videos tab and
            // fires /post/item_list (your own posts) before we switch tabs — that must
            // never be filed as Saved or Liked.
            let feed: Feed
            if url.contains("/api/user/collect/item_list") || url.contains("favorite_item_list") {
                guard case .saved = currentFeed else { return }
                feed = currentFeed
            } else if url.contains("/api/favorite/item_list") || url.contains("/api/user/favorite") {
                guard case .liked = currentFeed else { return }
                feed = currentFeed
            } else if url.contains("/api/post/item_list") {
                guard case .profile = currentFeed else { return }   // own posts while on Saved/Liked → drop
                feed = currentFeed
            } else if url.contains("/api/recommend/") {
                feed = url.contains("from_page=following") ? .following : .forYou
            } else {
                return
            }
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
          if (wanted(u)) { remember(u); res.clone().text().then(t => { if (t && t.length > 2) { noteCursor(u, t); post({ kind: 'items', url: u, body: t }); } }); }
        } catch (e) {}
        return res;
      };

      // XHR
      const _open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (m, u) { this.__cartvURL = u; return _open.apply(this, arguments); };
      const _send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function () {
        this.addEventListener('load', function () {
          try { if (wanted(this.__cartvURL || '')) { remember(this.__cartvURL);
                  if (this.responseText && this.responseText.length > 2) { noteCursor(this.__cartvURL, this.responseText); post({ kind: 'items', url: this.__cartvURL, body: this.responseText }); } } } catch (e) {}
        });
        return _send.apply(this, arguments);
      };

      // Scroll to trigger the next page. TikTok's feed container varies; scroll every scrollable.
      // The web FYP snaps one video per step and only fetches more near the end of
      // what it holds. So advance like a user: ArrowDown / wheel, several times, with
      // pauses, until a new item_list lands (or we give up).
      // Feed paging. Each /recommend/item_list call returns a fresh batch — no cursor.
      // The signature is over the query, not the clock, so a URL the page signed stays
      // valid for minutes. So: remember the last signed URL per endpoint, and when
      // asked for more, re-fetch it from inside the page (same origin, same cookies)
      // instead of coaxing the page to scroll. Fresh msToken is substituted each time.
      window.__cartvLastURL = window.__cartvLastURL || {};
      window.__cartvCursor = window.__cartvCursor || {};
      const kindOf = (u) => /recommend\/item_list/.test(u) ? 'fyp' : /post\/item_list/.test(u) ? 'post' : /favorite\/item_list|user\/favorite/.test(u) ? 'liked' : /user\/collect|favorite_item_list/.test(u) ? 'saved' : null;
      const remember = (u) => { try { const k = kindOf(u); if (k) window.__cartvLastURL[k] = u; } catch (e) {} };
      // Cursor lists (profile tabs) tell us when they're exhausted; the FYP never is.
      const noteCursor = (u, t) => { try { const k = kindOf(u); if (!k || k === 'fyp') return; const j = JSON.parse(t);
        window.__cartvCursor[k] = { cursor: String(j.cursor ?? ''), hasMore: j.hasMore !== false && j.has_more !== false }; } catch (e) {} };
      let inflight = false;
      window.__cartvMore = async function (kind) {
        kind = kind || 'fyp';
        if (kind !== 'fyp') {
          if (!window.__cartvLastURL[kind]) return 'no-url';
          // Profile grids page with a cursor that's inside the signed query, so we can't
          // rewrite it. Scroll the grid to its end instead: the page's own observer fires
          // the next signed request and the hook captures it.
          const c = window.__cartvCursor[kind];
          if (c && !c.hasMore) return 'end';
          try { const h = Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);
                window.scrollTo({ top: h, behavior: 'instant' });
                setTimeout(() => window.scrollTo({ top: h + 4000, behavior: 'instant' }), 120);
                setTimeout(() => window.scrollBy({ top: -200, behavior: 'instant' }), 260);
                setTimeout(() => window.scrollTo({ top: document.body.scrollHeight + 4000, behavior: 'instant' }), 420); } catch (e) {}
          return 'scrolled';
        }
        if (inflight) return 'busy';
        const u = window.__cartvLastURL.fyp;
        if (!u) return 'no-url';
        inflight = true;
        try {
          // Re-fetch the exact URL the page signed: each call returns a fresh ranked batch.
          const r = await _fetch(u, { credentials: 'include', headers: { 'accept': 'application/json, text/plain, */*' } });
          const t = await r.text();
          if (t && t.length > 2) { post({ kind: 'items', url: u, body: t }); return 'ok:' + t.length; }
          return 'empty';
        } catch (e) { return 'err:' + e; } finally { inflight = false; }
      };
      // Fallback for the very first batch on a fresh page (no URL remembered yet): scroll once.
      window.__cartvScroll = function () {
        try { window.scrollBy({ top: window.innerHeight, behavior: 'instant' });
              document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', code: 'ArrowDown', keyCode: 40, which: 40, bubbles: true })); } catch (e) {}
      };

      // Select a profile tab. data-e2e names have drifted over time, so fall back to
      // matching the tab's text/aria-label inside the profile tab bar.
      window.__cartvTab = function (name) {
        const bySel = { favorites: '[data-e2e="favorites-tab"], [data-e2e="user-favorites-tab"], [data-e2e="profile-favorites-tab"]',
                        liked:     '[data-e2e="liked-tab"], [data-e2e="user-liked-tab"], [data-e2e="profile-liked-tab"]' }[name];
        const words = name === 'favorites' ? ['favorites', 'favourites', 'saved'] : ['liked'];
        let el = bySel && document.querySelector(bySel);
        if (!el) {
          const cands = Array.from(document.querySelectorAll('[role="tab"], [class*="PTabItem"], [class*="TabItem"], p[class*="Tab"], div[class*="Tab"] > p'));
          el = cands.find(e => { const t = ((e.textContent || '') + ' ' + (e.getAttribute('aria-label') || '')).trim().toLowerCase();
                                 return t.length < 24 && words.some(w => t === w || t.startsWith(w)); });
        }
        if (!el) { post({ kind: 'log', msg: 'tab not found ' + name }); return false; }
        const selected = el.getAttribute('aria-selected') === 'true' || /active|selected/i.test(el.className || '');
        if (!selected) { el.click(); el.dispatchEvent(new MouseEvent('click', { bubbles: true })); }
        post({ kind: 'log', msg: (selected ? 'already on tab ' : 'clicked tab ') + name });
        return true;
      };

      // Never let the page play video/audio — we only want the JSON.
      const mute = () => document.querySelectorAll('video').forEach(v => { try { v.muted = true; v.pause(); v.autoplay = false; } catch (e) {} });
      new MutationObserver(mute).observe(document.documentElement, { childList: true, subtree: true });
      post({ kind: 'log', msg: 'hooks installed' });
    })();
    """#
}
