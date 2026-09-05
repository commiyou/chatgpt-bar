import AppKit
import ChatGPTBarKit

/// Menu bar item: left click toggles, right click opens the menu.
///
/// The menu is shown with `popUp(positioning:at:in:)` instead of assigning
/// `statusItem.menu` and clearing it from an async block during menu tracking.
final class StatusItemController {
    struct Handlers {
        var toggle: () -> Void
        var togglePin: () -> Void
        var newChat: () -> Void
        var newTempChat: () -> Void
        var copyLastResponse: () -> Void
        var reload: () -> Void
        var openInBrowser: () -> Void
        var openSettings: () -> Void
        var quit: () -> Void
    }

    private let statusItem: NSStatusItem
    private let handlers: Handlers
    private let target = MenuTarget()
    private var isPinned = false

    init(handlers: Handlers) {
        self.handlers = handlers
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: AppInfo.name)
                ?? NSImage(systemSymbolName: "message", accessibilityDescription: AppInfo.name)
            button.image?.isTemplate = true
            button.toolTip = AppInfo.name
            button.target = target
            button.action = #selector(MenuTarget.statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        target.onClick = { [weak self] isRightClick in
            guard let self else { return }
            if isRightClick {
                self.showMenu()
            } else {
                self.handlers.toggle()
            }
        }
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
    }

    private func showMenu() {
        let menu = NSMenu()
        add(menu, "显示 / 隐藏面板", handlers.toggle)
        let pinItem = add(menu, isPinned ? "取消置顶" : "窗口置顶", handlers.togglePin)
        pinItem.state = isPinned ? .on : .off
        menu.addItem(.separator())
        add(menu, "New Chat", handlers.newChat)
        add(menu, "New Temp Chat", handlers.newTempChat)
        add(menu, "复制最后一条回复", handlers.copyLastResponse)
        menu.addItem(.separator())
        add(menu, "重新加载", handlers.reload)
        add(menu, "在浏览器中打开", handlers.openInBrowser)
        add(menu, "设置…", handlers.openSettings)
        menu.addItem(.separator())
        add(menu, "退出 \(AppInfo.name)", handlers.quit)

        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuTarget.invoke(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = MenuAction(handler: handler)
        menu.addItem(item)
        return item
    }
}

private final class MenuAction {
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
}

private final class MenuTarget: NSObject {
    var onClick: ((Bool) -> Void)?

    @objc func statusItemClicked(_ sender: Any?) {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        onClick?(isRightClick)
    }

    @objc func invoke(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.handler()
    }
}
