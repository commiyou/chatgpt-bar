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

public struct AppSettings: Codable, Equatable {
    public static let currentSchemaVersion = 1

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

    public var selectors: SelectorSet
    public var proxy: ProxySettings

    /// `chatgptbar://paste?send=1` submits without asking only when this is on.
    /// Off by default: any process or web page can open a URL scheme.
    public var allowURLSchemeAutoSend: Bool

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
        selectors: SelectorSet = SelectorSet(),
        proxy: ProxySettings = ProxySettings(),
        allowURLSchemeAutoSend: Bool = false
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
        self.selectors = selectors
        self.proxy = proxy
        self.allowURLSchemeAutoSend = allowURLSchemeAutoSend
    }

    public var resolvedHomeURL: URL {
        URL(string: homeURL) ?? URL(string: "https://chatgpt.com")!
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
            // The prototype stored built-in defaults verbatim; keep only real edits.
            if stored == SelectorSet.builtIn[key] { continue }
            overrides[key] = stored
            found = true
        }
        if !overrides.isEmpty {
            settings.selectors = SelectorSet(overrides: overrides)
        }

        // Proxy is intentionally not migrated: the old implementation set
        // HTTP_PROXY env vars, which WKWebView never read.
        return found ? settings : nil
    }
}
