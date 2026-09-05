import AppKit
import WebKit

/// Host window for `window.open` / OAuth popups.
///
/// Popups must reuse the configuration handed over by WebKit, otherwise the
/// opener relationship (and therefore the sign-in callback) is lost.
final class PopupWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private let onClose: (PopupWindowController) -> Void

    init(
        configuration: WKWebViewConfiguration,
        windowFeatures: WKWindowFeatures,
        onClose: @escaping (PopupWindowController) -> Void
    ) {
        self.onClose = onClose

        let width = windowFeatures.width?.doubleValue ?? 520
        let height = windowFeatures.height?.doubleValue ?? 640
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)

        window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ChatGPT"
        window.contentView = webView
        window.center()

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.delegate = self
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        window.title = webView.url?.host ?? "ChatGPT"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        window.title = webView.title?.isEmpty == false ? webView.title! : (webView.url?.host ?? "ChatGPT")
    }

    func webViewDidClose(_ webView: WKWebView) {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        onClose(self)
    }
}
