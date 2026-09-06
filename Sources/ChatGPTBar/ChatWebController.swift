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
    private var loadingOverlay: LoadingOverlayView?
    private var scheduledReload: DispatchWorkItem?

    private var pending: [() -> Void] = []
    private let pendingLimit = 16
    private(set) var isPageReady = false

    private var navigationStartedAt: CFAbsoluteTime?
    private(set) var lastLoadSeconds: Double?
    private(set) var lastCommitSeconds: Double?

    private var homeURL: URL
    private var copyLastResponseStrategy: CopyLastResponseStrategy
    /// Remembered so retry-after-failure reloads the page that failed instead
    /// of silently falling back to the home page.
    private var lastRequestedURL: URL?

    init(settings: AppSettings) {
        self.homeURL = settings.resolvedHomeURL
        self.copyLastResponseStrategy = settings.copyLastResponseStrategy
        self.policy = ChatWebController.makePolicy(homeURL: settings.resolvedHomeURL)
        super.init()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = userContentController
        // Keep WebKit's stock User-Agent. A custom product suffix changes the
        // device fingerprint without improving compatibility.
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
        scheduledReload?.cancel()
        scheduledReload = nil
        if let url {
            homeURL = url
            policy = ChatWebController.makePolicy(homeURL: url)
        }
        hideErrorOverlay()
        showLoadingOverlay()
        lastRequestedURL = homeURL
        webView.load(URLRequest(url: homeURL))
    }

    func reload() {
        hideErrorOverlay()
        scheduleReload()
    }

    /// Clears only ChatGPT/OpenAI website data owned by this WKWebView store.
    /// App settings and other browsers are untouched.
    func clearChatWebsiteData(completion: @escaping (String) -> Void) {
        let store = WKWebsiteDataStore.default()
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: allTypes) { [weak self] records in
            let targets = records.filter { record in
                let name = record.displayName.lowercased()
                return name.contains("chatgpt")
                    || name.contains("openai")
                    || name.contains("oaistatic")
                    || name.contains("oaiusercontent")
                    || name.contains("auth0")
            }
            store.removeData(ofTypes: allTypes, for: targets) {
                DispatchQueue.main.async {
                    self?.isPageReady = false
                    self?.pending.removeAll()
                    self?.loadHome()
                    completion(AppLocalization.text(
                        "已清除 \(targets.count) 个 ChatGPT/OpenAI 网站数据记录，并重新加载页面。",
                        "Cleared \(targets.count) ChatGPT/OpenAI website data records and reloaded the page."
                    ))
                }
            }
        }
    }

    func openCurrentPageInBrowser() {
        NSWorkspace.shared.open(webView.url ?? homeURL)
    }

    /// Loads an arbitrary page (diagnostics); keeps the configured home intact.
    func load(url: URL) {
        scheduledReload?.cancel()
        scheduledReload = nil
        if let host = url.host, !policy.isAllowedHost(host) {
            policy = NavigationPolicy(allowedHostSuffixes: policy.allowedHostSuffixes + [host])
        }
        hideErrorOverlay()
        showLoadingOverlay()
        isPageReady = false
        lastRequestedURL = url
        webView.load(URLRequest(url: url))
    }

    /// Rebuilds the injected scripts after selectors or rendering options change.
    func rebuildScripts(settings: AppSettings) {
        installScripts(settings: settings)
        isPageReady = false
        showLoadingOverlay()
        scheduleReload()
    }

    /// Updates selectors in the existing page without a navigation. The
    /// document-start script remains the source of truth for a fresh load.
    func updateSelectors(settings: AppSettings, completion: ((Bool) -> Void)? = nil) {
        call(
            "return window.\(BridgeScript.globalName).configure(nextSelectors);",
            arguments: ["nextSelectors": settings.selectors.resolvedJSONObject]
        ) { [weak self] response in
            if !response.isOK {
                self?.rebuildScripts(settings: settings)
            }
            completion?(response.isOK)
        }
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

    /// Coalesce reloads requested by several settings changes in one apply
    /// pass. User-triggered navigations cancel this deferred work.
    private func scheduleReload() {
        isPageReady = false
        showLoadingOverlay()
        scheduledReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduledReload = nil
            if self.webView.url != nil {
                self.webView.reload()
            } else if let last = self.lastRequestedURL {
                self.webView.load(URLRequest(url: last))
            } else {
                self.loadHome()
            }
        }
        scheduledReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
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
                Feedback.shared.toast(AppLocalization.text("插入失败：\(BridgeErrorText.describe(response.error))", "Insert failed: \(BridgeErrorText.describe(response.error))"), kind: .failure)
            } else if submit, response.bool("submitted") == false {
                let reason = BridgeErrorText.describe(response.value?["submitError"] as? String)
                Feedback.shared.toast(AppLocalization.text("已插入，但发送失败：\(reason)", "Inserted, but submit failed: \(reason)"), kind: .failure)
            }
            completion?(response)
        }
    }

    func newChat() {
        call("return window.\(BridgeScript.globalName).newChat();") { response in
            if !response.isOK {
                Feedback.shared.toast(AppLocalization.text("New Chat 失败：\(BridgeErrorText.describe(response.error))", "New Chat failed: \(BridgeErrorText.describe(response.error))"), kind: .failure)
            }
        }
    }

    func newTempChat() {
        call("return window.\(BridgeScript.globalName).tempChat();") { response in
            guard response.isOK else {
                Feedback.shared.toast(AppLocalization.text("Temp Chat 失败：\(BridgeErrorText.describe(response.error))", "Temporary Chat failed: \(BridgeErrorText.describe(response.error))"), kind: .failure)
                return
            }
            if response.string("strategy") == "navigate" {
                Feedback.shared.toast(AppLocalization.text("未找到 Temp Chat 按钮，已改用 ?temporary-chat=true 链接", "Temporary Chat button not found; using ?temporary-chat=true instead"))
            }
        }
    }

    /// Reads the latest assistant response from the rendered page.
    ///
    /// The bridge returns both `markdown` and the legacy `text` key. Keeping
    /// this as a separate operation makes the read path usable by diagnostics
    /// and keeps clipboard writing in the native layer.
    func getLastResponse(completion: @escaping (BridgeResponse) -> Void) {
        call("return window.\(BridgeScript.globalName).getLastResponse();", completion: completion)
    }

    func updateCopyLastResponseStrategy(_ strategy: CopyLastResponseStrategy) {
        copyLastResponseStrategy = strategy
    }

    /// Copies the latest assistant response using the configured strategy.
    ///
    /// Do not intercept `navigator.clipboard`: the page's Copy action can
    /// write a partial/plain-text payload, and wrapping the API changes page
    /// behavior globally. The rendered assistant DOM is the stable source for
    /// this app's Markdown contract.
    func copyLastResponse() {
        if copyLastResponseStrategy == .chatGPT {
            copyUsingChatGPT()
            return
        }
        getLastResponse { [weak self] response in
            guard response.isOK,
                  let markdown = response.string("markdown") ?? response.string("text"),
                  !markdown.isEmpty else {
                Feedback.shared.toast(AppLocalization.text("复制失败：\(BridgeErrorText.describe(response.error))", "Copy failed: \(BridgeErrorText.describe(response.error))"), kind: .failure)
                return
            }
            self?.writeResponseToPasteboard(markdown, strategy: "DOM Markdown")
        }
    }

    /// Triggers the page's own Copy button, then observes the native pasteboard.
    /// This preserves the page result without replacing any page API.
    private func copyUsingChatGPT() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        call("return window.\(BridgeScript.globalName).clickCopyButton();") { [weak self] response in
            guard let self else { return }
            guard response.isOK else {
                Feedback.shared.toast(AppLocalization.text(
                    "GPT 原生 Copy 失败：\(BridgeErrorText.describe(response.error))",
                    "ChatGPT native Copy failed: \(BridgeErrorText.describe(response.error))"
                ), kind: .failure)
                return
            }
            self.waitForPasteboardChange(from: changeCount, deadline: Date().addingTimeInterval(2.0))
        }
    }

    private func waitForPasteboardChange(from previousChangeCount: Int, deadline: Date) {
        let pasteboard = NSPasteboard.general
        let hasContent = pasteboard.string(forType: .string)?.isEmpty == false
            || pasteboard.types?.contains(.html) == true
        if pasteboard.changeCount != previousChangeCount && hasContent {
            Feedback.shared.toast(AppLocalization.text(
                "已复制最后一条回复（GPT 原生 Copy）",
                "Copied the latest response (ChatGPT native Copy)"
            ))
            return
        }
        guard Date() < deadline else {
            Feedback.shared.toast(AppLocalization.text(
                "GPT 原生 Copy 未写入系统剪贴板，请重试。",
                "ChatGPT native Copy did not update the system pasteboard. Try again."
            ), kind: .failure)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForPasteboardChange(from: previousChangeCount, deadline: deadline)
        }
    }

    private func writeResponseToPasteboard(_ text: String, strategy: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Feedback.shared.toast(AppLocalization.text(
            "已复制最后一条回复（\(text.count) 字，\(strategy)）",
            "Copied the latest response (\(text.count) characters, \(strategy))"
        ))
    }

    func probeSelectors(completion: @escaping (String) -> Void) {
        call("return window.\(BridgeScript.globalName).probe();") { response in
            guard response.isOK, let results = response.array("results") else {
                completion(AppLocalization.text("探测失败：\(BridgeErrorText.describe(response.error))", "Selector detection failed: \(BridgeErrorText.describe(response.error))"))
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
                completion(AppLocalization.text("Dump 失败：\(BridgeErrorText.describe(response.error))", "DOM dump failed: \(BridgeErrorText.describe(response.error))"))
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
        call(
            "return await window.\(BridgeScript.globalName).perfRun(durationMs);",
            arguments: ["durationMs": Int(duration * 1000)]
        ) { [weak self] scrolled in
            guard let self else { return }
            self.metrics { metrics in
                var result: [String: Any] = [:]
                let scrollValue = scrolled.value ?? [:]
                result["jank"] = (scrollValue["sample"] as? [String: Any])
                    ?? ["supported": false, "reason": BridgeErrorText.describe(scrolled.error)]
                result["page"] = metrics.value ?? ["error": BridgeErrorText.describe(metrics.error)]
                result["scroll"] = scrollValue
                if let seconds = self.lastLoadSeconds {
                    result["uiLoadSeconds"] = (seconds * 1000).rounded() / 1000
                }
                completion(result)
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
            self.waitForTurns(deadline: Date().addingTimeInterval(30)) { turns in
                let timeToTurns = CFAbsoluteTimeGetCurrent() - startedAt
                self.waitForStableContent(
                    deadline: Date().addingTimeInterval(15)
                ) { stableTurns, stableSeconds, isStable in
                    self.samplePerformance(duration: settle) { sample in
                        var report = sample
                        report["timeToFirstTurnSeconds"] = (timeToTurns * 1000).rounded() / 1000
                        report["turnsWhenRendered"] = turns
                        report["turnsWhenStable"] = stableTurns
                        report["contentStable"] = isStable
                        report["contentStabilityTimedOut"] = !isStable
                        if isStable {
                            report["timeToStableContentSeconds"] = ((timeToTurns + stableSeconds) * 1000).rounded() / 1000
                        }
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
    }

    private func waitForTurns(deadline: Date, completion: @escaping (Int) -> Void) {
        metrics { [weak self] response in
            guard let self else { return }
            let isConversation = response.bool("isConversation") ?? false
            if !isConversation {
                completion(0)
                return
            }
            let turns = (response.value?["turns"] as? Int) ?? 0
            if turns > 0 || Date() >= deadline {
                completion(turns)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.waitForTurns(deadline: deadline, completion: completion)
            }
        }
    }

    private func waitForStableContent(
        deadline: Date,
        completion: @escaping (Int, TimeInterval, Bool) -> Void
    ) {
        let timeoutMs = max(1, Int(deadline.timeIntervalSinceNow * 1000))
        let quietMs = 500
        call(
            "return await window.\(BridgeScript.globalName).waitForContentStable(timeoutMs, quietMs);",
            arguments: ["timeoutMs": timeoutMs, "quietMs": quietMs]
        ) { response in
            guard response.isOK else {
                completion(0, 0, false)
                return
            }
            let turns = response.number("turns").map(Int.init) ?? 0
            let elapsed = (response.number("elapsedMs") ?? 0) / 1000
            completion(turns, elapsed, response.bool("stable") ?? false)
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
        hideLoadingOverlay()
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

    private func showLoadingOverlay() {
        if let loadingOverlay {
            loadingOverlay.startAnimating()
            return
        }
        let overlay = LoadingOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: containerView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        overlay.startAnimating()
        loadingOverlay = overlay
    }

    private func hideLoadingOverlay() {
        loadingOverlay?.stopAnimating()
        loadingOverlay?.removeFromSuperview()
        loadingOverlay = nil
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
                Feedback.shared.toast(AppLocalization.text("已在默认浏览器打开外部链接", "Opened the external link in the default browser"))
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
        showLoadingOverlay()
    }

    /// The document exists from here on, so the injected bridge is live.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hideErrorOverlay()
        hideLoadingOverlay()
        if let start = navigationStartedAt {
            lastCommitSeconds = CFAbsoluteTimeGetCurrent() - start
        }
        isPageReady = true
        flushPending()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideErrorOverlay()
        hideLoadingOverlay()
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
        Feedback.shared.toast(AppLocalization.text("网页进程已退出，正在重新加载", "Web content process exited; reloading"), kind: .failure)
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
                hideLoadingOverlay()
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
        alert.addButton(withTitle: AppLocalization.text("取消", "Cancel"))
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
        alert.addButton(withTitle: AppLocalization.text("取消", "Cancel"))
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
        Feedback.shared.toast(AppLocalization.text("下载完成：\(download.progress.fileURL?.lastPathComponent ?? "文件")", "Download finished: \(download.progress.fileURL?.lastPathComponent ?? "file")"))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Feedback.shared.toast(AppLocalization.text("下载失败：\(error.localizedDescription)", "Download failed: \(error.localizedDescription)"), kind: .failure)
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

        let title = NSTextField(labelWithString: AppLocalization.text("页面加载失败", "Page failed to load"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let detail = NSTextField(wrappingLabelWithString: message)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 320

        let button = NSButton(title: AppLocalization.text("重新加载", "Reload"), target: self, action: #selector(handleRetry))
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

private final class LoadingOverlayView: NSView {
    private let spinner = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true

        let title = NSTextField(labelWithString: AppLocalization.text("正在加载 ChatGPT…", "Loading ChatGPT…"))
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.textColor = .labelColor

        let stack = NSStackView(views: [spinner, title])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startAnimating() {
        spinner.startAnimation(nil)
    }

    func stopAnimating() {
        spinner.stopAnimation(nil)
    }
}
