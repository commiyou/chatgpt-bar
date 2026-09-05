import AppKit
import ChatGPTBarKit

/// Settings edit a working copy and only commit on Save, so recording a
/// shortcut is no longer an immediate, irreversible side effect.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    struct Environment {
        var currentSettings: () -> AppSettings
        /// Applies the edited settings and returns human readable warnings.
        var apply: (AppSettings) -> [String]
        var beginRecording: (@escaping (Shortcut?) -> Void) -> Void
        var cancelRecording: () -> Void
        var probeSelectors: (@escaping (String) -> Void) -> Void
        var dumpDOM: (@escaping (String) -> Void) -> Void
    }

    private enum ShortcutSlot: CaseIterable {
        case toggle, pin, newChat, newTempChat, copyLastResponse

        var title: String {
            switch self {
            case .toggle: return "全局开关（Toggle）"
            case .pin: return "窗口置顶（Pin）"
            case .newChat: return "New Chat"
            case .newTempChat: return "New Temp Chat"
            case .copyLastResponse: return "复制最后一条回复"
            }
        }

        var note: String {
            self == .toggle ? "全局生效，需要至少一个 ⌘/⌥/⌃" : "仅在聊天面板聚焦时生效"
        }
    }

    private let environment: Environment
    private var draft: AppSettings
    private var window: NSWindow!
    private var scrollView: NSScrollView!

    private var shortcutButtons: [ShortcutSlot: NSButton] = [:]
    private var selectorEditors: [SelectorKey: NSTextView] = [:]
    private var nonActivatingCheckbox: NSButton!
    private var autoSendCheckbox: NSButton!
    private var homeURLField: NSTextField!
    private var proxyEnabledCheckbox: NSButton!
    private var proxyHostField: NSTextField!
    private var proxyPortField: NSTextField!
    private var warningLabel: NSTextField!

    init(environment: Environment) {
        self.environment = environment
        self.draft = environment.currentSettings()
        super.init()
    }

    func show() {
        if window == nil { build() }
        draft = environment.currentSettings()
        loadDraftIntoControls()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        scrollToTop()
    }

    private func scrollToTop() {
        // The document view is flipped, so the origin is the top edge.
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Build

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addView(sectionTitle("快捷键"), in: .top)
        for slot in ShortcutSlot.allCases {
            stack.addView(shortcutRow(slot), in: .top)
        }

        warningLabel = NSTextField(wrappingLabelWithString: "")
        warningLabel.textColor = .systemOrange
        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.preferredMaxLayoutWidth = 480
        warningLabel.isHidden = true
        stack.addView(warningLabel, in: .top)

        stack.addView(separator(), in: .top)
        stack.addView(sectionTitle("面板行为"), in: .top)

        nonActivatingCheckbox = NSButton(checkboxWithTitle: "不抢占焦点（non-activating panel，切换后重建窗口）", target: nil, action: nil)
        stack.addView(nonActivatingCheckbox, in: .top)

        autoSendCheckbox = NSButton(checkboxWithTitle: "允许 chatgptbar:// 免确认直接发送（有风险）", target: nil, action: nil)
        stack.addView(autoSendCheckbox, in: .top)
        stack.addView(hint("关闭时，来自 URL Scheme 的 send=1 会先弹出确认框，避免任意网页静默用你的账号发消息。"), in: .top)

        homeURLField = NSTextField(string: draft.homeURL)
        homeURLField.placeholderString = "https://chatgpt.com"
        homeURLField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        stack.addView(labeledRow("首页地址", homeURLField), in: .top)

        stack.addView(separator(), in: .top)
        stack.addView(sectionTitle("代理"), in: .top)

        proxyEnabledCheckbox = NSButton(checkboxWithTitle: "启用 HTTP CONNECT 代理", target: nil, action: nil)
        proxyHostField = NSTextField(string: "")
        proxyHostField.placeholderString = "host"
        proxyHostField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        proxyPortField = NSTextField(string: "")
        proxyPortField.placeholderString = "port"
        proxyPortField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        stack.addView(horizontal([proxyEnabledCheckbox, proxyHostField, proxyPortField]), in: .top)

        if #available(macOS 14.0, *) {
            stack.addView(hint("通过 WKWebsiteDataStore.proxyConfigurations 生效，修改后需要重新加载页面。"), in: .top)
        } else {
            proxyEnabledCheckbox.isEnabled = false
            proxyHostField.isEnabled = false
            proxyPortField.isEnabled = false
            stack.addView(hint("当前系统低于 macOS 14，WKWebView 无法按应用配置代理，请改用系统代理。"), in: .top)
        }

        stack.addView(separator(), in: .top)
        stack.addView(sectionTitle("页面选择器"), in: .top)
        stack.addView(hint("每行一个 CSS 选择器，按顺序命中第一个。留空表示使用内置默认值。"), in: .top)

        for key in SelectorKey.allCases {
            let (row, textView) = selectorRow(key)
            selectorEditors[key] = textView
            stack.addView(row, in: .top)
        }

        let testButton = NSButton(title: "检测选择器", target: self, action: #selector(testSelectors))
        let dumpButton = NSButton(title: "导出 DOM 候选", target: self, action: #selector(dumpDOM))
        let resetButton = NSButton(title: "恢复内置默认", target: self, action: #selector(resetSelectors))
        stack.addView(horizontal([testButton, dumpButton, resetButton]), in: .top)

        stack.addView(separator(), in: .top)
        let saveButton = NSButton(title: "保存并应用", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        stack.addView(horizontal([saveButton, cancelButton]), in: .top)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        // A flipped container keeps the form top-aligned; a bare NSStackView as
        // document view starts scrolled to the bottom.
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
        scroll.documentView = documentView
        documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        scrollView = scroll

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(AppInfo.name) 设置"
        window.contentView = scroll
        window.delegate = self
        window.center()
    }

    // MARK: - Rows

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 480
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
        return box
    }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func labeledRow(_ title: String, _ view: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        label.alignment = .right
        return horizontal([label, view])
    }

    private func shortcutRow(_ slot: ShortcutSlot) -> NSStackView {
        let button = NSButton(title: "-", target: self, action: #selector(recordShortcut(_:)))
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        button.identifier = NSUserInterfaceItemIdentifier(String(describing: slot))
        shortcutButtons[slot] = button

        let clear = NSButton(title: "清除", target: self, action: #selector(clearShortcut(_:)))
        clear.identifier = button.identifier

        return horizontal([labeledRow(slot.title, button), clear, hint(slot.note)])
    }

    private func selectorRow(_ key: SelectorKey) -> (NSStackView, NSTextView) {
        let textView = NSTextView()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 62).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 380).isActive = true

        return (labeledRow(key.displayName, scroll), textView)
    }

    // MARK: - Draft <-> controls

    private func loadDraftIntoControls() {
        for slot in ShortcutSlot.allCases {
            shortcutButtons[slot]?.title = shortcut(for: slot)?.displayString ?? "未设置"
        }
        nonActivatingCheckbox.state = draft.nonActivating ? .on : .off
        autoSendCheckbox.state = draft.allowURLSchemeAutoSend ? .on : .off
        homeURLField.stringValue = draft.homeURL
        proxyEnabledCheckbox.state = draft.proxy.enabled ? .on : .off
        proxyHostField.stringValue = draft.proxy.host
        proxyPortField.stringValue = draft.proxy.port > 0 ? String(draft.proxy.port) : ""
        for key in SelectorKey.allCases {
            selectorEditors[key]?.string = SelectorSet.serialize(draft.selectors.selectors(for: key))
            selectorEditors[key]?.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        warningLabel.isHidden = true
    }

    private func collectControlsIntoDraft() {
        draft.nonActivating = nonActivatingCheckbox.state == .on
        draft.allowURLSchemeAutoSend = autoSendCheckbox.state == .on

        let url = homeURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.homeURL = url.isEmpty ? "https://chatgpt.com" : url

        draft.proxy.enabled = proxyEnabledCheckbox.state == .on
        draft.proxy.host = proxyHostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.proxy.port = Int(proxyPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        var selectors = draft.selectors
        for key in SelectorKey.allCases {
            selectors.setOverride(key, text: selectorEditors[key]?.string ?? "")
        }
        draft.selectors = selectors
    }

    private func shortcut(for slot: ShortcutSlot) -> Shortcut? {
        switch slot {
        case .toggle: return draft.toggleShortcut
        case .pin: return draft.pinShortcut
        case .newChat: return draft.newChatShortcut
        case .newTempChat: return draft.newTempChatShortcut
        case .copyLastResponse: return draft.copyLastResponseShortcut
        }
    }

    private func setShortcut(_ value: Shortcut?, for slot: ShortcutSlot) {
        switch slot {
        case .toggle: draft.toggleShortcut = value
        case .pin: draft.pinShortcut = value
        case .newChat: draft.newChatShortcut = value
        case .newTempChat: draft.newTempChatShortcut = value
        case .copyLastResponse: draft.copyLastResponseShortcut = value
        }
        shortcutButtons[slot]?.title = value?.displayString ?? "未设置"
    }

    private func slot(for sender: NSButton) -> ShortcutSlot? {
        ShortcutSlot.allCases.first { String(describing: $0) == sender.identifier?.rawValue }
    }

    // MARK: - Actions

    @objc private func recordShortcut(_ sender: NSButton) {
        guard let slot = slot(for: sender) else { return }
        sender.title = "按下快捷键…（Esc 取消）"
        environment.beginRecording { [weak self] shortcut in
            guard let self else { return }
            if let shortcut {
                self.setShortcut(shortcut, for: slot)
            } else {
                sender.title = self.shortcut(for: slot)?.displayString ?? "未设置"
            }
        }
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        guard let slot = slot(for: sender) else { return }
        setShortcut(nil, for: slot)
    }

    @objc private func resetSelectors() {
        for key in SelectorKey.allCases {
            selectorEditors[key]?.string = SelectorSet.serialize(SelectorSet.builtIn[key] ?? [])
        }
        var selectors = draft.selectors
        selectors.resetAll()
        draft.selectors = selectors
    }

    @objc private func testSelectors() {
        collectControlsIntoDraft()
        // Probe uses the selectors currently injected in the page, so apply first.
        showWarnings(environment.apply(draft))
        environment.probeSelectors { text in
            Feedback.shared.showText(title: "选择器检测", body: text)
        }
    }

    @objc private func dumpDOM() {
        environment.dumpDOM { text in
            Feedback.shared.showText(title: "DOM 候选（data-testid / aria-label / role）", body: text, extraButton: ("复制到剪贴板", {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }))
        }
    }

    @objc private func save() {
        collectControlsIntoDraft()
        let warnings = environment.apply(draft)
        showWarnings(warnings)
        if warnings.isEmpty {
            window.orderOut(nil)
        }
    }

    @objc private func cancel() {
        environment.cancelRecording()
        window.orderOut(nil)
    }

    private func showWarnings(_ warnings: [String]) {
        warningLabel.stringValue = warnings.joined(separator: "\n")
        warningLabel.isHidden = warnings.isEmpty
    }

    func windowWillClose(_ notification: Notification) {
        environment.cancelRecording()
    }
}
