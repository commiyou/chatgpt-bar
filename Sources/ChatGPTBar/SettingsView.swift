import SwiftUI
import ChatGPTBarKit

enum SettingsTab: String, Hashable, CaseIterable {
    case general, shortcuts, page

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
        case .toggle: return "显示 / 隐藏面板"
        case .pin: return "窗口置顶"
        case .newChat: return "New Chat"
        case .newTempChat: return "New Temp Chat"
        case .copyLastResponse: return "复制最后一条回复"
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
            self?.result = TextResult(title: "选择器检测", body: text)
        }
    }

    func dumpDOM() {
        isBusy = true
        environment.dumpDOM { [weak self] text in
            self?.isBusy = false
            self?.result = TextResult(title: "DOM 候选", body: text)
        }
    }

    func runDiagnostics() {
        isBusy = true
        environment.samplePerformance(6) { [weak self] report in
            self?.isBusy = false
            let body = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\(report)"
            self?.result = TextResult(title: "性能诊断（采样 6 秒）", body: body)
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
                    .tabItem { Label("通用", systemImage: "gearshape") }
                    .tag(SettingsTab.general)
                ShortcutsTab(model: model)
                    .tabItem { Label("快捷键", systemImage: "command") }
                    .tag(SettingsTab.shortcuts)
                PageTab(model: model)
                    .tabItem { Label("页面适配", systemImage: "curlybraces") }
                    .tag(SettingsTab.page)
            }

            Divider()
            FooterBar(model: model)
        }
        .frame(minWidth: 600, minHeight: 540)
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
            Button("取消") { model.cancel() }
                .keyboardShortcut(.cancelAction)
            Button("保存并应用") { model.save() }
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
                Toggle("不抢占焦点", isOn: $model.draft.nonActivating)
                LabeledContent("首页地址") {
                    TextField("", text: $model.draft.homeURL, prompt: Text("https://chatgpt.com"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 300)
                }
            } header: {
                Text("面板")
            } footer: {
                Text("关闭“不抢占焦点”后，面板会像普通窗口一样激活应用。切换该项会重建窗口。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("允许 chatgptbar:// 免确认直接发送", isOn: $model.draft.allowURLSchemeAutoSend)
            } header: {
                Text("安全")
            } footer: {
                Text("任何进程或网页都能触发 URL Scheme。关闭时，带 send=1 的调用会先弹出确认框并显示待发送内容。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("启用 HTTP CONNECT 代理", isOn: $model.draft.proxy.enabled)
                    .disabled(!model.supportsProxy)
                LabeledContent("地址") {
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
                Text("代理")
            } footer: {
                Text(model.supportsProxy
                     ? "通过 WKWebsiteDataStore.proxyConfigurations 生效，保存后会重新加载页面。"
                     : "当前系统低于 macOS 14，WKWebView 无法按应用配置代理，请改用系统代理。")
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
                Text("快捷键")
            } footer: {
                Text("“显示 / 隐藏面板”是全局快捷键，至少需要一个 ⌘ / ⌥ / ⌃；其余仅在聊天面板聚焦时生效。录制时按 Esc 取消。")
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
            .disabled(model.recording != nil && !isRecording)

            Button {
                model.clear(slot)
            } label: {
                Image(systemName: "delete.left")
            }
            .buttonStyle(.borderless)
            .help("清除该快捷键")
            .disabled(slot.value(in: model.draft) == nil)
        }
    }

    private var label: String {
        if isRecording { return "按下快捷键…" }
        return slot.value(in: model.draft)?.displayString ?? "未设置"
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
                            if model.isOverridden(key) {
                                Text("已修改")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                            }
                        }
                        SelectorEditor(text: model.binding(for: key))
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("页面选择器")
            } footer: {
                Text("每行一个 CSS 选择器，按顺序命中第一个；逗号不是分隔符，`:is(a, b)` 是合法写法。发送按钮只在输入框非空时存在，检测前请先在面板里输入几个字。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 10) {
                    Button("检测选择器") { model.testSelectors() }
                    Button("导出 DOM 候选") { model.dumpDOM() }
                    Spacer()
                    Button("恢复内置默认") { model.resetSelectors() }
                }
            }

            Section {
                Toggle("长会话渲染优化（实验性）", isOn: $model.draft.longConversationOptimization)
                Button("运行性能诊断（采样 6 秒）") { model.runDiagnostics() }
            } header: {
                Text("性能")
            } footer: {
                Text("优化会对视口外的会话轮次跳过布局与绘制。在 49000px、358 个代码块的会话上做过双向 A/B，没有稳定收益，因此默认关闭；卡顿主要来自页面自身渲染。")
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
                Text(result.body.isEmpty ? "（无内容）" : result.body)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()
            HStack {
                Button("复制到剪贴板") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.body, forType: .string)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 620, height: 460)
    }
}
