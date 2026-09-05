import AppKit

/// Every action that can fail must be visible when it fails - the prototype
/// discarded all bridge results, so a stale selector looked like a dead button.
final class Feedback {
    static let shared = Feedback()

    private var hud: NSPanel?
    private var dismissWork: DispatchWorkItem?

    private init() {}

    enum Kind {
        case info
        case failure

        var symbol: String {
            switch self {
            case .info: return "checkmark.circle.fill"
            case .failure: return "exclamationmark.triangle.fill"
            }
        }

        var tint: NSColor {
            switch self {
            case .info: return .systemGreen
            case .failure: return .systemOrange
            }
        }
    }

    /// Non-modal toast near the menu bar; safe to call from any completion handler.
    func toast(_ message: String, kind: Kind = .info) {
        if Thread.isMainThread {
            showHUD(message, kind: kind)
        } else {
            DispatchQueue.main.async { [weak self] in self?.showHUD(message, kind: kind) }
        }
    }

    func alert(title: String, message: String, style: NSAlert.Style = .informational) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = style
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Confirmation used before the URL scheme is allowed to submit a prompt.
    func confirm(
        title: String,
        message: String,
        confirmTitle: String,
        cancelTitle: String = AppLocalization.text("取消", "Cancel")
    ) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showHUD(_ message: String, kind: Kind) {
        dismissWork?.cancel()
        hud?.orderOut(nil)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
        icon.contentTintColor = kind.tint

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = 280

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])

        let size = stack.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: max(size.width, 200), height: max(size.height, 40))),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = effect

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(
                x: frame.maxX - panel.frame.width - 20,
                y: frame.maxY - panel.frame.height - 12
            )
            panel.setFrameOrigin(origin)
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        hud = panel

        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.hud else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                if self?.hud === panel { self?.hud = nil }
            })
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }
}
