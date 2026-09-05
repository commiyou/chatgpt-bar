import Foundation

/// Carbon modifier masks, duplicated here so this module stays Foundation-only.
public enum CarbonModifier {
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000

    public static let all: UInt32 = command | shift | option | control
}

/// A key combination. `nil` (not a zero value) means "unassigned", so a plain
/// `A` key or a modifier-less shortcut round-trips through storage correctly.
public struct Shortcut: Codable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & CarbonModifier.all
    }

    public var displayString: String {
        var out = ""
        if modifiers & CarbonModifier.control != 0 { out += "\u{2303}" }
        if modifiers & CarbonModifier.option != 0 { out += "\u{2325}" }
        if modifiers & CarbonModifier.shift != 0 { out += "\u{21E7}" }
        if modifiers & CarbonModifier.command != 0 { out += "\u{2318}" }
        out += Shortcut.keyLabel(keyCode)
        return out
    }

    /// A global hotkey without modifiers would swallow ordinary typing.
    public var isUsableAsGlobalHotkey: Bool {
        modifiers & (CarbonModifier.command | CarbonModifier.option | CarbonModifier.control) != 0
    }

    public static func keyLabel(_ code: UInt32) -> String {
        if let named = namedKeys[code] { return named }
        if let printable = printableKeys[code] { return printable }
        return "Key\(code)"
    }

    private static let namedKeys: [UInt32: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        115: "Home", 116: "PageUp", 119: "End", 121: "PageDown",
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}"
    ]

    private static let printableKeys: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C",
        9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`"
    ]

    public static let defaultToggle = Shortcut(keyCode: 49, modifiers: CarbonModifier.option | CarbonModifier.command)
    public static let defaultPin = Shortcut(keyCode: 35, modifiers: CarbonModifier.command)
    public static let defaultNewChat = Shortcut(keyCode: 45, modifiers: CarbonModifier.command | CarbonModifier.shift)
    public static let defaultNewTempChat = Shortcut(keyCode: 17, modifiers: CarbonModifier.command | CarbonModifier.shift)
    public static let defaultCopyLastResponse = Shortcut(keyCode: 8, modifiers: CarbonModifier.command | CarbonModifier.shift)
}
