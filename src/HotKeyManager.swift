import AppKit
import Carbon.HIToolbox

/// 全局快捷键（Carbon RegisterEventHotKey，不需要辅助功能授权）。
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    private static var shared: HotKeyManager?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        HotKeyManager.shared = self

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, _, _ -> OSStatus in
            HotKeyManager.shared?.action()
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventSpec, nil, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4454_4B59), id: 1) // 'DTKY'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            print("hotkey registered: \(HotKeyManager.defaultShortcutText)")
        } else {
            print("hotkey register failed: OSStatus(\(status))")
        }
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let handler = handlerRef { RemoveEventHandler(handler) }
    }

    static let defaultKeyCode = UInt32(kVK_ANSI_N)
    static let defaultModifiers = UInt32(cmdKey | optionKey)

    static var defaultShortcutText: String { "⌥⌘N" }
}
