import AppKit
import Foundation

class HotkeyManager {
    static let shared = HotkeyManager()

    private var onPress: (() -> Void)?
    private var onRelease: (() -> Void)?
    private var onInstructionPress: (() -> Void)?
    private var onInstructionRelease: (() -> Void)?

    // Double-tap Fn detection (regular dictation)
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var lastFnReleaseTime: Date?
    private let doubleTapThreshold: TimeInterval = 0.35
    private var fnIsDown = false

    // Fn + double-tap Shift detection (instruction/AI mode)
    private var shiftIsDown = false
    private var lastShiftReleaseTime: Date?

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
        installFlagsMonitor()
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

    // MARK: - Modifier Flags Monitor (double-tap Fn & Fn+double-tap Shift)

    private func installFlagsMonitor() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let fnDown = event.modifierFlags.contains(.function)
        let shiftDown = event.modifierFlags.contains(.shift)
        // Block Command/Control/Option
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        let hasBlockedModifiers = !event.modifierFlags.intersection(blockedModifiers).isEmpty

        // --- Fn + double-tap Shift (instruction/AI mode) ---
        // Only track Shift taps while Fn is held
        if fnDown && !hasBlockedModifiers {
            if shiftDown && !shiftIsDown {
                // Shift pressed while Fn held
                shiftIsDown = true
            } else if !shiftDown && shiftIsDown {
                // Shift released while Fn held
                shiftIsDown = false
                let now = Date()
                if let lastRelease = lastShiftReleaseTime,
                   now.timeIntervalSince(lastRelease) < doubleTapThreshold {
                    // Double-tap Shift detected while Fn held → instruction mode
                    lastShiftReleaseTime = nil
                    // Clear Fn double-tap state so releasing Fn doesn't also fire dictation
                    lastFnReleaseTime = nil
                    DispatchQueue.main.async { [weak self] in
                        self?.onInstructionPress?()
                        self?.onInstructionRelease?()
                    }
                } else {
                    lastShiftReleaseTime = now
                }
            }
        } else {
            // Fn not held or blocked modifiers — reset Shift tracking
            if shiftIsDown && !shiftDown { shiftIsDown = false }
            lastShiftReleaseTime = nil
        }

        // --- Double-tap Fn (regular dictation) ---
        if fnDown && !fnIsDown && !hasBlockedModifiers && !shiftDown {
            fnIsDown = true
        } else if !fnDown && fnIsDown {
            fnIsDown = false
            shiftIsDown = false
            lastShiftReleaseTime = nil

            if hasBlockedModifiers || shiftDown { return }

            let now = Date()
            if let lastRelease = lastFnReleaseTime,
               now.timeIntervalSince(lastRelease) < doubleTapThreshold {
                // Double-tap Fn → regular dictation
                lastFnReleaseTime = nil
                DispatchQueue.main.async { [weak self] in
                    self?.onPress?()
                    self?.onRelease?()
                }
            } else {
                lastFnReleaseTime = now
            }
        }
    }

}
