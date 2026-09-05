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
    private var policy: NavigationPolicy
    private var popups: [PopupWindowController] = []
    private var errorOverlay: ErrorOverlayView?

    private var pending: [() -> Void] = []
    private let pendingLimit = 16
    private(set) var isPageReady = false

    private var navigationStartedAt: CFAbsoluteTime?
    private(set) var lastLoadSeconds: Double?
    private(set) var lastCommitSeconds: Double?

    private var homeURL: URL
    /// Remembered so retry-after-failure reloads the page that failed instead
    /// of silently falling back to the home page.
    private var lastRequestedURL: URL?

    init(settings: AppSettings) {
        self.homeURL = settings.resolvedHomeURL
        self.policy = ChatWebController.makePolicy(homeURL: settings.resolvedHomeURL)
        super.init()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = userContentController
        // Append to the stock UA instead of pinning a Safari version that rots.
        configuration.applicationNameForUserAgent = "ChatGPTBar/\(AppInfo.shortVersion)"
        configuration.preferences.isElementFullscreenEnabled = true

        installScripts(settings: settings)

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

    /// The configured home page must stay in the panel even when it is not on
    /// the default allow list.
    private static func makePolicy(homeURL: URL) -> NavigationPolicy {
        var suffixes = NavigationPolicy.defaultAllowedHostSuffixes
        if let host = homeURL.host, !host.isEmpty, !suffixes.contains(host) {
            suffixes.append(host)
        }
        return NavigationPolicy(allowedHostSuffixes: suffixes)
    }

    // MARK: - Loading

    func loadHome(_ url: URL? = nil) {
        if let url {
            homeURL = url
            policy = ChatWebController.makePolicy(homeURL: url)
        }
        hideErrorOverlay()
        lastRequestedURL = homeURL
        webView.load(URLRequest(url: homeURL))
    }

    func reload() {
        hideErrorOverlay()
        if webView.url != nil {
            webView.reload()
        } else if let last = lastRequestedURL {
            webView.load(URLRequest(url: last))
        } else {
            loadHome()
        }
    }

    func openCurrentPageInBrowser() {
        NSWorkspace.shared.open(webView.url ?? homeURL)
    }

    /// Loads an arbitrary page (diagnostics); keeps the configured home intact.
    func load(url: URL) {
        if let host = url.host, !policy.isAllowedHost(host) {
            policy = NavigationPolicy(allowedHostSuffixes: policy.allowedHostSuffixes + [host])
        }
        hideErrorOverlay()
        isPageReady = false
        lastRequestedURL = url
        webView.load(URLRequest(url: url))
    }

    /// Rebuilds the injected scripts after selectors or rendering options change.
    func rebuildScripts(settings: AppSettings) {
        installScripts(settings: settings)
        isPageReady = false
        webView.reload()
    }

    private func installScripts(settings: AppSettings) {
        userContentController.removeAllUserScripts()
        userContentController.addUserScript(
            WKUserScript(
                source: BridgeScript.source(selectors: settings.selectors),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        guard settings.longConversationOptimization else { return }
        userContentController.addUserScript(
            WKUserScript(
                source: RenderTweaks.source(selectors: settings.selectors),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
    }

    // MARK: - Bridge plumbing

    /// Queues work until the document is committed (not until the load event):
    /// a heavy conversation can keep loading subresources for a minute, and
    /// waiting for `didFinish` would stall every insert until then.
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

    // MARK: - Diagnostics

    func metrics(completion: @escaping (BridgeResponse) -> Void) {
        call("return window.\(BridgeScript.globalName).metrics();", completion: completion)
    }

    func clearComposer(completion: ((BridgeResponse) -> Void)? = nil) {
        call("return window.\(BridgeScript.globalName).clear();") { response in completion?(response) }
    }

    /// The send button only exists while the composer has content, so probing
    /// it requires typing first.
    func probeComposer(completion: @escaping ([String: Any]) -> Void) {
        insert(text: "chatgpt-bar selector probe", mode: .replace, submit: false) { [weak self] inserted in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.probeSelectors { probe in
                    self.dumpDOMCandidates { dump in
                        self.clearComposer { cleared in
                            completion([
                                "inserted": inserted.isOK,
                                "insertError": inserted.error ?? "",
                                "cleared": cleared.isOK,
                                "selectorProbe": probe,
                                "domCandidates": dump
                            ])
                        }
                    }
                }
            }
        }
    }

    /// Samples frame gaps during a deterministic scroll sweep, then reports
    /// jank plus page metrics.
    func samplePerformance(duration: TimeInterval, completion: @escaping ([String: Any]) -> Void) {
        call("return window.\(BridgeScript.globalName).perfStart();") { [weak self] started in
            guard let self else { return }
            guard started.isOK else {
                completion(["error": BridgeErrorText.describe(started.error)])
                return
            }
            self.call(
                "return await window.\(BridgeScript.globalName).scrollBench(durationMs);",
                arguments: ["durationMs": Int(duration * 1000)]
            ) { scrolled in
                self.call("return window.\(BridgeScript.globalName).perfStop();") { stopped in
                    self.metrics { metrics in
                        var result: [String: Any] = [:]
                        result["jank"] = stopped.value ?? ["error": BridgeErrorText.describe(stopped.error)]
                        result["page"] = metrics.value ?? ["error": BridgeErrorText.describe(metrics.error)]
                        result["scroll"] = scrolled.value ?? ["error": BridgeErrorText.describe(scrolled.error)]
                        if let seconds = self.lastLoadSeconds {
                            result["uiLoadSeconds"] = (seconds * 1000).rounded() / 1000
                        }
                        completion(result)
                    }
                }
            }
        }
    }

    /// Waits until the conversation is actually rendered, then samples and probes.
    /// The page may already be loading from `--url` at launch.
    func runDiagnostics(url: URL?, settle: TimeInterval, completion: @escaping ([String: Any]) -> Void) {
        if let url, webView.url != url { load(url: url) }
        measurePass(settle: settle, includeProbes: true, completion: completion)
    }

    /// One measurement pass: wait for commit, wait for the conversation to be
    /// rendered, then sample scroll jank. Both A/B passes use this so the
    /// numbers are comparable.
    func measurePass(settle: TimeInterval, includeProbes: Bool, completion: @escaping ([String: Any]) -> Void) {
        let startedAt = CFAbsoluteTimeGetCurrent()
        waitUntilReady(deadline: Date().addingTimeInterval(90)) { [weak self] ready in
            guard let self else { return }
            guard ready else {
                completion(["error": "document was not committed within 90s"])
                return
            }
            self.waitForTurns(deadline: Date().addingTimeInterval(90)) { turns in
                let timeToTurns = CFAbsoluteTimeGetCurrent() - startedAt
                self.samplePerformance(duration: settle) { sample in
                    var report = sample
                    report["timeToFirstTurnSeconds"] = (timeToTurns * 1000).rounded() / 1000
                    report["turnsWhenRendered"] = turns
                    if let commit = self.lastCommitSeconds {
                        report["documentCommitSeconds"] = (commit * 1000).rounded() / 1000
                    }
                    guard includeProbes else {
                        completion(report)
                        return
                    }
                    self.probeSelectors { probe in
                        self.dumpDOMCandidates { dump in
                            report["selectorProbe"] = probe
                            report["domCandidates"] = dump
                            completion(report)
                        }
                    }
                }
            }
        }
    }

    private func waitForTurns(deadline: Date, completion: @escaping (Int) -> Void) {
        metrics { [weak self] response in
            let turns = (response.value?["turns"] as? Int) ?? 0
            if turns > 0 || Date() >= deadline {
                completion(turns)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self?.waitForTurns(deadline: deadline, completion: completion)
            }
        }
    }

    /// Reloads with `settings` applied (not persisted) and waits for commit.
    func reapplyScriptsAndWait(settings: AppSettings, completion: @escaping (Bool) -> Void) {
        rebuildScripts(settings: settings)
        waitUntilReady(deadline: Date().addingTimeInterval(60), completion: completion)
    }

    private func waitUntilReady(deadline: Date, completion: @escaping (Bool) -> Void) {
        if isPageReady {
            completion(true)
            return
        }
        guard Date() < deadline else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitUntilReady(deadline: deadline, completion: completion)
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
        navigationStartedAt = CFAbsoluteTimeGetCurrent()
    }

    /// The document exists from here on, so the injected bridge is live.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hideErrorOverlay()
        if let start = navigationStartedAt {
            lastCommitSeconds = CFAbsoluteTimeGetCurrent() - start
        }
        isPageReady = true
        flushPending()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideErrorOverlay()
        isPageReady = true
        if let start = navigationStartedAt {
            lastLoadSeconds = CFAbsoluteTimeGetCurrent() - start
            navigationStartedAt = nil
        }
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
        let nsError = error as NSError
        // Not real failures: navigations we cancelled for an external link, and
        // navigations WebKit turned into a download ("frame load interrupted").
        let isBenign = (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            || (nsError.domain == "WebKitErrorDomain" && (nsError.code == 102 || nsError.code == 204))
        if isBenign {
            // The previous page is still on screen, so keep serving bridge calls.
            if webView.url != nil {
                isPageReady = true
                flushPending()
            }
            return
        }

        isPageReady = false
        pending.removeAll()
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
