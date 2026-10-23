import AppKit
import Carbon
import MenoControlProtocol

@MainActor
final class GlobalHotkey {
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    let action: () -> Void
    init(key: String, modifiers: String, action: @escaping () -> Void) throws {
        self.action = action
        let code: UInt32
        switch key { case "R": code = UInt32(kVK_ANSI_R); case "N": code = UInt32(kVK_ANSI_N); default: code = UInt32(kVK_ANSI_M) }
        let flags: UInt32
        switch modifiers {
        case "control-option": flags = UInt32(controlKey | optionKey)
        case "command-option-shift": flags = UInt32(cmdKey | optionKey | shiftKey)
        default: flags = UInt32(controlKey | optionKey | shiftKey)
        }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let object = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { object.action() }; return noErr
        }, 1, &type, pointer, &handler)
        guard installed == noErr else { throw ControlError("hotkey_failed", "无法注册快捷键处理器") }
        let result = RegisterEventHotKey(code, flags, EventHotKeyID(signature: 0x4D454E4F, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        guard result == noErr else { if let handler { RemoveEventHandler(handler); self.handler = nil }; throw ControlError("hotkey_conflict", "快捷键已被占用或不可用（\(result)）") }
    }
    deinit { if let hotkey { UnregisterEventHotKey(hotkey) }; if let handler { RemoveEventHandler(handler) } }
}
