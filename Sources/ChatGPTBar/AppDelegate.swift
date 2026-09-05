import AppKit
import Network
import WebKit
import ChatGPTBarKit

/// Reads from this app's defaults domain, falling back to the prototype's
/// domain so an existing install keeps its settings.
///
/// The bundle id had to change: the prototype shipped `com.local.chatgptbar`,
/// and while two bundles claim the same id, Launch Services routes Services and
/// the URL scheme to whichever bundle it resolved first.
final class UserDefaultsStore: KeyValueStore {
    static let legacySuite = "com.local.chatgptbar"

    private let defaults: UserDefaults
    private let legacy: UserDefaults?

    init(defaults: UserDefaults = .standard, legacySuite: String? = UserDefaultsStore.legacySuite) {
        self.defaults = defaults
        self.legacy = legacySuite.flatMap { suite in
            Bundle.main.bundleIdentifier == suite ? nil : UserDefaults(suiteName: suite)
        }
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key) ?? legacy?.data(forKey: key)
    }

    func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    func object(forKey key: String) -> Any? {
        defaults.object(forKey: key) ?? legacy?.object(forKey: key)
    }

    func removeObject(forKey key: String) { defaults.removeObject(forKey: key) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SettingsStore(store: UserDefaultsStore())

    private var webController: ChatWebController!
    private var panelController: PanelController!
    private var statusItemController: StatusItemController!
    private var settingsController: SettingsWindowController!
    private var shortcutRouter: ShortcutRouter!

    private var settings: AppSettings { store.settings }
    private let launchOptions = LaunchOptions.parse()

    /// Settings with QA launch overrides applied (not persisted).
    private var effectiveSettings: AppSettings {
        var value = store.settings
        if let force = launchOptions.forceOptimization {
            value.longConversationOptimization = force
        }
        return value
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        applyAppearance(settings.appearance)
        AppLocalization.language = settings.language

        buildMainMenu()
        applyProxy(settings.proxy)

        webController = ChatWebController(settings: effectiveSettings)

        panelController = PanelController(
            content: webController.containerView,
            nonActivating: settings.nonActivating,
            pinned: settings.pinned,
            savedFrame: settings.panelFrame
        )
        panelController.onFrameChange = { [weak self] frame in
            self?.store.update { $0.panelFrame = frame }
        }
        panelController.onPinChange = { [weak self] pinned in
            self?.store.update { $0.pinned = pinned }
            self?.statusItemController.setPinned(pinned)
        }

        shortcutRouter = ShortcutRouter(scopeWindow: { [weak self] in self?.panelController.panel })
        shortcutRouter.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .pin: self.panelController.togglePin()
            case .newChat: self.webController.newChat()
            case .newTempChat: self.webController.newTempChat()
            case .copyLastResponse: self.webController.copyLastResponse()
            }
        }
        shortcutRouter.start()
        updateLocalShortcuts()

        statusItemController = StatusItemController(handlers: StatusItemController.Handlers(
            toggle: { [weak self] in self?.panelController.toggle() },
            togglePin: { [weak self] in self?.panelController.togglePin() },
            newChat: { [weak self] in self?.webController.newChat() },
            newTempChat: { [weak self] in self?.webController.newTempChat() },
            copyLastResponse: { [weak self] in self?.webController.copyLastResponse() },
            reload: { [weak self] in self?.webController.reload() },
            openInBrowser: { [weak self] in self?.webController.openCurrentPageInBrowser() },
            openSettings: { [weak self] in self?.openSettings() },
            quit: { NSApp.terminate(nil) }
        ))
        statusItemController.setPinned(settings.pinned)

        settingsController = SettingsWindowController(environment: SettingsWindowController.Environment(
            currentSettings: { [weak self] in self?.settings ?? AppSettings() },
            apply: { [weak self] draft in self?.apply(draft) ?? [] },
            beginRecording: { [weak self] completion in self?.shortcutRouter.beginRecording(completion: completion) },
            cancelRecording: { [weak self] in self?.shortcutRouter.cancelRecording() },
            probeSelectors: { [weak self] completion in self?.webController.probeSelectors(completion: completion) },
            dumpDOM: { [weak self] completion in self?.webController.dumpDOMCandidates(completion: completion) },
            samplePerformance: { [weak self] seconds, completion in
                self?.webController.samplePerformance(duration: seconds, completion: completion)
            },
            testURLScheme: { [weak self] url in
                self?.application(NSApp, open: [url])
            },
            clearChatWebsiteData: { [weak self] completion in
                guard let self else { return }
                guard Feedback.shared.confirm(
                    title: AppLocalization.text("清除 ChatGPT 网站数据", "Clear ChatGPT Website Data"),
                    message: AppLocalization.text(
                        "这会清除 ChatGPT/OpenAI 在 ChatGPT Bar 中的 Cookie、缓存和本地存储，可能需要重新登录；不会影响应用设置或 Chrome。",
                        "This clears ChatGPT/OpenAI cookies, cache, and local storage in ChatGPT Bar. You may need to sign in again. App settings and Chrome are not affected."
                    ),
                    confirmTitle: AppLocalization.text("清除并重新加载", "Clear & Reload")
                ) else {
                    completion(AppLocalization.text("已取消清除网站数据。", "Website data clear cancelled."))
                    return
                }
                self.webController.clearChatWebsiteData(completion: completion)
            }
        ))

        registerGlobalHotkeyAndReport()

        // Services need an explicit provider; the plist entry alone does nothing.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        if let url = launchOptions.url {
            webController.load(url: url)
        } else {
            webController.loadHome(settings.resolvedHomeURL)
        }
        panelController.show()

        if launchOptions.openSettings {
            settingsController.show(tab: launchOptions.settingsTab)
        }
        if let path = launchOptions.reportPath {
            runDevReport(path: path)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.saveFrameNow()
        shortcutRouter?.stop()
        HotKeyCenter.shared.tearDown()
    }

    // MARK: - Settings application

    /// Applies a settings draft and returns warnings for the Settings UI.
    @discardableResult
    private func apply(_ draft: AppSettings) -> [String] {
        let previous = settings
        store.replace(with: draft)

        var warnings: [String] = []

        if draft.nonActivating != previous.nonActivating {
            panelController.setNonActivating(draft.nonActivating)
        }
        if draft.appearance != previous.appearance {
            applyAppearance(draft.appearance)
        }
        if draft.language != previous.language {
            AppLocalization.language = draft.language
            panelController.refreshLocalizedChrome()
        }
        if draft.proxy != previous.proxy {
            applyProxy(draft.proxy)
            if #available(macOS 14.0, *) {
                webController.reload()
            } else if draft.proxy.enabled {
                warnings.append(AppLocalization.text("当前系统低于 macOS 14，代理设置不会生效。", "On macOS below 14, proxy settings are not supported."))
            }
        }
        if draft.selectors != previous.selectors {
            webController.rebuildScripts(settings: draft)
        } else if draft.longConversationOptimization != previous.longConversationOptimization {
            webController.rebuildScripts(settings: draft)
        }
        if draft.homeURL != previous.homeURL {
            webController.loadHome(draft.resolvedHomeURL)
        }
        if draft.copyLastResponseStrategy != previous.copyLastResponseStrategy {
            webController.updateCopyLastResponseStrategy(draft.copyLastResponseStrategy)
        }

        updateLocalShortcuts()
        if let error = registerGlobalHotkeyAndReport() {
            warnings.append(error)
        }
        return warnings
    }

    @discardableResult
    private func registerGlobalHotkeyAndReport() -> String? {
        let result = HotKeyCenter.shared.register(settings.toggleShortcut) { [weak self] in
            self?.panelController.toggle()
        }
        switch result {
        case .success:
            return nil
        case .failure(let error):
            return error.errorDescription
        }
    }

    private func updateLocalShortcuts() {
        shortcutRouter.update(bindings: [
            (settings.pinShortcut, .pin),
            (settings.newChatShortcut, .newChat),
            (settings.newTempChatShortcut, .newTempChat),
            (settings.copyLastResponseShortcut, .copyLastResponse)
        ])
    }

    /// WKWebView cannot be proxied with environment variables; the only
    /// supported per-app path is `proxyConfigurations` on macOS 14+.
    private func applyProxy(_ proxy: ProxySettings) {
        guard #available(macOS 14.0, *) else { return }
        guard proxy.isComplete, let port = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: proxy.port)) else {
            WKWebsiteDataStore.default().proxyConfigurations = []
            return
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(proxy.host), port: port)
        WKWebsiteDataStore.default().proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: endpoint)]
    }

    private func applyAppearance(_ appearance: AppAppearance) {
        switch appearance {
        case .auto:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    private func runDevReport(path: String) {
        panelController.show()
        panelController.setTemporaryFloating(true)

        let finish: ([String: Any]) -> Void = { [weak self] payload in
            guard let self else { return }
            var output = payload
            output["appVersion"] = AppInfo.shortVersion
            output["settleSeconds"] = self.launchOptions.settle
            FileHandle.standardError.write(Data((DevReportWriter.write(output, to: path) + "\n").utf8))
            self.panelController.setTemporaryFloating(false)
            if self.launchOptions.exitAfterReport { NSApp.terminate(nil) }
        }

        webController.runDiagnostics(url: launchOptions.url, settle: launchOptions.settle) { [weak self] baseline in
            guard let self else { return }
            var payload: [String: Any] = [
                "passA": baseline,
                "passAOptimization": self.effectiveSettings.longConversationOptimization
            ]

            let continueWithAB: () -> Void = {
                guard self.launchOptions.abCompare else {
                    finish(payload)
                    return
                }
                var flipped = self.effectiveSettings
                flipped.longConversationOptimization = !flipped.longConversationOptimization
                self.webController.reapplyScriptsAndWait(settings: flipped) { ready in
                    guard ready else {
                        payload["passBError"] = "second pass did not load"
                        finish(payload)
                        return
                    }
                    self.webController.measurePass(settle: self.launchOptions.settle, includeProbes: false) { second in
                        payload["passB"] = second
                        payload["passBOptimization"] = flipped.longConversationOptimization
                        finish(payload)
                    }
                }
            }

            guard self.launchOptions.probeComposer else {
                continueWithAB()
                return
            }
            self.webController.probeComposer { composer in
                payload["composerProbe"] = composer
                continueWithAB()
            }
        }
    }

    // MARK: - URL scheme

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            do {
                perform(try URLCommandParser.parse(url))
            } catch {
                Feedback.shared.toast(AppLocalization.text("URL 无法执行：\(error)", "URL could not be executed: \(error)"), kind: .failure)
            }
        }
    }

    private func perform(_ command: URLCommand) {
        guard settings.enabledURLCommands.contains(command.schemeCommand) else {
            Feedback.shared.toast(
                AppLocalization.text(
                    "已禁用 URL 命令：\(command.schemeCommand.displayName)",
                    "URL command disabled: \(command.schemeCommand.displayNameEnglish)"
                ),
                kind: .failure
            )
            return
        }
        switch command {
        case .open:
            panelController.show()
        case .newChat:
            webController.newChat()
        case .newTempChat:
            webController.newTempChat()
        case .copyLastResponse:
            webController.copyLastResponse()
        case .paste(let text, let mode, let send, let reveal):
            insertFromExternalSource(text: text, mode: mode, send: send, reveal: reveal, source: "URL Scheme")
        }
    }

    /// Auto-send from an external trigger is confirmed unless explicitly allowed:
    /// any process can open a URL scheme.
    private func insertFromExternalSource(text: String, mode: PasteMode, send: Bool, reveal: Bool, source: String) {
        var shouldSend = send
        if reveal || send {
            panelController.show()
        }
        if send, !settings.allowURLSchemeAutoSend {
            let preview = text.count > 300 ? String(text.prefix(300)) + "…" : text
            shouldSend = Feedback.shared.confirm(
                title: AppLocalization.text("\(source) 请求直接发送", "\(source) requests immediate submission"),
                message: AppLocalization.text("即将向 ChatGPT 发送以下内容：\n\n\(preview)", "The following content will be submitted to ChatGPT:\n\n\(preview)"),
                confirmTitle: AppLocalization.text("发送", "Submit")
            )
        }
        webController.insert(text: text, mode: mode, submit: shouldSend)
    }

    // MARK: - macOS Service

    @objc func sendToChatGPT(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            error?.pointee = AppLocalization.text("没有可用的文本", "No text is available") as NSString
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.insertFromExternalSource(text: text, mode: .append, send: false, reveal: true, source: "Services")
        }
    }

    // MARK: - Main menu

    /// The Edit menu is what makes ⌘C/⌘V/⌘A work inside the web view.
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: AppLocalization.text("设置…", "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: AppLocalization.text("重新加载", "Reload"), action: #selector(reloadPage), keyEquivalent: "r")
        appMenu.addItem(withTitle: AppLocalization.text("在浏览器中打开", "Open in Browser"), action: #selector(openInBrowser), keyEquivalent: "o")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: AppLocalization.text("隐藏面板", "Hide Panel"), action: #selector(hidePanel), keyEquivalent: "w")
        appMenu.addItem(withTitle: AppLocalization.text("退出 \(AppInfo.name)", "Quit \(AppInfo.name)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: AppLocalization.text("编辑", "Edit"))
        editMenu.addItem(withTitle: AppLocalization.text("撤销", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: AppLocalization.text("重做", "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: AppLocalization.text("剪切", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: AppLocalization.text("复制", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: AppLocalization.text("粘贴", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: AppLocalization.text("全选", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func reloadPage() { webController.reload() }
    @objc private func openInBrowser() { webController.openCurrentPageInBrowser() }
    @objc private func hidePanel() { panelController.hide() }
}
