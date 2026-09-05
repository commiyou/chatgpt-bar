import Foundation
import ChatGPTBarKit

/// Runtime language selection for UI copy. The setting is intentionally kept
/// outside `Bundle` localization so it can change without relaunching.
enum AppLocalization {
    static var language: AppLanguage = .system

    static var usesEnglish: Bool {
        switch language {
        case .en:
            return true
        case .zhHans:
            return false
        case .system:
            return Locale.current.language.languageCode?.identifier.lowercased() == "en"
        }
    }

    static func text(_ chinese: String, _ english: String) -> String {
        usesEnglish ? english : chinese
    }
}
