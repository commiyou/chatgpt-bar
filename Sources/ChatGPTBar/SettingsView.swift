import SwiftUI
import ChatGPTBarKit

enum SettingsTab: String, Hashable, CaseIterable {
    case general, shortcuts, urlScheme, page

    init?(flag: String?) {
        guard let flag, let value = SettingsTab(rawValue: flag) else { return nil }
        self = value
    }
}

enum ShortcutSlot: String, CaseIterable, Identifiable {
    case toggle, pin, newChat, newTempChat, copyLastResponse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggle: return AppLocalization.text("显示 / 隐藏面板", "Show / Hide Panel")
        case .pin: return AppLocalization.text("窗口置顶", "Pin Window")
        case .newChat: return "New Chat"
        case .newTempChat: return "New Temp Chat"
        case .copyLastResponse: return AppLocalization.text("复制最后一条回复", "Copy Last Response")
        }
    }

    var helpText: String {
        switch self {
        case .toggle:
            return AppLocalization.text("全局快捷键，显示或隐藏 ChatGPT Bar 面板.", "Global shortcut to show or hide the ChatGPT Bar panel.")
        case .pin:
            return AppLocalization.text(
                "切换面板的 floating window level。它会覆盖普通窗口，但不会覆盖系统级安全界面或某些全屏独占窗口。",
                "Toggles the floating window level. It stays above normal windows, but not system security UI or some exclusive full-screen windows."
            )
        case .newChat:
            return AppLocalization.text("仅在聊天面板聚焦时生效，创建普通新会话。", "Works only when the chat panel is focused and creates a normal conversation.")
        case .newTempChat:
            return AppLocalization.text("仅在聊天面板聚焦时生效，创建临时会话。", "Works only when the chat panel is focused and creates a temporary conversation.")
        case .copyLastResponse:
            return AppLocalization.text("仅在聊天面板聚焦时生效，按“最后回复复制方式”设置复制最后一条助手回复。", "Works only when the chat panel is focused and follows the selected last-response copy strategy.")
        }
    }

    var isGlobal: Bool { self == .toggle }

    func value(in settings: AppSettings) -> Shortcut? {
        switch self {
        case .toggle: return settings.toggleShortcut
        case .pin: return settings.pinShortcut
        case .newChat: return settings.newChatShortcut
        case .newTempChat: return settings.newTempChatShortcut
        case .copyLastResponse: return settings.copyLastResponseShortcut
        }
    }

    func set(_ value: Shortcut?, in settings: inout AppSettings) {
        switch self {
        case .toggle: settings.toggleShortcut = value
        case .pin: settings.pinShortcut = value
        case .newChat: settings.newChatShortcut = value
        case .newTempChat: settings.newTempChatShortcut = value
        case .copyLastResponse: settings.copyLastResponseShortcut = value
        }
    }
}

struct TextResult: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

/// Draft state for the settings window: edits stay local until Save.
final class SettingsModel: ObservableObject {
    @Published var draft: AppSettings
    @Published var selectorText: [SelectorKey: String] = [:]
    @Published var proxyPort: String = ""
    @Published var warnings: [String] = []
    @Published var recording: ShortcutSlot?
    @Published var result: TextResult?
    @Published var isBusy = false

    let environment: SettingsWindowController.Environment
    var onClose: () -> Void = {}

    var supportsProxy: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    init(environment: SettingsWindowController.Environment) {
        self.environment = environment
        self.draft = environment.currentSettings()
        reload()
    }

    func reload() {
        draft = environment.currentSettings()
        proxyPort = draft.proxy.port > 0 ? String(draft.proxy.port) : ""
        selectorText = Dictionary(
            uniqueKeysWithValues: SelectorKey.allCases.map {
                ($0, SelectorSet.serialize(draft.selectors.selectors(for: $0)))
            }
        )
        warnings = []
        recording = nil
    }

    func binding(for key: SelectorKey) -> Binding<String> {
        Binding(
            get: { self.selectorText[key] ?? "" },
            set: { self.selectorText[key] = $0 }
        )
    }

    func isOverridden(_ key: SelectorKey) -> Bool {
        SelectorSet.parse(selectorText[key] ?? "") != (SelectorSet.builtIn[key] ?? [])
    }

    func record(_ slot: ShortcutSlot) {
        recording = slot
        environment.beginRecording { [weak self] shortcut in
            guard let self else { return }
            self.recording = nil
            guard let shortcut else { return }
            var updated = self.draft
            slot.set(shortcut, in: &updated)
            self.draft = updated
        }
    }

    func clear(_ slot: ShortcutSlot) {
        var updated = draft
        slot.set(nil, in: &updated)
        draft = updated
    }

    func resetSelectors() {
        for key in SelectorKey.allCases {
            selectorText[key] = SelectorSet.serialize(SelectorSet.builtIn[key] ?? [])
        }
    }

    /// Folds the editable strings back into the draft.
    private func collected() -> AppSettings {
        var settings = draft
        settings.homeURL = settings.homeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.homeURL.isEmpty { settings.homeURL = "https://chatgpt.com" }
        settings.proxy.host = settings.proxy.host.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.proxy.port = Int(proxyPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        var selectors = settings.selectors
        for key in SelectorKey.allCases {
            selectors.setOverride(key, text: selectorText[key] ?? "")
        }
        settings.selectors = selectors
        return settings
    }

    @discardableResult
    func apply() -> [String] {
        let settings = collected()
        draft = settings
        warnings = environment.apply(settings)
        return warnings
    }

    func save() {
        if apply().isEmpty { onClose() }
    }

    func cancel() {
        environment.cancelRecording()
        onClose()
    }

    func testSelectors() {
        apply()
        isBusy = true
        environment.probeSelectors { [weak self] text in
            self?.isBusy = false
            self?.result = TextResult(title: AppLocalization.text("选择器检测", "Selector Detection"), body: text)
        }
    }

    func dumpDOM() {
        isBusy = true
        environment.dumpDOM { [weak self] text in
            self?.isBusy = false
            self?.result = TextResult(title: AppLocalization.text("DOM 候选", "DOM Candidates"), body: text)
        }
    }

    func runDiagnostics() {
        isBusy = true
        environment.samplePerformance(6) { [weak self] report in
            self?.isBusy = false
            let body = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\(report)"
            self?.result = TextResult(title: AppLocalization.text("性能诊断（采样 6 秒）", "Performance Diagnostic (6s sample)"), body: body)
        }
    }

    func testURLScheme(_ command: URLSchemeCommand) {
        _ = apply()
        guard draft.enabledURLCommands.contains(command) else {
            result = TextResult(
                title: AppLocalization.text("URL Scheme 测试", "URL Scheme Test"),
                body: AppLocalization.text("该命令当前已禁用，请先打开开关。", "This command is disabled. Enable it first.")
            )
            return
        }
        guard let url = URL(string: command.exampleURL) else { return }
        environment.testURLScheme(url)
        result = TextResult(
            title: AppLocalization.text("URL Scheme 测试", "URL Scheme Test"),
            body: AppLocalization.text(
                "已触发：\(command.exampleURL)\n\n粘贴测试使用 send=0，不会自动发送。",
                "Triggered: \(command.exampleURL)\n\nPaste tests use send=0 and do not auto-submit."
            )
        )
    }

    func copyURLScheme(_ command: URLSchemeCommand) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command.exampleURL, forType: .string)
    }

    func clearChatWebsiteData() {
        isBusy = true
        environment.clearChatWebsiteData { [weak self] message in
            self?.isBusy = false
            self?.result = TextResult(
                title: AppLocalization.text("清除网站数据", "Clear Website Data"),
                body: message
            )
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var selection: SettingsTab

    init(model: SettingsModel, initialTab: SettingsTab = .general) {
        self.model = model
        self._selection = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selection) {
                GeneralTab(model: model)
                    .tabItem { Label(AppLocalization.text("通用", "General"), systemImage: "gearshape") }
                    .tag(SettingsTab.general)
                ShortcutsTab(model: model)
                    .tabItem { Label(AppLocalization.text("快捷键", "Shortcuts"), systemImage: "command") }
                    .tag(SettingsTab.shortcuts)
                URLSchemeTab(model: model)
                    .tabItem { Label("URL Scheme", systemImage: "link") }
                    .tag(SettingsTab.urlScheme)
                PageTab(model: model)
                    .tabItem { Label(AppLocalization.text("页面适配", "Page Adaptation"), systemImage: "curlybraces") }
                    .tag(SettingsTab.page)
            }

            Divider()
            FooterBar(model: model)
        }
        .frame(minWidth: 680, minHeight: 620)
        .sheet(item: $model.result) { result in
            ResultSheet(result: result) { model.result = nil }
        }
    }
}

private struct FooterBar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if !model.warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if model.isBusy { ProgressView().controlSize(.small) }
            Button(AppLocalization.text("取消", "Cancel")) { model.cancel() }
                .keyboardShortcut(.cancelAction)
            Button(AppLocalization.text("保存并应用", "Save & Apply")) { model.save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle(AppLocalization.text("不抢占焦点", "Do not activate app"), isOn: $model.draft.nonActivating)
                LabeledContent(AppLocalization.text("首页地址", "Home URL")) {
                    TextField("", text: $model.draft.homeURL, prompt: Text("https://chatgpt.com"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 300)
                }
            } header: {
                Text(AppLocalization.text("面板", "Panel"))
            } footer: {
                Text(AppLocalization.text(
                    "关闭“不抢占焦点”后，面板会像普通窗口一样激活应用。切换该项会重建窗口。",
                    "When disabled, the panel activates the app like a normal window. Changing this rebuilds the panel."
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(AppLocalization.text("外观", "Appearance"), selection: $model.draft.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                Picker(AppLocalization.text("语言", "Language"), selection: $model.draft.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            } header: {
                    Text(AppLocalization.text("外观与语言", "Appearance & Language"))
            } footer: {
                Text(AppLocalization.text(
                    "外观支持自动、浅色和深色；语言支持跟随系统、简体中文和 English。保存后对新打开的窗口生效。",
                    "Appearance supports Auto, Light, and Dark. Language supports System, Simplified Chinese, and English. Changes apply to newly opened windows."
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(
                    AppLocalization.text("最后回复复制方式", "Last response copy strategy"),
                    selection: $model.draft.copyLastResponseStrategy
                ) {
                    ForEach(CopyLastResponseStrategy.allCases, id: \.self) { strategy in
                        Text(AppLocalization.usesEnglish ? strategy.displayNameEnglish : strategy.displayName)
                            .tag(strategy)
                    }
                }
            } header: {
                Text(AppLocalization.text("复制", "Copy"))
            } footer: {
                Text(AppLocalization.text(
                    "Markdown（getLastResponse）从已渲染的助手回复重建 Markdown；GPT 原生 Copy 会点击页面自己的 Copy 按钮并等待系统剪贴板变化，不会拦截页面 clipboard API。",
                    "Markdown (getLastResponse) rebuilds Markdown from the rendered assistant response. ChatGPT native Copy clicks the page's own Copy button and waits for the system pasteboard without intercepting page clipboard APIs."
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(AppLocalization.text("启用 HTTP CONNECT 代理", "Enable HTTP CONNECT proxy"), isOn: $model.draft.proxy.enabled)
                    .disabled(!model.supportsProxy)
                LabeledContent(AppLocalization.text("地址", "Address")) {
                    HStack(spacing: 8) {
                        TextField("host", text: $model.draft.proxy.host)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                        TextField("port", text: $model.proxyPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }
                .disabled(!model.supportsProxy || !model.draft.proxy.enabled)
            } header: {
                Text(AppLocalization.text("代理", "Proxy"))
            } footer: {
                Text(model.supportsProxy
                     ? AppLocalization.text(
                         "通过 WKWebsiteDataStore.proxyConfigurations 生效，保存后会重新加载页面。",
                         "Uses WKWebsiteDataStore.proxyConfigurations and reloads the page after saving."
                       )
                     : AppLocalization.text(
                         "当前系统低于 macOS 14，WKWebView 无法按应用配置代理，请改用系统代理。",
                         "On macOS versions below 14, WKWebView cannot configure an app proxy. Use the system proxy instead."
                       ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(AppLocalization.text("清除 ChatGPT 网站数据…", "Clear ChatGPT Website Data…")) {
                    model.clearChatWebsiteData()
                }
                .disabled(model.isBusy)
            } header: {
                Text(AppLocalization.text("数据与缓存", "Data & Cache"))
            } footer: {
                Text(AppLocalization.text(
                    "只清除 ChatGPT/OpenAI 在本应用 WKWebView 中的 Cookie、缓存和本地存储，可能需要重新登录；不会清除应用设置，也不会影响 Chrome。",
                    "Clears only ChatGPT/OpenAI cookies, cache, and local storage in this app's WKWebView. You may need to sign in again. App settings and Chrome are not affected."
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct URLSchemeTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Text(AppLocalization.text(
                    "chatgptbar:// 是给其他应用、脚本或自动化工具调用 ChatGPT Bar 的本地 URL Scheme。每个命令都可以单独关闭。",
                    "chatgptbar:// is a local URL Scheme for other apps, scripts, and automations to call ChatGPT Bar. Each command can be disabled independently."
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(AppLocalization.text(
                    "测试按钮会走和外部调用相同的解析与权限链路；粘贴命令固定使用 send=0，避免测试时误发送。",
                    "Test buttons use the same parser and permission path as external calls. Paste tests always use send=0 to avoid accidental submission."
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text(AppLocalization.text("调用说明", "How It Works"))
            }

            Section {
                ForEach(URLSchemeCommand.allCases, id: \.self) { command in
                    VStack(alignment: .leading, spacing: 7) {
                        Toggle(
                            AppLocalization.usesEnglish ? command.displayNameEnglish : command.displayName,
                            isOn: Binding(
                                get: { model.draft.enabledURLCommands.contains(command) },
                                set: { enabled in
                                    if enabled {
                                        model.draft.enabledURLCommands.insert(command)
                                    } else {
                                        model.draft.enabledURLCommands.remove(command)
                                    }
                                }
                            )
                        )
                        .help(AppLocalization.usesEnglish ? command.helpTextEnglish : command.helpText)

                        Text(AppLocalization.usesEnglish ? command.helpTextEnglish : command.helpText)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(command.exampleURL)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(AppLocalization.text("复制命令", "Copy Command")) { model.copyURLScheme(command) }
                                .buttonStyle(.borderless)
                            Button(AppLocalization.text("测试", "Test")) { model.testURLScheme(command) }
                                .disabled(!model.draft.enabledURLCommands.contains(command))
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text(AppLocalization.text("命令列表", "Commands"))
            }

            Section {
                Toggle(
                    AppLocalization.text("允许 chatgptbar:// 免确认直接发送", "Allow chatgptbar:// to submit without confirmation"),
                    isOn: $model.draft.allowURLSchemeAutoSend
                )
            } header: {
                Text(AppLocalization.text("安全", "Security"))
            } footer: {
                Text(AppLocalization.text(
                    "任何进程或网页都能触发 URL Scheme。关闭时，带 send=1 的调用会先弹出确认框并显示待发送内容。这个开关只影响自动发送，不影响 paste 的 send=0 测试。",
                    "Any process or webpage can trigger the URL Scheme. When disabled, send=1 calls show a confirmation with a preview. This only affects auto-submit, not paste tests with send=0."
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutSlot.allCases) { slot in
                    LabeledContent(slot.title) {
                        ShortcutField(model: model, slot: slot)
                    }
                }
            } header: {
                Text(AppLocalization.text("快捷键", "Shortcuts"))
            } footer: {
                Text(AppLocalization.text(
                    "“显示 / 隐藏面板”是全局快捷键，至少需要一个 ⌘ / ⌥ / ⌃；其余仅在聊天面板聚焦时生效。录制时按 Esc 取消。",
                    "Show / Hide Panel is global and requires ⌘, ⌥, or ⌃. Other shortcuts work only when the chat panel is focused. Press Esc to cancel recording."
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutField: View {
    @ObservedObject var model: SettingsModel
    let slot: ShortcutSlot

    private var isRecording: Bool { model.recording == slot }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.record(slot)
            } label: {
                Text(label)
                    .font(.system(.body, design: isRecording ? .default : .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 132)
            }
            .help(slot.helpText)
            .disabled(model.recording != nil && !isRecording)

            Button {
                model.clear(slot)
            } label: {
                Image(systemName: "delete.left")
            }
            .buttonStyle(.borderless)
            .help(AppLocalization.text("清除该快捷键", "Clear this shortcut"))
            .disabled(slot.value(in: model.draft) == nil)
        }
    }

    private var label: String {
        if isRecording { return AppLocalization.text("按下快捷键…", "Press a shortcut…") }
        return slot.value(in: model.draft)?.displayString
            ?? AppLocalization.text("未设置", "Not set")
    }
}

private struct PageTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(SelectorKey.allCases, id: \.self) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(key.displayName)
                                .font(.callout.weight(.medium))
                                .help(AppLocalization.usesEnglish ? key.helpTextEnglish : key.helpText)
                            if model.isOverridden(key) {
                                Text(AppLocalization.text("已修改", "Modified"))
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                            }
                        }
                        SelectorEditor(text: model.binding(for: key))
                            .help(AppLocalization.usesEnglish ? key.helpTextEnglish : key.helpText)
                        Text(AppLocalization.usesEnglish ? key.helpTextEnglish : key.helpText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text(AppLocalization.text("页面选择器", "Page Selectors"))
            } footer: {
                Text(AppLocalization.text(
                    "每行一个 CSS 选择器，按顺序命中第一个；逗号不是分隔符，`:is(a, b)` 是合法写法。发送按钮只在输入框非空时存在，检测前请先在面板里输入几个字。",
                    "Enter one CSS selector per line; the first matching selector wins. Commas are not separators, and :is(a, b) is valid CSS. The send button appears only when the editor has content, so type a few characters before testing."
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 10) {
                    Button(AppLocalization.text("检测选择器", "Test Selectors")) { model.testSelectors() }
                        .help("按当前页面逐个执行每个 CSS 选择器，报告命中、失配或 CSS 语法错误；不会自动替换你的配置。")
                    Button(AppLocalization.text("导出 DOM 候选", "Export DOM Candidates")) { model.dumpDOM() }
                        .help("扫描当前页面的 data-testid、aria-label、消息角色和可编辑节点，生成可用于更新选择器的候选清单。")
                    Spacer()
                    Button(AppLocalization.text("恢复内置默认", "Restore Built-ins")) { model.resetSelectors() }
                }
            }

            Section {
                Text(AppLocalization.text("检测逻辑", "Detection Logic"))
                    .font(.callout.weight(.medium))
                Text(AppLocalization.text(
                    "检测会在当前页面对每个选择器调用 querySelector；找到节点显示 OK，找不到显示 MISS，CSS 语法非法显示 ERR。它只观察当前 DOM，不会点击、发送或修改页面。",
                    "Detection calls querySelector for every selector on the current page. It reports OK, MISS, or ERR for invalid CSS. It only observes the DOM and never clicks, submits, or edits the page."
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(AppLocalization.text("长会话渲染优化（实验性）", "Long-conversation rendering optimization (Experimental)"), isOn: $model.draft.longConversationOptimization)
                Button(AppLocalization.text("运行性能诊断（采样 6 秒）", "Run performance diagnostic (6s sample)")) { model.runDiagnostics() }
            } header: {
                Text(AppLocalization.text("性能", "Performance"))
            } footer: {
                Text(AppLocalization.text(
                    "优化会对视口外的会话轮次跳过布局与绘制。在 49000px、358 个代码块的会话上做过双向 A/B，没有稳定收益，因此默认关闭；卡顿主要来自页面自身渲染。",
                    "Optimization skips layout and paint for off-screen turns. A two-way A/B on a 49,000px conversation with 358 code blocks showed no stable gain, so it is off by default; most jank comes from page rendering."
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SelectorEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: 86)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct ResultSheet: View {
    let result: TextResult
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(result.title).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            ScrollView {
                Text(result.body.isEmpty ? AppLocalization.text("（无内容）", "(empty)") : result.body)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()
            HStack {
                Button(AppLocalization.text("复制到剪贴板", "Copy to Clipboard")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.body, forType: .string)
                }
                Spacer()
                Button(AppLocalization.text("关闭", "Close")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 620, height: 460)
    }
}
