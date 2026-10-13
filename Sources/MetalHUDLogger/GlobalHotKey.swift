import Carbon.HIToolbox
import Foundation

/// System-wide hotkey via Carbon `RegisterEventHotKey` (works while other apps are fullscreen,
/// no Accessibility permission needed). Defaults to ⌃⌥R.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: Int = kVK_ANSI_R, modifiers: Int = controlKey | optionKey, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &eventType, userData, &handlerRef)
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D48_554C), id: 1) // 'MHUL'
        let registerStatus = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                                 GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
