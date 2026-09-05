import Foundation
import ChatGPTBarKit

// XCTest is not available on a Command Line Tools only install, so the pure
// logic checks run as a plain executable: `swift run SelfTest`.

var failures: [String] = []
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures.append(label) }
}

func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    checks += 1
    if lhs != rhs { failures.append("\(label): \(lhs) != \(rhs)") }
}

// MARK: - Shortcut

checkEqual(Shortcut.defaultToggle.displayString, "\u{2325}\u{2318}Space", "toggle shortcut display")
checkEqual(Shortcut.defaultCopyLastResponse.displayString, "\u{21E7}\u{2318}C", "copy shortcut display")
check(Shortcut.defaultToggle.isUsableAsGlobalHotkey, "toggle usable as global hotkey")
check(!Shortcut(keyCode: 0, modifiers: 0).isUsableAsGlobalHotkey, "modifier-less shortcut rejected globally")

// The prototype treated 0 as "unset", so `A` and "no modifiers" were unstorable.
do {
    let store = InMemoryStore()
    let settings = SettingsStore(store: store)
    settings.update { $0.toggleShortcut = Shortcut(keyCode: 0, modifiers: CarbonModifier.control) }
    let reloaded = SettingsStore(store: store)
    checkEqual(reloaded.settings.toggleShortcut, Shortcut(keyCode: 0, modifiers: CarbonModifier.control), "keyCode 0 round-trips")

    settings.update { $0.pinShortcut = nil }
    let cleared = SettingsStore(store: store)
    check(cleared.settings.pinShortcut == nil, "cleared shortcut stays nil")
}

// MARK: - Settings persistence and migration

do {
    let store = InMemoryStore()
    let first = SettingsStore(store: store)
    checkEqual(first.settings.allowURLSchemeAutoSend, false, "auto-send defaults to off")
    checkEqual(first.settings.homeURL, "https://chatgpt.com", "default home URL")

    first.update { $0.homeURL = "https://chatgpt.com/?model=gpt-5" }
    checkEqual(SettingsStore(store: store).settings.homeURL, "https://chatgpt.com/?model=gpt-5", "home URL persists")

    // Corrupt payload must not crash or wipe the app into an unusable state.
    store.set(Data("not json".utf8), forKey: SettingsStore.settingsKey)
    checkEqual(SettingsStore(store: store).settings.homeURL, "https://chatgpt.com", "corrupt payload falls back to defaults")
}

do {
    let legacy = InMemoryStore(seed: [
        "hotkeyKeyCode": 49,
        "hotkeyModifiers": 0x0900,
        "nonActivating": false,
        "panelFrame": "{{100, 100}, {460, 720}}",
        "selector.editor": ["#custom-editor"],
        "selector.assistant": SelectorSet.builtIn[.assistant]!
    ])
    let migrated = SettingsStore(store: legacy).settings
    checkEqual(migrated.toggleShortcut, Shortcut.defaultToggle, "legacy toggle shortcut migrated")
    checkEqual(migrated.nonActivating, false, "legacy nonActivating migrated")
    checkEqual(migrated.panelFrame, "{{100, 100}, {460, 720}}", "legacy panel frame migrated")
    checkEqual(migrated.selectors.selectors(for: .editor), ["#custom-editor"], "legacy selector override migrated")
    check(!migrated.selectors.isOverridden(.assistant), "legacy default-valued selector not pinned as override")
}

// MARK: - Selectors

do {
    var set = SelectorSet()
    checkEqual(set.selectors(for: .editor), SelectorSet.builtIn[.editor]!, "built-in selectors used by default")

    // Commas are part of CSS, not a separator.
    set.setOverride(.send, text: "button:is([data-testid=\"send-button\"], [aria-label=\"Send\"])\n\nform button")
    checkEqual(
        set.selectors(for: .send),
        ["button:is([data-testid=\"send-button\"], [aria-label=\"Send\"])", "form button"],
        "newline separated selectors"
    )

    // Editing a field back to the built-in list drops the override, so future
    // app versions can ship better defaults.
    set.setOverride(.editor, text: SelectorSet.serialize(SelectorSet.builtIn[.editor]!))
    check(!set.isOverridden(.editor), "matching built-ins clears the override")

    set.resetAll()
    check(!set.isOverridden(.send), "resetAll clears overrides")
}

// MARK: - Bridge script

do {
    var set = SelectorSet()
    set.setOverride(.editor, text: "div[data-x=\"</script>\"]")
    let source = BridgeScript.source(selectors: set)
    check(source.contains("window.__chatgptBar"), "bridge defines its global")
    check(source.contains("\\u003c/script\\u003e"), "selector text is escaped")
    check(!source.contains("</script>"), "raw script terminator never emitted")
    check(source.contains("async insert("), "bridge exposes insert")
    check(source.contains("lastResponse()"), "bridge exposes lastResponse")

    let okResponse = BridgeResponse.parse(["ok": true, "value": ["text": "hello"]])
    check(okResponse.isOK, "ok response parsed")
    checkEqual(okResponse.string("text"), "hello", "response value read")

    let failResponse = BridgeResponse.parse(["ok": false, "error": "editor_not_found"])
    check(!failResponse.isOK, "failure response parsed")
    check(BridgeErrorText.describe(failResponse.error).contains("输入框"), "failure code has a readable message")
    check(!BridgeResponse.parse("garbage").isOK, "non-dictionary response is a failure")
}

// MARK: - URL commands

func parse(_ string: String) throws -> URLCommand {
    try URLCommandParser.parse(URL(string: string)!)
}

do {
    checkEqual(try parse("chatgptbar://newChat"), .newChat, "newChat command")
    checkEqual(try parse("chatgptbar://newTempChat"), .newTempChat, "newTempChat command")
    checkEqual(try parse("chatgptbar://copyLastResponse"), .copyLastResponse, "copyLastResponse command")
    checkEqual(try parse("chatgptbar://open"), .open, "open command")

    checkEqual(
        try parse("chatgptbar://paste?text=hello%20world"),
        .paste(text: "hello world", mode: .append, send: false, reveal: true),
        "paste defaults"
    )
    checkEqual(
        try parse("chatgptbar://paste?text=a&mode=replace&send=1&open=0"),
        .paste(text: "a", mode: .replace, send: true, reveal: true),
        "send always reveals the panel"
    )
    checkEqual(
        try parse("chatgptbar://paste?text=a&open=0"),
        .paste(text: "a", mode: .append, send: false, reveal: false),
        "open=0 honoured without send"
    )

    // `dump` used to be reachable from any web page and wrote to the clipboard.
    do {
        _ = try parse("chatgptbar://dump")
        failures.append("dump should no longer be a URL command")
    } catch {
        checks += 1
    }

    do {
        _ = try parse("chatgptbar://paste")
        failures.append("paste without text should fail")
    } catch let error as URLCommandError {
        checkEqual(error, .missingText, "missing text error")
    }

    do {
        _ = try URLCommandParser.parse(URL(string: "https://example.com/paste?text=a")!)
        failures.append("foreign scheme should fail")
    } catch let error as URLCommandError {
        checkEqual(error, .unsupportedScheme("https"), "unsupported scheme error")
    }

    let long = String(repeating: "x", count: URLCommandParser.textLimit + 1)
    do {
        _ = try URLCommandParser.parse(URL(string: "chatgptbar://paste?text=\(long)")!)
        failures.append("oversized text should fail")
    } catch let error as URLCommandError {
        checkEqual(error, .textTooLong(count: long.count, limit: URLCommandParser.textLimit), "text limit enforced")
    }
}

// MARK: - Navigation policy

do {
    let policy = NavigationPolicy()
    func decide(_ url: String, mainFrame: Bool = true) -> NavigationDecision {
        policy.decide(url: URL(string: url), isMainFrame: mainFrame)
    }

    checkEqual(decide("https://chatgpt.com/c/123"), .allowInPanel, "chatgpt stays in panel")
    checkEqual(decide("https://accounts.google.com/o/oauth2/auth"), .allowInPanel, "sign-in provider stays in panel")
    checkEqual(decide("https://news.ycombinator.com"), .openExternally, "external link goes to the browser")
    checkEqual(decide("https://news.ycombinator.com", mainFrame: false), .allowInPanel, "subresources are never blocked")
    checkEqual(decide("mailto:someone@example.com"), .openExternally, "mailto handed to the system")
    checkEqual(decide("itms-apps://apps.apple.com"), .block, "unknown scheme blocked")
    check(policy.isAllowedHost("cdn.oaistatic.com"), "subdomain suffix match")
    check(!policy.isAllowedHost("chatgpt.com.evil.example"), "suffix match is not substring match")
}

// MARK: - Result

if failures.isEmpty {
    print("SelfTest: \(checks) checks passed")
} else {
    print("SelfTest: \(failures.count)/\(checks) checks FAILED")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
