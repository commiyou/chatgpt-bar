import Foundation

public enum PasteMode: String, Codable, Equatable {
    case append
    case replace
}

public enum URLCommand: Equatable {
    case paste(text: String, mode: PasteMode, send: Bool, reveal: Bool)
    case newChat
    case newTempChat
    case copyLastResponse
    case open
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
