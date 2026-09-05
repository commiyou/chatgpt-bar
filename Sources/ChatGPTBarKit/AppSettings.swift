import Foundation

public struct ProxySettings: Codable, Equatable {
    public var enabled: Bool
    public var host: String
    public var port: Int

    public init(enabled: Bool = false, host: String = "", port: Int = 0) {
        self.enabled = enabled
        self.host = host
        self.port = port
    }

    public var isComplete: Bool {
        enabled && !host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(port)
    }
}

public enum CopyLastResponseStrategy: String, Codable, CaseIterable, Equatable, Hashable {
    case getLastResponse
    case chatGPT

    public var displayName: String {
        switch self {
        case .getLastResponse:
            return "Markdown（getLastResponse）"
        case .chatGPT:
            return "GPT 原生 Copy"
        }
    }

    public var displayNameEnglish: String {
        switch self {
        case .getLastResponse:
            return "Markdown (getLastResponse)"
        case .chatGPT:
            return "ChatGPT native Copy"
        }
    }
}

public struct AppSettings: Codable, Equatable {
    public static let currentSchemaVersion = 5

    public var schemaVersion: Int
    public var homeURL: String
    public var nonActivating: Bool
    public var pinned: Bool
    public var panelFrame: String?

    public var toggleShortcut: Shortcut?
    public var pinShortcut: Shortcut?
    public var newChatShortcut: Shortcut?
    public var newTempChatShortcut: Shortcut?
    public var copyLastResponseShortcut: Shortcut?
    public var copyLastResponseStrategy: CopyLastResponseStrategy

    public var selectors: SelectorSet
    public var proxy: ProxySettings

    /// Applies `content-visibility` to offscreen conversation turns. Opt-in
    /// because it trades find-in-page/scroll-anchoring fidelity for speed.
    public var longConversationOptimization: Bool

    /// `chatgptbar://paste?send=1` submits without asking only when this is on.
    /// Off by default: any process or web page can open a URL scheme.
    public var allowURLSchemeAutoSend: Bool

    /// URL commands are individually disableable. Missing values decode to
    /// the full set so upgrading never silently disables an existing workflow.
    public var enabledURLCommands: Set<URLSchemeCommand>

    public var appearance: AppAppearance
    public var language: AppLanguage

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        homeURL: String = "https://chatgpt.com",
        nonActivating: Bool = true,
        pinned: Bool = false,
        panelFrame: String? = nil,
        toggleShortcut: Shortcut? = .defaultToggle,
        pinShortcut: Shortcut? = .defaultPin,
        newChatShortcut: Shortcut? = .defaultNewChat,
        newTempChatShortcut: Shortcut? = .defaultNewTempChat,
        copyLastResponseShortcut: Shortcut? = .defaultCopyLastResponse,
        copyLastResponseStrategy: CopyLastResponseStrategy = .getLastResponse,
        selectors: SelectorSet = SelectorSet(),
        proxy: ProxySettings = ProxySettings(),
        longConversationOptimization: Bool = false,
        allowURLSchemeAutoSend: Bool = false,
        enabledURLCommands: Set<URLSchemeCommand> = Set(URLSchemeCommand.allCases),
        appearance: AppAppearance = .auto,
        language: AppLanguage = .system
    ) {
        self.schemaVersion = schemaVersion
        self.homeURL = homeURL
        self.nonActivating = nonActivating
        self.pinned = pinned
        self.panelFrame = panelFrame
        self.toggleShortcut = toggleShortcut
        self.pinShortcut = pinShortcut
        self.newChatShortcut = newChatShortcut
        self.newTempChatShortcut = newTempChatShortcut
        self.copyLastResponseShortcut = copyLastResponseShortcut
        self.copyLastResponseStrategy = copyLastResponseStrategy
        self.selectors = selectors
        self.proxy = proxy
        self.longConversationOptimization = longConversationOptimization
        self.allowURLSchemeAutoSend = allowURLSchemeAutoSend
        self.enabledURLCommands = enabledURLCommands
        self.appearance = appearance
        self.language = language
    }

    public var resolvedHomeURL: URL {
        URL(string: homeURL) ?? URL(string: "https://chatgpt.com")!
    }
}

extension AppSettings {
    /// `longConversationOptimization` was added in schema 2, URL command
    /// permissions in schema 3, appearance/language in schema 4, and copy
    /// strategy in schema 5. Older payloads use safe historical defaults.
    enum CodingKeys: String, CodingKey {
        case schemaVersion, homeURL, nonActivating, pinned, panelFrame
        case toggleShortcut, pinShortcut, newChatShortcut, newTempChatShortcut, copyLastResponseShortcut
        case copyLastResponseStrategy
        case selectors, proxy, longConversationOptimization, allowURLSchemeAutoSend, enabledURLCommands
        case appearance, language
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
            homeURL: try container.decodeIfPresent(String.self, forKey: .homeURL) ?? defaults.homeURL,
            nonActivating: try container.decodeIfPresent(Bool.self, forKey: .nonActivating) ?? defaults.nonActivating,
            pinned: try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? defaults.pinned,
            panelFrame: try container.decodeIfPresent(String.self, forKey: .panelFrame),
            toggleShortcut: try container.decodeIfPresent(Shortcut.self, forKey: .toggleShortcut),
            pinShortcut: try container.decodeIfPresent(Shortcut.self, forKey: .pinShortcut),
            newChatShortcut: try container.decodeIfPresent(Shortcut.self, forKey: .newChatShortcut),
            newTempChatShortcut: try container.decodeIfPresent(Shortcut.self, forKey: .newTempChatShortcut),
            copyLastResponseShortcut: try container.decodeIfPresent(Shortcut.self, forKey: .copyLastResponseShortcut),
            copyLastResponseStrategy: try container.decodeIfPresent(CopyLastResponseStrategy.self, forKey: .copyLastResponseStrategy) ?? .getLastResponse,
            selectors: try container.decodeIfPresent(SelectorSet.self, forKey: .selectors) ?? SelectorSet(),
            proxy: try container.decodeIfPresent(ProxySettings.self, forKey: .proxy) ?? ProxySettings(),
            longConversationOptimization: try container.decodeIfPresent(Bool.self, forKey: .longConversationOptimization) ?? false,
            allowURLSchemeAutoSend: try container.decodeIfPresent(Bool.self, forKey: .allowURLSchemeAutoSend) ?? false,
            enabledURLCommands: try container.decodeIfPresent(Set<URLSchemeCommand>.self, forKey: .enabledURLCommands)
                ?? Set(URLSchemeCommand.allCases),
            appearance: try container.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .auto,
            language: try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(homeURL, forKey: .homeURL)
        try container.encode(nonActivating, forKey: .nonActivating)
        try container.encode(pinned, forKey: .pinned)
        try container.encodeIfPresent(panelFrame, forKey: .panelFrame)
        try container.encodeIfPresent(toggleShortcut, forKey: .toggleShortcut)
        try container.encodeIfPresent(pinShortcut, forKey: .pinShortcut)
        try container.encodeIfPresent(newChatShortcut, forKey: .newChatShortcut)
        try container.encodeIfPresent(newTempChatShortcut, forKey: .newTempChatShortcut)
        try container.encodeIfPresent(copyLastResponseShortcut, forKey: .copyLastResponseShortcut)
        try container.encode(copyLastResponseStrategy, forKey: .copyLastResponseStrategy)
        try container.encode(selectors, forKey: .selectors)
        try container.encode(proxy, forKey: .proxy)
        try container.encode(longConversationOptimization, forKey: .longConversationOptimization)
        try container.encode(allowURLSchemeAutoSend, forKey: .allowURLSchemeAutoSend)
        try container.encode(enabledURLCommands, forKey: .enabledURLCommands)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(language, forKey: .language)
    }
}

/// Minimal storage seam so settings logic is testable without UserDefaults.
public protocol KeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    func object(forKey key: String) -> Any?
    func removeObject(forKey key: String)
}

public final class InMemoryStore: KeyValueStore {
    private var storage: [String: Any] = [:]

    public init(seed: [String: Any] = [:]) { storage = seed }

    public func data(forKey key: String) -> Data? { storage[key] as? Data }
    public func set(_ data: Data?, forKey key: String) {
        if let data { storage[key] = data } else { storage.removeValue(forKey: key) }
    }
    public func object(forKey key: String) -> Any? { storage[key] }
    public func removeObject(forKey key: String) { storage.removeValue(forKey: key) }
}

public final class SettingsStore {
    public static let settingsKey = "settings.json"

    private let store: KeyValueStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public private(set) var settings: AppSettings

    public init(store: KeyValueStore) {
        self.store = store
        self.settings = SettingsStore.loadSettings(from: store, decoder: JSONDecoder())
    }

    private static func loadSettings(from store: KeyValueStore, decoder: JSONDecoder) -> AppSettings {
        if let data = store.data(forKey: settingsKey) {
            if let decoded = try? decoder.decode(AppSettings.self, from: data) {
                return migrate(decoded)
            }
            // Corrupt blob: fall back to defaults rather than crashing on launch.
            return AppSettings()
        }
        if let legacy = LegacySettingsMigration.settings(from: store) {
            return legacy
        }
        return AppSettings()
    }

    private static func migrate(_ settings: AppSettings) -> AppSettings {
        var updated = settings
        if updated.schemaVersion < 2 {
            // Schema 1 (and the prototype) persisted the shipped default
            // selectors verbatim, which pinned users to stale values forever.
            updated.selectors = LegacySelectors.dropStaleOverrides(in: updated.selectors)
        }
        if updated.schemaVersion < AppSettings.currentSchemaVersion {
            updated.schemaVersion = AppSettings.currentSchemaVersion
        }
        return updated
    }

    @discardableResult
    public func update(_ mutate: (inout AppSettings) -> Void) -> AppSettings {
        var copy = settings
        mutate(&copy)
        copy.schemaVersion = AppSettings.currentSchemaVersion
        settings = copy
        persist()
        return settings
    }

    public func replace(with newValue: AppSettings) {
        settings = newValue
        settings.schemaVersion = AppSettings.currentSchemaVersion
        persist()
    }

    private func persist() {
        guard let data = try? encoder.encode(settings) else { return }
        store.set(data, forKey: SettingsStore.settingsKey)
    }
}

/// Selector lists that were shipped as defaults by earlier versions. Overrides
/// made up entirely of these are stale defaults, not user edits.
public enum LegacySelectors {
    public static let prototype: [SelectorKey: [String]] = [
        .editor: [
            "textarea[aria-label=\"Chat with ChatGPT\"]",
            "div[contenteditable=\"true\"]",
            "textarea"
        ],
        .send: [
            "button[data-testid=\"send-button\"]",
            "button[aria-label=\"Send prompt\"]",
            "button[data-testid=\"composer-send-button\"]",
            "button[aria-label*=\"Send\"]"
        ],
        .newChat: [
            "button[data-testid=\"new-chat-button\"]",
            "a[href=\"/\"]",
            "button[aria-label=\"New chat\"]",
            "[data-testid=\"new-chat\"]",
            "a[aria-label=\"New chat\"]"
        ],
        .tempChat: [
            "button[data-testid=\"temporary-chat-button\"]",
            "button[aria-label=\"Temporary chat\"]",
            "button[aria-label*=\"Temporary chat\"]",
            "[aria-label*=\"Temporary chat\"]",
            "[aria-label*=\"\u{4E34}\u{65F6}\"]"
        ],
        .assistant: [
            "div[data-message-author-role=\"assistant\"]"
        ]
    ]

    /// True when every selector was shipped by a previous version, i.e. the
    /// user never hand-wrote anything here.
    public static func isShippedDefault(_ key: SelectorKey, _ selectors: [String]) -> Bool {
        let known = Set((prototype[key] ?? []) + (SelectorSet.builtIn[key] ?? []))
        return !selectors.isEmpty && selectors.allSatisfy { known.contains($0) }
    }

    public static func dropStaleOverrides(in set: SelectorSet) -> SelectorSet {
        var overrides = set.overrides
        for (key, value) in overrides where isShippedDefault(key, value) {
            overrides[key] = nil
        }
        return SelectorSet(overrides: overrides)
    }
}

/// Reads the flat `UserDefaults` keys written by the single-file prototype so
/// existing installs keep their shortcuts, selectors and window frame.
public enum LegacySettingsMigration {
    public static func settings(from store: KeyValueStore) -> AppSettings? {
        var found = false
        var settings = AppSettings()

        func shortcut(_ prefix: String, fallback: Shortcut?) -> Shortcut? {
            guard
                let code = store.object(forKey: "\(prefix)KeyCode") as? Int,
                let mods = store.object(forKey: "\(prefix)Modifiers") as? Int
            else { return fallback }
            found = true
            return Shortcut(keyCode: UInt32(max(0, code)), modifiers: UInt32(max(0, mods)))
        }

        settings.toggleShortcut = shortcut("hotkey", fallback: settings.toggleShortcut)
        settings.pinShortcut = shortcut("pin", fallback: settings.pinShortcut)
        settings.newChatShortcut = shortcut("newChat", fallback: settings.newChatShortcut)
        settings.newTempChatShortcut = shortcut("newTempChat", fallback: settings.newTempChatShortcut)
        settings.copyLastResponseShortcut = shortcut("copyLastResponse", fallback: settings.copyLastResponseShortcut)

        if let nonActivating = store.object(forKey: "nonActivating") as? Bool {
            settings.nonActivating = nonActivating
            found = true
        }
        if let frame = store.object(forKey: "panelFrame") as? String {
            settings.panelFrame = frame
            found = true
        }

        var overrides: [SelectorKey: [String]] = [:]
        for key in SelectorKey.allCases {
            guard let stored = store.object(forKey: "selector.\(key.rawValue)") as? [String], !stored.isEmpty else { continue }
            found = true
            // The prototype stored its built-in defaults verbatim; keep only
            // selectors the user actually wrote.
            if LegacySelectors.isShippedDefault(key, stored) { continue }
            overrides[key] = stored
        }
        if !overrides.isEmpty {
            settings.selectors = SelectorSet(overrides: overrides)
        }

        // Proxy is intentionally not migrated: the old implementation set
        // HTTP_PROXY env vars, which WKWebView never read.
        return found ? settings : nil
    }
}
