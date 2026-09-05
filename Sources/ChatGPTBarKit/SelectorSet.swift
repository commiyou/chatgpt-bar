import Foundation

public enum SelectorKey: String, CaseIterable, Codable {
    case editor
    case send
    case newChat
    case tempChat
    case assistant
    /// ChatGPT's native Copy action. Used only as a trigger for the optional
    /// page-copy strategy; the bridge never intercepts page clipboard APIs.
    case copyButton
    /// Conversation turn container. Not clicked - used by the long-conversation
    /// rendering optimization and by the perf metrics.
    case turn

    public var displayName: String {
        switch self {
        case .editor: return "Editor"
        case .send: return "Send"
        case .newChat: return "New Chat"
        case .tempChat: return "Temp Chat"
        case .assistant: return "Assistant"
        case .copyButton: return "Copy Button"
        case .turn: return "Turn"
        }
    }

    public var helpText: String {
        switch self {
        case .editor:
            return "用于定位 ChatGPT 输入框，供粘贴、追加、替换和发送前的输入操作使用。优先填写稳定的 id、data-testid 或语义属性，避免依赖易变的 class。"
        case .send:
            return "用于定位发送按钮。按钮通常只在输入框非空时出现；按顺序尝试，全部失配时会回退为向输入框发送 Enter。"
        case .newChat:
            return "用于定位普通新建会话入口。找不到时会回退到站点根路径，因此自定义选择器应尽量指向真正的导航入口。"
        case .tempChat:
            return "用于定位临时会话入口。会话页可能没有按钮，找不到时会回退到 ?temporary-chat=true。"
        case .assistant:
            return "用于定位助手回复容器，供“复制最后一条回复”提取 Markdown，也用于判断当前页面是否已有回复。"
        case .copyButton:
            return "用于可选的 GPT 原生 Copy 策略，只负责定位并点击最后一条回复附近的 Copy 按钮；不会拦截页面剪贴板 API。"
        case .turn:
            return "用于定位会话轮次容器，仅供长会话渲染优化和性能诊断使用，不参与点击操作。"
        }
    }

    public var helpTextEnglish: String {
        switch self {
        case .editor:
            return "Locates the ChatGPT editor for paste, append, replace, and submit operations. Prefer stable id, data-testid, or semantic attributes over volatile classes."
        case .send:
            return "Locates the send button. It usually exists only when the editor is non-empty; if every selector misses, Enter is sent to the editor as a fallback."
        case .newChat:
            return "Locates the normal new-chat entry point. If it misses, navigation falls back to the site root."
        case .tempChat:
            return "Locates the temporary-chat entry point. Conversation pages may not expose a button, so the fallback is ?temporary-chat=true."
        case .assistant:
            return "Locates assistant response containers for Markdown copy and for determining whether a response exists."
        case .copyButton:
            return "Locates ChatGPT's native Copy action for the optional page-copy strategy. It only triggers the button and never intercepts page clipboard APIs."
        case .turn:
            return "Locates conversation turn containers for long-conversation rendering optimization and performance diagnostics only."
        }
    }
}

/// Built-in selectors plus user overrides.
///
/// Only overrides are persisted, so a new app version can ship better built-in
/// selectors without being permanently shadowed by a stale saved copy.
public struct SelectorSet: Equatable {
    public static let builtIn: [SelectorKey: [String]] = [
        .editor: [
            "#prompt-textarea",
            "form div[contenteditable=\"true\"]",
            "div[contenteditable=\"true\"]",
            "textarea"
        ],
        .send: [
            "button[data-testid=\"send-button\"]",
            "button[aria-label=\"Send prompt\"]",
            "button[data-testid=\"composer-send-button\"]",
            "form button[type=\"submit\"]:not([data-testid=\"composer-plus-btn\"])"
        ],
        .newChat: [
            "[data-testid=\"create-new-chat-button\"]",
            "a[aria-label=\"New chat\"]",
            "button[data-testid=\"new-chat-button\"]",
            "nav a[href=\"/\"]"
        ],
        .tempChat: [
            "button[aria-label*=\"Temporary chat\" i]",
            "button[aria-label*=\"temporary chat\" i]",
            "[aria-label*=\"\u{4E34}\u{65F6}\"]",
            "button[data-testid=\"temporary-chat-button\"]",
            "button[data-testid*=\"temporary-chat\" i]"
        ],
        .assistant: [
            "[data-message-author-role=\"assistant\"]"
        ],
        .copyButton: [
            "button[aria-label=\"Copy response\"]",
            "button[aria-label=\"复制回复\"]",
            "button[data-testid=\"copy-turn-action-button\"]",
            "button[data-testid=\"copy-button\"]",
            "button[data-testid^=\"copy-\" i]",
            "button[aria-label=\"Copy\"]",
            "button[aria-label*=\"Copy\" i]",
            "button[aria-label=\"复制\"]",
            "button[aria-label*=\"复制\"]"
        ],
        .turn: [
            "[data-testid^=\"conversation-turn\"]",
            "article[data-testid^=\"conversation-turn\"]"
        ]
    ]

    public private(set) var overrides: [SelectorKey: [String]]

    public init(overrides: [SelectorKey: [String]] = [:]) {
        self.overrides = overrides.filter { !$0.value.isEmpty }
    }

    public func selectors(for key: SelectorKey) -> [String] {
        if let custom = overrides[key], !custom.isEmpty { return custom }
        return SelectorSet.builtIn[key] ?? []
    }

    public var resolved: [SelectorKey: [String]] {
        var out: [SelectorKey: [String]] = [:]
        for key in SelectorKey.allCases { out[key] = selectors(for: key) }
        return out
    }

    public var resolvedJSONObject: [String: [String]] {
        var out: [String: [String]] = [:]
        for (key, value) in resolved { out[key.rawValue] = value }
        return out
    }

    public func isOverridden(_ key: SelectorKey) -> Bool {
        overrides[key]?.isEmpty == false
    }

    /// Sets an override, or clears it when the text resolves to the built-in list.
    public mutating func setOverride(_ key: SelectorKey, text: String) {
        let parsed = SelectorSet.parse(text)
        if parsed.isEmpty || parsed == SelectorSet.builtIn[key] {
            overrides[key] = nil
        } else {
            overrides[key] = parsed
        }
    }

    public mutating func resetAll() {
        overrides = [:]
    }

    /// One selector per line. Commas are *not* separators: `:is(a, b)` is a
    /// single valid CSS selector.
    public static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#!") }
    }

    public static func serialize(_ selectors: [String]) -> String {
        selectors.joined(separator: "\n")
    }
}

extension SelectorSet: Codable {
    private enum CodingKeys: String, CodingKey { case overrides }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([String: [String]].self, forKey: .overrides) ?? [:]
        var mapped: [SelectorKey: [String]] = [:]
        for (key, value) in raw {
            guard let selectorKey = SelectorKey(rawValue: key), !value.isEmpty else { continue }
            mapped[selectorKey] = value
        }
        self.init(overrides: mapped)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var raw: [String: [String]] = [:]
        for (key, value) in overrides { raw[key.rawValue] = value }
        try container.encode(raw, forKey: .overrides)
    }
}
