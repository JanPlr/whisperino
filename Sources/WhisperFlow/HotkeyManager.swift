import Carbon
import Foundation

class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var onTrigger: (() -> Void)?

    func register(callback: @escaping () -> Void) {
        self.onTrigger = callback
        registerCarbonHotkey()
    }

    func handleHotkey() {
        onTrigger?()
    }

    private func registerCarbonHotkey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerRef = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyHandler,
            1,
            &eventType,
            handlerRef,
            nil
        )

        // Option+D (keycode 2 = D, optionKey modifier)
        let hotKeyID = EventHotKeyID(signature: OSType(0x5746), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_D),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}

// Carbon event handler (must be a plain function, not a closure)
private func carbonHotkeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData = userData else {
        return OSStatus(eventNotHandledErr)
    }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        manager.handleHotkey()
    }
    return noErr
}
