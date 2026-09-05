import AppKit
import Network
import WebKit
import ChatGPTBarKit

final class UserDefaultsStore: KeyValueStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    func object(forKey key: String) -> Any? { defaults.object(forKey: key) }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        buildMainMenu()
        applyProxy(settings.proxy)

        webController = ChatWebController(settings: settings)

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
            dumpDOM: { [weak self] completion in self?.webController.dumpDOMCandidates(completion: completion) }
        ))

        registerGlobalHotkeyAndReport()

        // Services need an explicit provider; the plist entry alone does nothing.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        webController.loadHome(settings.resolvedHomeURL)
        panelController.show()

        if CommandLine.arguments.contains("--settings") {
            openSettings()
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
        if draft.proxy != previous.proxy {
            applyProxy(draft.proxy)
            if #available(macOS 14.0, *) {
                webController.reload()
            } else if draft.proxy.enabled {
                warnings.append("当前系统低于 macOS 14，代理设置不会生效。")
            }
        }
        if draft.selectors != previous.selectors {
            webController.rebuildBridge(selectors: draft.selectors)
        }
        if draft.homeURL != previous.homeURL {
            webController.loadHome(draft.resolvedHomeURL)
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

    @objc private func openSettings() {
        settingsController.show()
    }

    // MARK: - URL scheme

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            do {
                perform(try URLCommandParser.parse(url))
            } catch {
                Feedback.shared.toast("URL 无法执行：\(error)", kind: .failure)
            }
        }
    }

    private func perform(_ command: URLCommand) {
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
                title: "\(source) 请求直接发送",
                message: "即将向 ChatGPT 发送以下内容：\n\n\(preview)",
                confirmTitle: "发送"
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
            error?.pointee = "没有可用的文本" as NSString
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
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "重新加载", action: #selector(reloadPage), keyEquivalent: "r")
        appMenu.addItem(withTitle: "在浏览器中打开", action: #selector(openInBrowser), keyEquivalent: "o")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏面板", action: #selector(hidePanel), keyEquivalent: "w")
        appMenu.addItem(withTitle: "退出 \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func reloadPage() { webController.reload() }
    @objc private func openInBrowser() { webController.openCurrentPageInBrowser() }
    @objc private func hidePanel() { panelController.hide() }
}
