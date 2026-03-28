import AppKit
import Foundation

class HotkeyManager {
    static let shared = HotkeyManager()

    private var onToggle: (() -> Void)?
    private var onInstructionToggle: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var isRecordingCheck: (() -> Bool)?

    // Double-tap Fn detection
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var lastFnReleaseTime: Date?
    private let doubleTapThreshold: TimeInterval = 0.4
    private var fnIsDown = false

    // Fn + double-tap Shift detection (instruction/AI mode)
    private var shiftIsDown = false
    private var lastShiftReleaseTime: Date?

    // Global key monitors for Enter/Esc during recording
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

    // MARK: - Enter/Esc Key Monitor

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

    /// Returns true if the event was consumed.
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

    // MARK: - Modifier Flags Monitor

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

        // --- Fn + double-tap Shift (instruction/AI mode) ---
        if fnDown && !hasBlockedModifiers {
            if shiftDown && !shiftIsDown {
                shiftIsDown = true
            } else if !shiftDown && shiftIsDown {
                shiftIsDown = false
                let now = Date()
                if let lastRelease = lastShiftReleaseTime,
                   now.timeIntervalSince(lastRelease) < doubleTapThreshold {
                    lastShiftReleaseTime = nil
                    lastFnReleaseTime = nil
                    DispatchQueue.main.async { [weak self] in
                        self?.onInstructionToggle?()
                    }
                } else {
                    lastShiftReleaseTime = now
                }
            }
        } else {
            if shiftIsDown && !shiftDown { shiftIsDown = false }
            lastShiftReleaseTime = nil
        }

        // --- Double-tap Fn to start, single tap Fn to stop ---
        if fnDown && !fnIsDown && !hasBlockedModifiers && !shiftDown {
            fnIsDown = true
        } else if !fnDown && fnIsDown {
            fnIsDown = false
            shiftIsDown = false
            lastShiftReleaseTime = nil

            if hasBlockedModifiers || shiftDown { return }

            if isRecordingCheck?() == true {
                // Single tap while recording → stop
                lastFnReleaseTime = nil
                DispatchQueue.main.async { [weak self] in
                    self?.onToggle?()
                }
            } else {
                // Not recording → require double-tap to start
                let now = Date()
                if let lastRelease = lastFnReleaseTime,
                   now.timeIntervalSince(lastRelease) < doubleTapThreshold {
                    lastFnReleaseTime = nil
                    DispatchQueue.main.async { [weak self] in
                        self?.onToggle?()
                    }
                } else {
                    lastFnReleaseTime = now
                }
            }
        }
    }
}
