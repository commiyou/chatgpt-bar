import AppKit

final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A non-activating panel does not get key status from AppKit on click, so
    /// clicking anywhere in the panel has to claim it explicitly.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown, !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }
}

final class PanelController: NSObject, NSWindowDelegate {
    private(set) var panel: ChatPanel!
    private let content: NSView

    private var nonActivating: Bool
    private var pinned: Bool

    private var frameSaveWork: DispatchWorkItem?

    /// Debounced: the prototype wrote to UserDefaults on every drag event.
    var onFrameChange: ((String) -> Void)?
    var onPinChange: ((Bool) -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?

    init(content: NSView, nonActivating: Bool, pinned: Bool, savedFrame: String?) {
        self.content = content
        self.nonActivating = nonActivating
        self.pinned = pinned
        super.init()
        buildPanel(savedFrame: savedFrame)
    }

    var isPinned: Bool { pinned }
    var isVisible: Bool { panel.isVisible }

    // MARK: - Construction

    private func buildPanel(savedFrame: String?) {
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .utilityWindow]
        if nonActivating { styleMask.insert(.nonactivatingPanel) }

        let panel = ChatPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 720),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        panel.title = AppInfo.name
        panel.titlebarAppearsTransparent = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.minSize = NSSize(width: 340, height: 380)

        content.translatesAutoresizingMaskIntoConstraints = true
        content.frame = panel.contentView?.bounds ?? panel.frame
        content.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(content)

        self.panel = panel
        applyPinLevel()
        restore(savedFrame: savedFrame)
    }

    private func restore(savedFrame: String?) {
        if let savedFrame {
            let rect = NSRectFromString(savedFrame)
            if rect.width >= panel.minSize.width, rect.height >= panel.minSize.height, isOnAnyScreen(rect) {
                panel.setFrame(rect, display: false)
                return
            }
        }
        panel.center()
    }

    private func isOnAnyScreen(_ rect: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
    }

    // MARK: - Visibility

    func toggle() {
        if panel.isVisible && panel.isKeyWindow {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if !nonActivating {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
        if let first = content.subviews.first {
            panel.makeFirstResponder(first)
        }
        onVisibilityChange?(true)
    }

    func hide() {
        saveFrameNow()
        panel.orderOut(nil)
        onVisibilityChange?(false)
    }

    // MARK: - Pin

    func togglePin() {
        setPinned(!pinned)
    }

    func setPinned(_ value: Bool) {
        pinned = value
        applyPinLevel()
        onPinChange?(value)
    }

    private func applyPinLevel() {
        panel.isFloatingPanel = pinned
        panel.level = pinned ? .floating : .normal
        panel.title = pinned ? "\(AppInfo.name) (Pinned)" : AppInfo.name
    }

    // MARK: - Non-activating

    /// `.nonactivatingPanel` is not reliably mutable on a live window, so the
    /// panel is rebuilt and the web view is moved across.
    func setNonActivating(_ value: Bool) {
        guard value != nonActivating else { return }
        nonActivating = value

        let wasVisible = panel.isVisible
        let frame = NSStringFromRect(panel.frame)
        content.removeFromSuperview()
        panel.delegate = nil
        panel.orderOut(nil)

        buildPanel(savedFrame: frame)
        if wasVisible { show() }
    }

    // MARK: - Frame persistence

    func windowDidMove(_ notification: Notification) { scheduleFrameSave() }
    func windowDidResize(_ notification: Notification) { scheduleFrameSave() }

    /// Closing the panel keeps the session alive; it only hides.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    private func scheduleFrameSave() {
        frameSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveFrameNow() }
        frameSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveFrameNow() {
        frameSaveWork?.cancel()
        frameSaveWork = nil
        onFrameChange?(NSStringFromRect(panel.frame))
    }
}
