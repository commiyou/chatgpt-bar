import Foundation

public enum NavigationDecision: Equatable {
    /// Keep the navigation inside the panel.
    case allowInPanel
    /// Hand off to the default browser and cancel in-panel navigation.
    case openExternally
    /// Refuse entirely (unknown schemes).
    case block
}

/// Keeps the panel on ChatGPT and its sign-in providers; everything else the
/// user clicks goes to the real browser instead of hijacking the shell.
public struct NavigationPolicy {
    public static let defaultAllowedHostSuffixes: [String] = [
        "chatgpt.com",
        "openai.com",
        "oaistatic.com",
        "oaiusercontent.com",
        "auth0.com",
        "accounts.google.com",
        "gstatic.com",
        "googleapis.com",
        "googleusercontent.com",
        "appleid.apple.com",
        "cdn-apple.com",
        "login.microsoftonline.com",
        "login.live.com",
        "sentry.io",
        "stripe.com",
        "cloudflare.com",
        "challenges.cloudflare.com"
    ]

    public let allowedHostSuffixes: [String]

    public init(allowedHostSuffixes: [String] = NavigationPolicy.defaultAllowedHostSuffixes) {
        self.allowedHostSuffixes = allowedHostSuffixes.map { $0.lowercased() }
    }

    public func isAllowedHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return allowedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// - Parameter isMainFrame: only main-frame navigations are redirected;
    ///   blocking subresources or iframes would break the page.
    public func decide(url: URL?, isMainFrame: Bool) -> NavigationDecision {
        guard let url else { return .block }
        let scheme = url.scheme?.lowercased() ?? ""

        switch scheme {
        case "http", "https":
            if isAllowedHost(url.host) { return .allowInPanel }
            return isMainFrame ? .openExternally : .allowInPanel
        case "about", "blob", "data", "javascript":
            return .allowInPanel
        case "mailto", "tel", "facetime", "sms":
            return .openExternally
        default:
            return .block
        }
    }
}
