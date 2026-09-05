import Foundation

public enum PasteMode: String, Codable, Equatable {
    case append
    case replace
}

public enum AppAppearance: String, CaseIterable, Codable, Hashable {
    case auto
    case light
    case dark

    public var displayName: String {
        switch self {
        case .auto: return "跟随系统 / Auto"
        case .light: return "浅色 / Light"
        case .dark: return "深色 / Dark"
        }
    }
}

public enum AppLanguage: String, CaseIterable, Codable, Hashable {
    case system
    case zhHans
    case en

    public var displayName: String {
        switch self {
        case .system: return "跟随系统 / System"
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }
}

public enum URLSchemeCommand: String, CaseIterable, Codable, Hashable {
    case open
    case paste
    case newChat
    case newTempChat
    case copyLastResponse

    public var displayName: String {
        switch self {
        case .open: return "打开 / 显示面板"
        case .paste: return "粘贴文本（paste / share / send）"
        case .newChat: return "新建普通会话"
        case .newTempChat: return "新建临时会话"
        case .copyLastResponse: return "复制最后一条回复"
        }
    }

    public var helpText: String {
        switch self {
        case .open:
            return "允许外部调用 chatgptbar://open，只显示面板，不发送内容。"
        case .paste:
            return "允许外部调用 chatgptbar://paste、share 或 send，把 text 参数写入输入框；send 还可能提交。"
        case .newChat:
            return "允许外部调用 chatgptbar://newChat，在当前页面创建普通新会话。"
        case .newTempChat:
            return "允许外部调用 chatgptbar://newTempChat，打开临时会话；站点没有按钮时会回退到临时会话 URL。"
        case .copyLastResponse:
            return "允许外部调用 chatgptbar://copyLastResponse，把最后一条助手回复以 Markdown 写入剪贴板。"
        }
    }

    public var displayNameEnglish: String {
        switch self {
        case .open: return "Open / Show Panel"
        case .paste: return "Paste Text (paste / share / send)"
        case .newChat: return "New Chat"
        case .newTempChat: return "New Temporary Chat"
        case .copyLastResponse: return "Copy Last Response"
        }
    }

    public var helpTextEnglish: String {
        switch self {
        case .open:
            return "Allows chatgptbar://open to show the panel without sending content."
        case .paste:
            return "Allows paste, share, or send URLs to write the text parameter into the editor; send may submit it."
        case .newChat:
            return "Allows chatgptbar://newChat to create a normal conversation on the current page."
        case .newTempChat:
            return "Allows chatgptbar://newTempChat to open a temporary conversation, falling back to the temporary-chat URL when needed."
        case .copyLastResponse:
            return "Allows chatgptbar://copyLastResponse to copy the latest assistant response as Markdown."
        }
    }

    public var exampleURL: String {
        switch self {
        case .open:
            return "chatgptbar://open"
        case .paste:
            return "chatgptbar://paste?text=hello%20from%20ChatGPT%20Bar&mode=append&send=0&open=1"
        case .newChat:
            return "chatgptbar://newChat"
        case .newTempChat:
            return "chatgptbar://newTempChat"
        case .copyLastResponse:
            return "chatgptbar://copyLastResponse"
        }
    }
}

public enum URLCommand: Equatable {
    case paste(text: String, mode: PasteMode, send: Bool, reveal: Bool)
    case newChat
    case newTempChat
    case copyLastResponse
    case open

    public var schemeCommand: URLSchemeCommand {
        switch self {
        case .paste: return .paste
        case .newChat: return .newChat
        case .newTempChat: return .newTempChat
        case .copyLastResponse: return .copyLastResponse
        case .open: return .open
        }
    }
}

public enum URLCommandError: Error, Equatable, CustomStringConvertible {
    case unsupportedScheme(String)
    case unknownCommand(String)
    case missingText
    case textTooLong(count: Int, limit: Int)

    public var description: String {
        switch self {
        case .unsupportedScheme(let scheme):
            return "Unsupported URL scheme: \(scheme)"
        case .unknownCommand(let command):
            return "Unknown command: \(command)"
        case .missingText:
            return "Missing `text` parameter"
        case .textTooLong(let count, let limit):
            return "Text too long: \(count) characters (limit \(limit))"
        }
    }
}

public enum URLCommandParser {
    public static let scheme = "chatgptbar"
    public static let textLimit = 100_000

    /// `chatgptbar://paste?text=...&mode=append|replace&send=0|1&open=0|1`
    ///
    /// `dump` is deliberately not exposed: it copies page metadata to the
    /// clipboard, so it stays a Settings-only action.
    public static func parse(_ url: URL) throws -> URLCommand {
        guard url.scheme?.lowercased() == scheme else {
            throw URLCommandError.unsupportedScheme(url.scheme ?? "")
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        let rawCommand = (url.host ?? url.pathComponents.first(where: { $0 != "/" }) ?? "").lowercased()

        func value(_ name: String) -> String? {
            items.first(where: { $0.name.lowercased() == name })?.value
        }
        func flag(_ name: String, default defaultValue: Bool) -> Bool {
            guard let raw = value(name)?.lowercased() else { return defaultValue }
            switch raw {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return defaultValue
            }
        }

        switch rawCommand {
        case "paste", "share", "send":
            guard let text = value("text"), !text.isEmpty else { throw URLCommandError.missingText }
            guard text.count <= textLimit else {
                throw URLCommandError.textTooLong(count: text.count, limit: textLimit)
            }
            let mode = PasteMode(rawValue: (value("mode") ?? "append").lowercased()) ?? .append
            let send = flag("send", default: rawCommand == "send")
            // A submit always shows the panel, so the user can see what is sent.
            let reveal = send ? true : flag("open", default: true)
            return .paste(text: text, mode: mode, send: send, reveal: reveal)
        case "newchat":
            return .newChat
        case "newtempchat", "temp", "tempchat":
            return .newTempChat
        case "copylastresponse", "copylast":
            return .copyLastResponse
        case "open", "toggle", "":
            return .open
        default:
            throw URLCommandError.unknownCommand(rawCommand)
        }
    }
}
