import Foundation

public enum SelectorKey: String, CaseIterable, Codable {
    case editor
    case send
    case newChat
    case tempChat
    case assistant

    public var displayName: String {
        switch self {
        case .editor: return "Editor"
        case .send: return "Send"
        case .newChat: return "New Chat"
        case .tempChat: return "Temp Chat"
        case .assistant: return "Assistant"
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
            "div[contenteditable=\"true\"][data-virtualkeyboard]",
            "form div[contenteditable=\"true\"]",
            "textarea[data-testid=\"prompt-textarea\"]",
            "div[contenteditable=\"true\"]",
            "textarea"
        ],
        .send: [
            "button[data-testid=\"send-button\"]",
            "button[data-testid=\"composer-send-button\"]",
            "button[aria-label=\"Send prompt\"]",
            "form button[type=\"submit\"]"
        ],
        .newChat: [
            "button[data-testid=\"create-new-chat-button\"]",
            "a[data-testid=\"create-new-chat-button\"]",
            "button[data-testid=\"new-chat-button\"]",
            "a[href=\"/\"][data-discover]",
            "nav a[href=\"/\"]"
        ],
        .tempChat: [
            "button[data-testid=\"temporary-chat-button\"]",
            "button[aria-label*=\"Temporary chat\" i]",
            "[data-testid*=\"temporary-chat\" i]"
        ],
        .assistant: [
            "div[data-message-author-role=\"assistant\"]",
            "[data-message-author-role=\"assistant\"]"
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
