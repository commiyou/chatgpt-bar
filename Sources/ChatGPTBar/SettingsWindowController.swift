import AppKit
import SwiftUI
import ChatGPTBarKit

/// Hosts the SwiftUI settings form.
///
/// Edits go into a draft and are only committed on Save, so recording a
/// shortcut is not an immediate, irreversible side effect.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    struct Environment {
        var currentSettings: () -> AppSettings
        /// Applies the edited settings and returns human readable warnings.
        var apply: (AppSettings) -> [String]
        var beginRecording: (@escaping (Shortcut?) -> Void) -> Void
        var cancelRecording: () -> Void
        var probeSelectors: (@escaping (String) -> Void) -> Void
        var dumpDOM: (@escaping (String) -> Void) -> Void
        var samplePerformance: (TimeInterval, @escaping ([String: Any]) -> Void) -> Void
    }

    private let environment: Environment
    private var window: NSWindow?
    private var model: SettingsModel?

    init(environment: Environment) {
        self.environment = environment
        super.init()
    }

    func show() {
        show(tab: .general)
    }

    func show(tab: SettingsTab) {
        let window = self.window ?? build(tab: tab)
        model?.reload()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func build(tab: SettingsTab) -> NSWindow {
        let model = SettingsModel(environment: environment)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        model.onClose = { [weak window] in window?.orderOut(nil) }

        window.title = "\(AppInfo.name) 设置"
        window.contentView = NSHostingView(rootView: SettingsView(model: model, initialTab: tab))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.model = model
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        environment.cancelRecording()
    }
}
