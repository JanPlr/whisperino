import Carbon
import Foundation

class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var onPress: (() -> Void)?
    private var onRelease: (() -> Void)?

    func register(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
        registerCarbonHotkey()
    }

    func handleHotkeyPress() {
        onPress?()
    }

    func handleHotkeyRelease() {
        onRelease?()
    }

    private func registerCarbonHotkey() {
        // Listen for both key press AND key release (for push-to-talk)
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]

        let handlerRef = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyHandler,
            2,
            &eventTypes,
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
    guard let userData = userData, let event = event else {
        return OSStatus(eventNotHandledErr)
    }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    let eventKind = GetEventKind(event)

    DispatchQueue.main.async {
        if eventKind == UInt32(kEventHotKeyPressed) {
            manager.handleHotkeyPress()
        } else if eventKind == UInt32(kEventHotKeyReleased) {
            manager.handleHotkeyRelease()
        }
    }
    return noErr
}
