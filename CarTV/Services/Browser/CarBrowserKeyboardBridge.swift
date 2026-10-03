import Foundation
import WebKit

struct BrowserKeyboardRequest: Identifiable {
    let id = UUID()
    let value: String
    let placeholder: String
    let secure: Bool
    var searchDestination: BrowserDestination? = nil
}

/// WebKit retains its message handler; the handler only weakly references the session.
@MainActor
final class CarBrowserKeyboardBridge: NSObject, WKScriptMessageHandler {
    private weak var session: BrowserSession?
    init(session: BrowserSession) { self.session = session }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard session?.ownsWebView(message.webView) == true else { return }
        guard let body = message.body as? [String: Any], let value = body["value"] as? String else { return }
        session?.requestKeyboard(BrowserKeyboardRequest(
            value: value, placeholder: body["placeholder"] as? String ?? "Type here",
            secure: body["secure"] as? Bool ?? false,
            searchDestination: body["youtubeSearch"] as? Bool == true ? .youtube : nil
        ), frame: message.frameInfo)
    }

    static let script = #"""
    (() => {
        let target = null;
        function editable(node) {
            if (!(node instanceof Element)) return null;
            const field = node.closest('input, textarea, [contenteditable]:not([contenteditable="false"])');
            if (!field || field.disabled || field.readOnly) return null;
            if (field.tagName === 'INPUT' && !['text','search','url','email','tel','password','number'].includes(field.type)) return null;
            return field;
        }
        function open(field) {
            target = field;
            field.blur();
            window.webkit.messageHandlers.carTVKeyboard.postMessage({
                value: field.isContentEditable ? field.textContent : field.value,
                placeholder: field.placeholder || field.getAttribute('aria-label') || 'Type here',
                secure: field.type === 'password',
                youtubeSearch: /(^|\.)youtube\.com$/.test(location.hostname) &&
                    (field.type === 'search' || field.name === 'search_query' || /search/i.test(field.getAttribute('aria-label') || ''))
            });
        }
        document.addEventListener('pointerdown', event => {
            const field = editable(event.target);
            if (!field) return;
            event.preventDefault();
            open(field);
        }, true);
        document.addEventListener('focusin', event => {
            const field = editable(event.target);
            if (field) open(field);
        }, true);
        window.__carTVSetInput = value => {
            if (!target || !target.isConnected) return;
            if (target.isContentEditable) target.textContent = value;
            else {
                const prototype = target.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                const setter = Object.getOwnPropertyDescriptor(prototype, 'value').set;
                setter.call(target, value);
            }
            target.dispatchEvent(new Event('input', { bubbles: true }));
        };
        window.__carTVSubmitInput = () => {
            if (!target || !target.isConnected) return;
            const field = target;
            field.dispatchEvent(new Event('change', { bubbles: true }));
            const enter = new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true });
            const handled = !field.dispatchEvent(enter);
            field.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
            if (!handled && field.form) field.form.requestSubmit();
            field.blur();
        };
    })();
    """#
}
