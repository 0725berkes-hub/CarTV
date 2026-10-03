import Foundation
import WebKit

@MainActor
final class BrowserPageBridge: NSObject, WKScriptMessageHandler {
    private weak var session: BrowserSession?
    init(session: BrowserSession) { self.session = session }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard session?.ownsWebView(message.webView) == true else { return }
        if let event = message.body as? String { session?.handlePageEvent(event) }
        else if let body = message.body as? [String: Any] {
            if body["event"] as? String == "youtube-search-target" {
                session?.updateYouTubeSearchTarget(body["rect"] as? [String: Double])
            } else if body["event"] as? String == "media-failure" {
                session?.reportMediaFailure(body["reason"] as? String ?? "unknown",
                    position: body["position"] as? Double ?? 0,
                    readyState: body["readyState"] as? Int ?? 0,
                    errorCode: body["errorCode"] as? Int ?? 0)
            }
        }
    }

    // Independent of media setup: search must still work if a site's player setup fails.
    static let searchScript = #"""
    (() => {
        if (!/(^|\.)youtube\.com$/.test(location.hostname)) return;
        const selector = '.topbar-button-search-button, .mobile-topbar-header-search-button, ytm-search-button-renderer, #search-icon-legacy, button[aria-label="Search"], button[aria-label="Search YouTube"], button[title="Search"]';
        const headerSelector = 'ytm-header, ytm-header-bar, ytm-mobile-topbar-renderer, #masthead-container, ytd-masthead';
        const trackedSelector = headerSelector + ', [role="dialog"], ytm-menu-popup-renderer, ytm-bottom-sheet-renderer';
        const contentSelector = '#movie_player, ytd-rich-grid-renderer, ytd-item-section-renderer, ytd-watch-next-secondary-results-renderer, ytd-playlist-panel-renderer';
        const post = value => window.webkit.messageHandlers.carTVPage.postMessage(value);
        let lastTarget = '';
        let queued = false;
        const isFullscreen = () => !!(document.fullscreenElement || document.webkitFullscreenElement ||
            document.documentElement.hasAttribute('data-cartv-fullscreen'));
        function reportTarget() {
            queued = false;
            if (!window.__carTVUsesCarKeyboard) return;
            let rect = null;
            if (!isFullscreen()) {
                for (const header of document.querySelectorAll(headerSelector)) {
                    for (const button of header.querySelectorAll(selector)) {
                        const box = button.getBoundingClientRect();
                        if (box.width <= 0 || box.height <= 0 || box.right <= 0 || box.bottom <= 0 || box.left >= innerWidth || box.top >= innerHeight) continue;
                        const hit = document.elementFromPoint(Math.max(0, Math.min(innerWidth - 1, box.left + box.width / 2)),
                            Math.max(0, Math.min(innerHeight - 1, box.top + box.height / 2)));
                        // Skip hidden duplicate headers and site dialogs above the search icon.
                        if (hit && (button.contains(hit) || hit.contains(button))) {
                            rect = { x: box.left / innerWidth, y: box.top / innerHeight, width: box.width / innerWidth, height: box.height / innerHeight };
                            break;
                        }
                    }
                    if (rect) break;
                }
            }
            const key = JSON.stringify(rect);
            if (key !== lastTarget) { lastTarget = key; post({ event: 'youtube-search-target', rect }); }
        }
        const refresh = () => {
            if (queued) return;
            // Header geometry is irrelevant in fullscreen; let YouTube animate
            // without adding a layout read or animation-frame callback of our own.
            if (isFullscreen()) {
                if (lastTarget !== 'null') {
                    lastTarget = 'null'; post({ event: 'youtube-search-target', rect: null });
                }
                return;
            }
            queued = true;
            requestAnimationFrame(reportTarget);
        };
        // Capture early, before the website focuses and immediately blurs its search field.
        // Pointer release handles touch; click also handles rotary/keyboard activation.
        let lastActivation = -Infinity;
        const open = event => {
            const node = event.target instanceof Element ? event.target : event.target?.parentElement;
            const button = node?.closest(selector);
            if (!button || !button.closest(headerSelector)) return;
            event.preventDefault(); event.stopImmediatePropagation();
            const now = Date.now();
            if (now - lastActivation < 500) return;
            lastActivation = now;
            post('youtube-search');
        };
        window.addEventListener('pointerup', open, true);
        window.addEventListener('click', open, true);
        // The phone uses normal web hit testing. Only CarPlay needs a native
        // search target, so don't monitor the phone's page for its geometry.
        if (!window.__carTVUsesCarKeyboard) return;
        window.addEventListener('resize', refresh);
        document.addEventListener('scroll', event => {
            // Scrolling recommendations or a playlist cannot move the page header.
            if ([document, document.body, document.documentElement].includes(event.target)) refresh();
        }, { capture: true, passive: true });
        document.addEventListener('fullscreenchange', refresh);
        document.addEventListener('webkitfullscreenchange', refresh);
        document.addEventListener('yt-navigate-finish', refresh);
        document.addEventListener('DOMContentLoaded', refresh, { once: true });
        new MutationObserver(records => {
            if (isFullscreen()) return;
            if (records.some(record => {
                if (record.type === 'attributes')
                    return record.target === document.documentElement || !!record.target.closest?.(trackedSelector);
                if (record.type !== 'childList') return false;
                if (record.target === document.body || record.target === document.documentElement ||
                    record.target.closest?.(trackedSelector)) return true;
                const nodes = [...record.addedNodes, ...record.removedNodes];
                if (nodes.some(node => node.matches?.(trackedSelector))) return true;
                // New thumbnails and player controls don't contain the header.
                // Skip recursive queries through every lazy-loaded video tile.
                if (record.target.closest?.(contentSelector)) return false;
                return nodes.some(node => node.querySelector?.(trackedSelector));
            })) refresh();
        }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'style', 'hidden', 'data-cartv-fullscreen'] });
        refresh();
    })();
    """#

    static let script = #"""
    (() => {
        const isYouTube = /(^|\.)youtube\.com$/.test(location.hostname);
        const post = value => window.webkit.messageHandlers.carTVPage.postMessage(value);
        const videoForPage = () => document.querySelector('#player-container-id video, #movie_player video, video');
        const blur = () => { if (document.activeElement instanceof HTMLElement) document.activeElement.blur(); };
        document.addEventListener('submit', () => { blur(); post('submit'); }, true);
        document.addEventListener('keydown', event => {
            if (event.key === 'Enter' && !event.isComposing && event.target.tagName !== 'TEXTAREA')
                setTimeout(() => { blur(); post('submit'); }, 0);
        }, true);
        document.addEventListener('dblclick', event => {
            if (!(event.target instanceof Element) || !event.target.closest('#player-container-id, #movie_player')) event.preventDefault();
        }, { passive: false });

        // Capture only for CarPlay background audio; fullscreen stays in WebKit.
        window.__carTVCaptureMedia = () => {
            const video = videoForPage();
            if (!isYouTube || !video || video.ended) return null;
            return { pageURL: location.href,
                mediaURL: video.currentSrc || video.src || '', position: video.currentTime || 0,
                duration: Number.isFinite(video.duration) ? video.duration : 0, isLive: video.duration === Infinity,
                title: document.querySelector('h1')?.textContent?.trim() || document.title,
                userAgent: navigator.userAgent };
        };
        // YouTube and other desktop sites own fullscreen, exit and miniplayer APIs.
        // Do not redirect container fullscreen into Apple's native video player.

        // Observe actual fullscreen; WebKit and YouTube own the APIs, video and controls.
        let fullscreen = false, pictureInPicture = false;
        function fullscreenChanged() {
            const video = videoForPage();
            const pip = !!(document.pictureInPictureElement || video?.webkitPresentationMode === 'picture-in-picture');
            if (pip !== pictureInPicture) { pictureInPicture = pip; post(pip ? 'pip-enter' : 'pip-exit'); }
            const next = !!(document.fullscreenElement || document.webkitFullscreenElement ||
                video?.webkitDisplayingFullscreen || video?.webkitPresentationMode === 'fullscreen');
            if (next === fullscreen) return;
            fullscreen = next;
            document.documentElement.toggleAttribute('data-cartv-fullscreen', fullscreen);
            post(fullscreen ? 'fullscreen-enter' : 'fullscreen-exit');
        }
        for (const event of ['fullscreenchange', 'webkitfullscreenchange', 'webkitbeginfullscreen', 'webkitendfullscreen', 'webkitpresentationmodechanged', 'enterpictureinpicture', 'leavepictureinpicture'])
            document.addEventListener(event, fullscreenChanged, true);

        // A tap on the playing picture hides website controls. An explicit pause
        // button remains fully owned by YouTube, including keyboard/media controls.
        let pictureTap = null;
        function backgroundVideo(node) {
            if (!isYouTube || !(node instanceof Element) ||
                node.closest('button, a, input, [role="button"], .player-control-play-pause-icon, .ytp-play-button, .ytp-progress-bar, .player-controls-progress-bar')) return null;
            if (!node.matches('video, #player-control-overlay, .player-controls-background, .player-controls-middle, .player-controls-content, .fullscreen-controls, .html5-video-container')) return null;
            return node.closest('#player-container-id, #movie_player')?.querySelector('video');
        }
        window.addEventListener('pointerdown', event => {
            const video = backgroundVideo(event.target);
            pictureTap = video && !video.paused && !video.ended ? { video, source: video.currentSrc, time: Date.now() } : null;
        }, { capture: true, passive: true });
        window.addEventListener('click', event => {
            const video = backgroundVideo(event.target);
            const tap = pictureTap; pictureTap = null;
            if (!video || !((tap?.video === video && Date.now() - tap.time < 1000) || !video.paused && !video.ended)) return;
            const source = tap?.video === video ? tap.source : video.currentSrc;
            setTimeout(() => {
                if (video.isConnected && video.currentSrc === source && video.paused && !video.ended)
                    video.play().catch(() => {});
            }, 0);
        }, true);

        let healthTimer = null;
        let lastPosition = 0, lastAdvance = 0;
        function stopHealthCheck() { if (healthTimer !== null) clearInterval(healthTimer); healthTimer = null; }
        function mediaFailure(reason, video) {
            stopHealthCheck();
            post({ event: 'media-failure', reason, position: video?.currentTime || 0,
                readyState: video?.readyState || 0, errorCode: video?.error?.code || 0 });
        }
        function watchProgress(video) {
            stopHealthCheck(); lastPosition = video.currentTime; lastAdvance = Date.now();
            healthTimer = setInterval(() => {
                if (!video.isConnected || video.ended) { stopHealthCheck(); return; }
                if (video.paused || video.seeking || document.hidden || video.readyState < 3 || video.playbackRate === 0) {
                    lastAdvance = Date.now(); return;
                }
                if (Math.abs(video.currentTime - lastPosition) > 0.05) { lastPosition = video.currentTime; lastAdvance = Date.now(); }
                else if (Date.now() - lastAdvance > 15000) mediaFailure('decoder-not-advancing', video);
            }, 1000);
        }
        document.addEventListener('play', event => { if (event.target instanceof HTMLVideoElement) post('play'); }, true);
        document.addEventListener('playing', event => {
            if (event.target instanceof HTMLVideoElement) { post('playing'); watchProgress(event.target); }
        }, true);
        document.addEventListener('pause', event => {
            if (event.target instanceof HTMLVideoElement) { stopHealthCheck(); post('pause'); }
        }, true);
        document.addEventListener('ended', event => { if (event.target instanceof HTMLVideoElement) { stopHealthCheck(); post('pause'); } }, true);
        document.addEventListener('error', event => {
            if (event.target instanceof HTMLVideoElement) mediaFailure('media-element-error', event.target);
        }, true);

        // Resume only on returning to a paused session or explicit recovery.
        let resumeObserver = null, resumeTimeout = null;
        function cancelPendingResume() {
            resumeObserver?.disconnect(); resumeObserver = null;
            if (resumeTimeout !== null) clearTimeout(resumeTimeout);
            resumeTimeout = null;
        }
        window.__carTVResumeMedia = (position = 0) => {
            cancelPendingResume();
            const resume = () => {
                const video = videoForPage();
                if (!video) return false;
                cancelPendingResume();
                if (Number.isFinite(position) && position > 0) {
                    const seek = () => { try { video.currentTime = position; } catch (_) {} };
                    if (video.readyState >= 1) seek(); else video.addEventListener('loadedmetadata', seek, { once: true });
                }
                video.play().catch(() => {});
                return true;
            };
            if (!resume()) {
                resumeObserver = new MutationObserver(resume);
                resumeObserver.observe(document.documentElement, { childList: true, subtree: true });
                resumeTimeout = setTimeout(cancelPendingResume, 10000);
            }
        };
        window.__carTVPauseMedia = () => {
            cancelPendingResume(); stopHealthCheck(); document.querySelectorAll('video').forEach(video => video.pause());
        };
        window.__carTVRestoreMedia = (position, resume) => {
            cancelPendingResume();
            const video = videoForPage();
            if (!video) return;
            const restore = () => {
                if (Number.isFinite(position) && position >= 0) {
                    try { video.currentTime = position; } catch (_) {}
                }
                if (resume) video.play().catch(() => {}); else video.pause();
            };
            if (video.readyState >= 1) restore(); else video.addEventListener('loadedmetadata', restore, { once: true });
        };

        function prepare() {
            if (!document.head) return;
            if (window === window.top) {
                let viewport = document.querySelector('meta[name="viewport"]');
                if (!viewport) { viewport = document.createElement('meta'); viewport.name = 'viewport'; document.head.appendChild(viewport); }
                const car = !!window.__carTVUsesCarKeyboard;
                const replaced = car
                    ? /^(width|height|initial-scale|minimum-scale|maximum-scale|user-scalable)\s*=/i
                    : /^(initial-scale|minimum-scale|maximum-scale|user-scalable)\s*=/i;
                const extra = (viewport.content || '').split(/[,;]/).map(value => value.trim()).filter(value =>
                    value && !replaced.test(value));
                // Give WebKit a desktop layout width and let it infer the fit scale.
                // pageZoom shrinks content without giving the page this wider viewport.
                const sizing = car ? ['width=1200', 'user-scalable=no']
                    : ['initial-scale=1', 'maximum-scale=1', 'user-scalable=no'];
                viewport.content = [...extra, ...sizing].join(', ');
            }
            if (!document.getElementById('cartv-browser-style')) {
                const style = document.createElement('style'); style.id = 'cartv-browser-style';
                style.textContent = `
                    html { touch-action: manipulation; }
                    button, [role="button"], a { touch-action: manipulation; }
                    input, textarea { font-size: max(16px, 1em) !important; }
                    html[data-cartv-car] * { scrollbar-width: none; }
                    html[data-cartv-car] *::-webkit-scrollbar { display: none; }
                    /* Keep YouTube's desktop player, with a slightly narrower sidebar. */
                    html[data-cartv-car]:not([data-cartv-fullscreen]) ytd-watch-flexy[is-two-columns_]:not([fullscreen]) {
                        --ytd-watch-flexy-sidebar-width: 320px;
                    }
                    /* Give the existing desktop recommendation column its own scroll area. */
                    html[data-cartv-car]:not([data-cartv-fullscreen]) ytd-watch-flexy[is-two-columns_]:not([fullscreen]) #secondary {
                        width: 320px !important;
                        min-width: 0 !important;
                        flex: 0 0 320px;
                        align-self: flex-start;
                        position: sticky;
                        top: var(--ytd-masthead-height, 56px);
                        max-height: calc(100dvh - var(--ytd-masthead-height, 56px) - 16px);
                        min-height: 0;
                        overflow-y: auto;
                        overscroll-behavior-y: contain;
                    }
                    html[data-cartv-car] ytd-playlist-panel-renderer #items {
                        overscroll-behavior-y: contain;
                    }
                    html[data-cartv-block-ads] :is(ytd-ad-slot-renderer, ytm-ad-slot-renderer, ytd-display-ad-renderer,
                        ytm-promoted-sparkles-web-renderer, ytd-promoted-sparkles-web-renderer,
                        ytm-promoted-video-renderer, ytd-promoted-video-renderer, .ytp-ad-overlay-container,
                        [data-e2e="feed-ad-container"], [data-e2e="search-ad-container"]) { display: none !important; }
                    /* Hiding only the advert leaves its outer grid tile occupying a slot. */
                    html[data-cartv-block-ads] :is(ytd-rich-item-renderer, ytd-item-section-renderer):has(
                        ytd-ad-slot-renderer, ytd-display-ad-renderer, ytd-promoted-sparkles-web-renderer,
                        ytd-promoted-video-renderer):not(:has(ytd-rich-grid-media, ytd-video-renderer,
                        ytd-playlist-renderer, ytd-channel-renderer)) { display: none !important; }
                `;
                document.head.appendChild(style);
            }
            document.documentElement.toggleAttribute('data-cartv-block-ads', window.__carTVBlockAds !== false);
            document.documentElement.toggleAttribute('data-cartv-car', !!window.__carTVUsesCarKeyboard);
        }
        // Scope the TikTok observer to install prompts. YouTube gets no layout observer.
        if (/(^|\.)tiktok\.com$/.test(location.hostname)) {
            let queued = false;
            const dismissPrompt = () => {
                queued = false;
                for (const title of document.querySelectorAll('h1, h2, h3, [role="heading"]')) {
                    if (!/^Get the full app experience$/i.test(title.textContent.trim())) continue;
                    for (let modal = title.parentElement, depth = 0; modal && depth < 6; modal = modal.parentElement, depth++) {
                        const cancel = Array.from(modal.querySelectorAll('button, a, [role="button"], span')).find(node =>
                            !node.children.length && /^Not now$/i.test(node.textContent.trim()));
                        if (cancel) { (cancel.closest('button, a, [role="button"]') || cancel).click(); break; }
                    }
                }
            };
            new MutationObserver(records => {
                if (!queued && records.some(record => record.addedNodes.length)) {
                    queued = true; setTimeout(dismissPrompt, 200);
                }
            }).observe(document.documentElement, { childList: true, subtree: true });
        }
        // Change chrome only when crossing a direction threshold on the main page.
        let lastScroll = 0, distance = 0, direction = 0, hidden = false, chromeChangedAt = -Infinity;
        window.__carTVSetChromeHidden = value => {
            hidden = !!value; distance = 0; chromeChangedAt = Date.now();
            lastScroll = Math.max(0, window.scrollY || document.documentElement.scrollTop || 0);
        };
        document.addEventListener('scroll', event => {
            if (fullscreen || ![document, document.body, document.documentElement].includes(event.target)) return;
            const current = Math.max(0, window.scrollY || document.documentElement.scrollTop || 0);
            const delta = current - lastScroll; lastScroll = current;
            // Ignore the scroll adjustment caused by our own toolbar height change.
            if (Date.now() - chromeChangedAt < 300) return;
            if (Math.sign(delta) !== direction) { distance = 0; direction = Math.sign(delta); }
            distance += Math.abs(delta);
            const next = current < 8 ? false : distance > 40 ? direction > 0 : hidden;
            if (next !== hidden) { hidden = next; distance = 0; chromeChangedAt = Date.now(); post(hidden ? 'chrome-hide' : 'chrome-show'); }
        }, { passive: true });
        document.addEventListener('DOMContentLoaded', prepare, { once: true });
        if (document.readyState !== 'loading') prepare();
    })();
    """#
}
