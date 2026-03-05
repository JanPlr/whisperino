import AppKit
import Carbon
import Foundation

class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var instructionHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onPress: (() -> Void)?
    private var onRelease: (() -> Void)?
    private var onInstructionPress: (() -> Void)?
    private var onInstructionRelease: (() -> Void)?

    // Double-tap Option detection
    private var flagsMonitor: Any?
    private var lastOptionReleaseTime: Date?
    private let doubleTapThreshold: TimeInterval = 0.35
    private var optionIsDown = false

    func register(
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void,
        onInstructionPress: @escaping () -> Void,
        onInstructionRelease: @escaping () -> Void
    ) {
        self.onPress = onPress
        self.onRelease = onRelease
        self.onInstructionPress = onInstructionPress
        self.onInstructionRelease = onInstructionRelease
        installEventHandlerOnce()
        let config = SettingsStore.shared.settings.hotkey
        registerHotKeys(keyCode: config.keyCode, modifiers: config.modifiers)
        installDoubleTapMonitor()
    }

    func updateHotkey(config: HotkeyConfig) {
        unregisterHotKeys()
        registerHotKeys(keyCode: config.keyCode, modifiers: config.modifiers)
    }

    func handleHotkeyPress(instruction: Bool) {
        if instruction {
            onInstructionPress?()
        } else {
            onPress?()
        }
    }

    func handleHotkeyRelease(instruction: Bool) {
        if instruction {
            onInstructionRelease?()
        } else {
            onRelease?()
        }
    }

    // MARK: - Double-tap Option

    /// Monitors modifier key changes globally to detect double-tap Option.
    /// This works independently of the configurable hotkey — it's always active.
    private func installDoubleTapMonitor() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        // Also monitor locally (when our own windows are focused)
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let optionDown = event.modifierFlags.contains(.option)
        // Only care about bare Option (no other modifiers)
        let otherModifiers: NSEvent.ModifierFlags = [.command, .shift, .control]
        let hasOtherModifiers = !event.modifierFlags.intersection(otherModifiers).isEmpty

        if optionDown && !optionIsDown && !hasOtherModifiers {
            // Option pressed
            optionIsDown = true
        } else if !optionDown && optionIsDown {
            // Option released
            optionIsDown = false

            if hasOtherModifiers { return }

            let now = Date()
            if let lastRelease = lastOptionReleaseTime,
               now.timeIntervalSince(lastRelease) < doubleTapThreshold {
                // Double-tap detected
                lastOptionReleaseTime = nil
                DispatchQueue.main.async { [weak self] in
                    self?.onPress?()
                }
            } else {
                lastOptionReleaseTime = now
            }
        }
    }

    // MARK: - Carbon Hotkey

    /// Install the Carbon event handler once (handles both press and release)
    private func installEventHandlerOnce() {
        guard eventHandlerRef == nil else { return }

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
            &eventHandlerRef
        )
    }

    private func registerHotKeys(keyCode: UInt32, modifiers: UInt32) {
        // Primary hotkey (e.g. Option+D)
        let hotKeyID = EventHotKeyID(signature: OSType(0x5746), id: 1)
        RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )

        // Instruction hotkey: same key + Shift (e.g. Shift+Option+D)
        let instructionID = EventHotKeyID(signature: OSType(0x5746), id: 2)
        RegisterEventHotKey(
            keyCode, modifiers | UInt32(shiftKey), instructionID,
            GetApplicationEventTarget(), 0, &instructionHotKeyRef
        )
    }

    private func unregisterHotKeys() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = instructionHotKeyRef {
            UnregisterEventHotKey(ref)
            instructionHotKeyRef = nil
        }
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

    // Determine which hotkey fired by checking the hotkey ID
    var hotkeyID = EventHotKeyID()
    GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    )
    let isInstruction = hotkeyID.id == 2

    DispatchQueue.main.async {
        if eventKind == UInt32(kEventHotKeyPressed) {
            manager.handleHotkeyPress(instruction: isInstruction)
        } else if eventKind == UInt32(kEventHotKeyReleased) {
            manager.handleHotkeyRelease(instruction: isInstruction)
        }
    }
    return noErr
}
