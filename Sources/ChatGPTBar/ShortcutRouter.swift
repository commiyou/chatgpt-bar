import AppKit
import ChatGPTBarKit

extension NSEvent.ModifierFlags {
    var carbonMask: UInt32 {
        var mask: UInt32 = 0
        if contains(.command) { mask |= CarbonModifier.command }
        if contains(.shift) { mask |= CarbonModifier.shift }
        if contains(.option) { mask |= CarbonModifier.option }
        if contains(.control) { mask |= CarbonModifier.control }
        return mask
    }
}

/// Window-scoped local shortcuts plus shortcut recording.
///
/// Scoping matters: the prototype used one app-wide monitor that swallowed
/// keystrokes typed into the Settings text fields and shadowed the web page's
/// own shortcuts.
final class ShortcutRouter {
    enum Action: CaseIterable {
        case pin
        case newChat
        case newTempChat
        case copyLastResponse
    }

    /// Returns the window local shortcuts apply to (the chat panel).
    var scopeWindow: () -> NSWindow?
    var onAction: ((Action) -> Void)?

    private var monitor: Any?
    private var bindings: [(shortcut: Shortcut, action: Action)] = []
    private var recordingCompletion: ((Shortcut?) -> Void)?
    private var lastShortcutAction: (shortcut: Shortcut, time: TimeInterval)?

    var isRecording: Bool { recordingCompletion != nil }

    init(scopeWindow: @escaping () -> NSWindow?) {
        self.scopeWindow = scopeWindow
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        cancelRecording()
    }

    func update(bindings newBindings: [(Shortcut?, Action)]) {
        bindings = newBindings.compactMap { shortcut, action in
            guard let shortcut else { return nil }
            return (shortcut, action)
        }
    }

    /// Captures the next key press. Esc cancels, so an armed recorder can never
    /// keep eating keystrokes.
    func beginRecording(completion: @escaping (Shortcut?) -> Void) {
        cancelRecording()
        recordingCompletion = completion
    }

    func cancelRecording() {
        guard let completion = recordingCompletion else { return }
        recordingCompletion = nil
        completion(nil)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if let completion = recordingCompletion {
            recordingCompletion = nil
            let isEscape = event.keyCode == 53 && event.modifierFlags.carbonMask == 0
            completion(isEscape ? nil : Shortcut(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags.carbonMask))
            return nil
        }

        guard let scope = scopeWindow(), event.window === scope else { return event }

        let candidate = Shortcut(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags.carbonMask)
        guard let match = bindings.first(where: { $0.shortcut == candidate }) else { return event }
        // Some AppKit paths deliver the same local keyDown twice; a toggle must
        // not flip twice for one physical press.
        let now = Date().timeIntervalSinceReferenceDate
        if let last = lastShortcutAction, last.shortcut == candidate, now - last.time < 0.15 {
            return nil
        }
        lastShortcutAction = (candidate, now)
        onAction?(match.action)
        return nil
    }
}
