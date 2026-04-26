import AppKit
import Foundation

/// Push-to-talk hotkey: press and hold Fn to record, release to submit.
/// Adding Shift while pressing Fn switches to instruction (LLM) mode.
/// While recording, Return also submits and Esc cancels.
class HotkeyManager {
    static let shared = HotkeyManager()

    private var onToggle: (() -> Void)?
    private var onInstructionToggle: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var isRecordingCheck: (() -> Bool)?

    // Modifier flags monitor — tracks Fn (and Shift) state changes
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var fnIsDown = false

    // Global key monitors for Enter (submit) and Esc (cancel) during recording
    private var keyDownMonitor: Any?
    private var localKeyDownMonitor: Any?

    func register(
        onToggle: @escaping () -> Void,
        onInstructionToggle: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        isRecording: @escaping () -> Bool
    ) {
        self.onToggle = onToggle
        self.onInstructionToggle = onInstructionToggle
        self.onCancel = onCancel
        self.isRecordingCheck = isRecording
        installFlagsMonitor()
        installKeyMonitor()
    }

    // MARK: - Enter / Esc Key Monitor

    private func installKeyMonitor() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyDown(event) == true { return nil }
            return event
        }
    }

    @discardableResult
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isRecordingCheck?() == true else { return false }
        switch event.keyCode {
        case 36, 76: // Return, Enter (numpad)
            DispatchQueue.main.async { [weak self] in self?.onToggle?() }
            return true
        case 53: // Escape
            DispatchQueue.main.async { [weak self] in self?.onCancel?() }
            return true
        default:
            return false
        }
    }

    // MARK: - Modifier Flags Monitor (Fn hold-to-talk)

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
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        let hasBlockedModifiers = !event.modifierFlags.intersection(blockedModifiers).isEmpty

        // Fn pressed (transition from up to down)
        if fnDown && !fnIsDown {
            fnIsDown = true
            // Don't start if other modifiers are held or already recording
            guard !hasBlockedModifiers, isRecordingCheck?() == false else { return }
            // Mode is decided at the moment of press: Shift held → instruction
            if shiftDown {
                DispatchQueue.main.async { [weak self] in
                    self?.onInstructionToggle?()
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.onToggle?()
                }
            }
        }
        // Fn released (transition from down to up) → submit if recording
        else if !fnDown && fnIsDown {
            fnIsDown = false
            guard isRecordingCheck?() == true else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onToggle?()
            }
        }
    }
}
