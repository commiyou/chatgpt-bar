import AppKit
import WebKit
import ChatGPTBarKit

/// Owns the WKWebView, its delegates and the JS bridge calls.
///
/// The prototype had no navigation or UI delegate at all, which silently broke
/// external links, OAuth popups, file uploads, downloads, JS dialogs and load
/// errors. All of those are handled here.
final class ChatWebController: NSObject {
    let containerView = NSView()
    private(set) var webView: WKWebView!

    private let userContentController = WKUserContentController()
    private let policy = NavigationPolicy()
    private var popups: [PopupWindowController] = []
    private var errorOverlay: ErrorOverlayView?

    private var pending: [() -> Void] = []
    private let pendingLimit = 16
    private(set) var isPageReady = false

    private var homeURL: URL

    init(settings: AppSettings) {
        self.homeURL = settings.resolvedHomeURL
        super.init()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = userContentController
        // Append to the stock UA instead of pinning a Safari version that rots.
        configuration.applicationNameForUserAgent = "ChatGPTBar/\(AppInfo.shortVersion)"
        configuration.preferences.isElementFullscreenEnabled = true

        installBridge(selectors: settings.selectors)

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        webView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: containerView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
    }

    // MARK: - Loading

    func loadHome(_ url: URL? = nil) {
        if let url { homeURL = url }
        hideErrorOverlay()
        webView.load(URLRequest(url: homeURL))
    }

    func reload() {
        hideErrorOverlay()
        if webView.url == nil {
            loadHome()
        } else {
            webView.reload()
        }
    }

    func openCurrentPageInBrowser() {
        NSWorkspace.shared.open(webView.url ?? homeURL)
    }

    /// Rebuilds the injected bridge after the selectors change.
    func rebuildBridge(selectors: SelectorSet) {
        installBridge(selectors: selectors)
        isPageReady = false
        webView.reload()
    }

    private func installBridge(selectors: SelectorSet) {
        userContentController.removeAllUserScripts()
        userContentController.addUserScript(
            WKUserScript(
                source: BridgeScript.source(selectors: selectors),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
    }

    // MARK: - Bridge plumbing

    /// Queues work until the first navigation finishes, replacing the
    /// prototype's fixed 0.4s guess.
    private func whenReady(_ block: @escaping () -> Void) {
        if isPageReady {
            block()
            return
        }
        if pending.count >= pendingLimit { pending.removeFirst() }
        pending.append(block)
    }

    private func flushPending() {
        let queued = pending
        pending.removeAll()
        queued.forEach { $0() }
    }

    private func call(
        _ body: String,
        arguments: [String: Any] = [:],
        completion: @escaping (BridgeResponse) -> Void
    ) {
        whenReady { [weak self] in
            guard let self else { return }
            let wrapped = """
            if (!window.\(BridgeScript.globalName)) { return { ok: false, error: 'bridge_missing' }; }
            \(body)
            """
            self.webView.callAsyncJavaScript(wrapped, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    completion(BridgeResponse.parse(value))
                case .failure(let error):
                    completion(BridgeResponse(isOK: false, error: "js_error", detail: error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Bridge actions

    func insert(text: String, mode: PasteMode, submit: Bool, completion: ((BridgeResponse) -> Void)? = nil) {
        call(
            "return await window.\(BridgeScript.globalName).insert(text, mode, submitAfter);",
            arguments: ["text": text, "mode": mode.rawValue, "submitAfter": submit]
        ) { response in
            if !response.isOK {
                Feedback.shared.toast("插入失败：\(BridgeErrorText.describe(response.error))", kind: .failure)
            } else if submit, response.bool("submitted") == false {
                let reason = BridgeErrorText.describe(response.value?["submitError"] as? String)
                Feedback.shared.toast("已插入，但发送失败：\(reason)", kind: .failure)
            }
            completion?(response)
        }
    }

    func newChat() {
        call("return window.\(BridgeScript.globalName).newChat();") { response in
            if !response.isOK {
                Feedback.shared.toast("New Chat 失败：\(BridgeErrorText.describe(response.error))", kind: .failure)
            }
        }
    }

    func newTempChat() {
        call("return window.\(BridgeScript.globalName).tempChat();") { response in
            guard response.isOK else {
                Feedback.shared.toast("Temp Chat 失败：\(BridgeErrorText.describe(response.error))", kind: .failure)
                return
            }
            if response.string("strategy") == "navigate" {
                Feedback.shared.toast("未找到 Temp Chat 按钮，已改用 ?temporary-chat=true 链接")
            }
        }
    }

    /// Copies the last answer natively: no dependency on the page's own
    /// English-only "Copy message" button.
    func copyLastResponse() {
        call("return window.\(BridgeScript.globalName).lastResponse();") { response in
            guard response.isOK, let text = response.string("text"), !text.isEmpty else {
                Feedback.shared.toast("复制失败：\(BridgeErrorText.describe(response.error))", kind: .failure)
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            Feedback.shared.toast("已复制最后一条回复（\(text.count) 字）")
        }
    }

    func probeSelectors(completion: @escaping (String) -> Void) {
        call("return window.\(BridgeScript.globalName).probe();") { response in
            guard response.isOK, let results = response.array("results") else {
                completion("探测失败：\(BridgeErrorText.describe(response.error))")
                return
            }
            var lines: [String] = []
            if let url = response.string("url") { lines.append("URL: \(url)\n") }
            for item in results {
                let key = item["key"] as? String ?? "?"
                let selector = item["selector"] as? String ?? "?"
                let found = item["found"] as? Bool ?? false
                if let error = item["error"] as? String {
                    lines.append("ERR   \(key): \(selector)  (\(error))")
                } else {
                    lines.append("\(found ? "OK   " : "MISS ")\(key): \(selector)")
                }
            }
            completion(lines.joined(separator: "\n"))
        }
    }

    func dumpDOMCandidates(completion: @escaping (String) -> Void) {
        call("return window.\(BridgeScript.globalName).dump();") { response in
            guard response.isOK, let text = response.string("text") else {
                completion("Dump 失败：\(BridgeErrorText.describe(response.error))")
                return
            }
            completion(text)
        }
    }

    // MARK: - Error overlay

    private func showErrorOverlay(message: String) {
        hideErrorOverlay()
        let overlay = ErrorOverlayView(message: message) { [weak self] in
            self?.reload()
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: containerView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        errorOverlay = overlay
    }

    private func hideErrorOverlay() {
        errorOverlay?.removeFromSuperview()
        errorOverlay = nil
    }
}

// MARK: - WKNavigationDelegate

extension ChatWebController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        switch policy.decide(url: navigationAction.request.url, isMainFrame: isMainFrame) {
        case .allowInPanel:
            decisionHandler(.allow)
        case .openExternally:
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                Feedback.shared.toast("已在默认浏览器打开外部链接")
            }
            decisionHandler(.cancel)
        case .block:
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // Anything WebKit cannot render becomes a download instead of a blank page.
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isPageReady = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideErrorOverlay()
        isPageReady = true
        flushPending()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isPageReady = false
        Feedback.shared.toast("网页进程已退出，正在重新加载", kind: .failure)
        loadHome()
    }

    private func handleLoadFailure(_ error: Error) {
        isPageReady = false
        pending.removeAll()
        let nsError = error as NSError
        // Cancelled navigations (our own external-link redirects) are not failures.
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        showErrorOverlay(message: nsError.localizedDescription)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
}

// MARK: - WKUIDelegate

extension ChatWebController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Required for OAuth sign-in popups; without it `target="_blank"` and
        // provider login windows are silently dropped.
        let popup = PopupWindowController(configuration: configuration, windowFeatures: windowFeatures) { [weak self] controller in
            self?.popups.removeAll { $0 === controller }
        }
        popups.append(popup)
        popup.show()
        return popup.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.first(where: { $0.webView === webView })?.close()
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ChatGPT"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ChatGPT"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "取消")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        let alert = NSAlert()
        alert.messageText = "ChatGPT"
        alert.informativeText = prompt
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "取消")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        // Voice input needs the microphone, but only for the allowed hosts.
        decisionHandler(policy.isAllowedHost(origin.host) ? .grant : .deny)
    }
}

// MARK: - WKDownloadDelegate

extension ChatWebController: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var target = downloads.appendingPathComponent(suggestedFilename)
        var index = 1
        let ext = target.pathExtension
        let base = target.deletingPathExtension().lastPathComponent
        while FileManager.default.fileExists(atPath: target.path) {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            target = downloads.appendingPathComponent(name)
            index += 1
        }
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        Feedback.shared.toast("下载完成：\(download.progress.fileURL?.lastPathComponent ?? "文件")")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Feedback.shared.toast("下载失败：\(error.localizedDescription)", kind: .failure)
    }
}

// MARK: - Error overlay view

private final class ErrorOverlayView: NSView {
    private let retry: () -> Void

    init(message: String, retry: @escaping () -> Void) {
        self.retry = retry
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "wifi.exclamationmark", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 32, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: "页面加载失败")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let detail = NSTextField(wrappingLabelWithString: message)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 320

        let button = NSButton(title: "重新加载", target: self, action: #selector(handleRetry))
        button.keyEquivalent = "\r"

        let stack = NSStackView(views: [icon, title, detail, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func handleRetry() { retry() }
}
