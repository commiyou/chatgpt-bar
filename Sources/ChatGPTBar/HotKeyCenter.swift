import AppKit
import Carbon.HIToolbox
import ChatGPTBarKit

/// Global hotkey registration.
///
/// The prototype installed a new Carbon event handler on every re-registration
/// and ignored every `OSStatus`, so the toggle key fired N times after N edits
/// and a conflicting key failed silently. Here the handler is installed exactly
/// once and every failure is reported back to the caller.
final class HotKeyCenter {
    enum RegistrationError: LocalizedError, Equatable {
        case needsModifier
        case handlerInstallFailed(OSStatus)
        case registrationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .needsModifier:
                return AppLocalization.text("全局快捷键至少需要一个 ⌘ / ⌥ / ⌃ 修饰键", "The global shortcut needs ⌘, ⌥, or ⌃")
            case .handlerInstallFailed(let status):
                return AppLocalization.text("无法安装快捷键事件处理器（OSStatus \(status)）", "Could not install the shortcut event handler (OSStatus \(status))")
            case .registrationFailed(let status):
                return status == OSStatus(eventHotKeyExistsErr)
                    ? AppLocalization.text("该快捷键已被其他应用占用", "That shortcut is already used by another app")
                    : AppLocalization.text("快捷键注册失败（OSStatus \(status)）", "Shortcut registration failed (OSStatus \(status))")
            }
        }
    }

    static let shared = HotKeyCenter()

    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var action: (() -> Void)?
    private let signature = OSType(0x43424152) // 'CBAR'
    private let hotKeyID: UInt32 = 1

    private init() {}

    /// Registers (or clears, when `shortcut` is nil) the single global hotkey.
    @discardableResult
    func register(_ shortcut: Shortcut?, action: @escaping () -> Void) -> Result<Void, RegistrationError> {
        unregisterHotKey()
        self.action = action

        guard let shortcut else { return .success(()) }
        guard shortcut.isUsableAsGlobalHotkey else { return .failure(.needsModifier) }

        if let error = installHandlerIfNeeded() { return .failure(error) }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: hotKeyID)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            return .failure(.registrationFailed(status))
        }
        hotKeyRef = ref
        return .success(())
    }

    func fire(id: UInt32) {
        guard id == hotKeyID else { return }
        action?()
    }

    func tearDown() {
        unregisterHotKey()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        action = nil
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() -> RegistrationError? {
        guard eventHandler == nil else { return nil }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            chatGPTBarHotKeyHandler,
            1,
            &spec,
            nil,
            &ref
        )
        guard status == noErr else { return .handlerInstallFailed(status) }
        eventHandler = ref
        return nil
    }
}

private func chatGPTBarHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var id = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &id
    )
    guard status == noErr else { return OSStatus(eventNotHandledErr) }

    DispatchQueue.main.async {
        HotKeyCenter.shared.fire(id: id.id)
    }
    return noErr
}
