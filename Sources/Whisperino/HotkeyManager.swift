import AppKit
import Foundation

/// Hotkey behaviour:
///
/// 1. **Hold Fn** (push-to-talk) — press to record, release to submit.
/// 2. **Double-tap Fn** (toggle) — quickly tap twice to enter a latched
///    recording, then a single tap stops and submits. Useful for hands-free
///    long dictation.
/// 3. **Fn + Shift** — instruction mode (LLM responds). Works whether you
///    press them in either order, thanks to a tiny mode-decision delay.
/// 4. **Esc / Return** — cancel / submit while recording.
class HotkeyManager {
    static let shared = HotkeyManager()

    private var onToggle: (() -> Void)?
    private var onInstructionToggle: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var isRecordingCheck: (() -> Bool)?

    // Modifier flag monitors
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var fnIsDown = false
    private var fnPressTime: Date?

    // Double-tap toggle support
    private var isLatched = false
    private var stopPending = false
    private var latchTimeoutTask: DispatchWorkItem?

    // Mode-decision delay — gives Shift a chance to register if pressed
    // near-simultaneously with Fn. Below human perception threshold.
    private var modeDecisionTask: DispatchWorkItem?
    private let modeDecisionDelay: TimeInterval = 0.018

    // A "tap" is anything shorter than this — hold-to-talk requires the
    // press to last at least this long; otherwise the brief release
    // becomes the first half of a possible double-tap.
    private let shortTapThreshold: TimeInterval = 0.22

    // How long to wait for a second tap before treating the recording
    // as an accidental tap and discarding it.
    private let doubleTapWindow: TimeInterval = 0.40

    // Enter / Esc monitors (work during recording)
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
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        let hasBlockedModifiers = !event.modifierFlags.intersection(blockedModifiers).isEmpty

        if fnDown && !fnIsDown {
            fnIsDown = true
            handleFnPress(blocked: hasBlockedModifiers)
        } else if !fnDown && fnIsDown {
            fnIsDown = false
            handleFnRelease()
        }
    }

    private func handleFnPress(blocked: Bool) {
        fnPressTime = Date()
        guard !blocked else { return }

        let isCurrentlyRecording = isRecordingCheck?() ?? false

        // — Press during latched recording: prepare to stop on release —
        if isCurrentlyRecording && isLatched {
            stopPending = true
            return
        }

        // — Press during latch-pending recording: this is the second tap
        //   of a double-tap → upgrade to latched mode (don't auto-submit
        //   on release any more) —
        if isCurrentlyRecording && !isLatched {
            latchTimeoutTask?.cancel()
            latchTimeoutTask = nil
            isLatched = true
            return
        }

        // — Fresh press: start a new recording. Tiny delay so a Shift
        //   pressed near-simultaneously is captured, picking instruction
        //   mode. —
        modeDecisionTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Re-check live modifier state at the moment we actually fire
            let flags = NSEvent.modifierFlags
            let stillFn = flags.contains(.function)
            let nowShift = flags.contains(.shift)
            let blockedNow = !flags.intersection([.command, .control, .option]).isEmpty
            guard stillFn, !blockedNow else { return }
            self.modeDecisionTask = nil
            self.isLatched = false
            self.stopPending = false
            if nowShift {
                self.onInstructionToggle?()
            } else {
                self.onToggle?()
            }
        }
        modeDecisionTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + modeDecisionDelay, execute: task)
    }

    private func handleFnRelease() {
        // — If user released before the mode-decision fired, recording
        //   never started; just discard the pending task —
        if let task = modeDecisionTask {
            task.cancel()
            modeDecisionTask = nil
            return
        }

        guard let pressTime = fnPressTime else { return }
        let duration = Date().timeIntervalSince(pressTime)
        let isCurrentlyRecording = isRecordingCheck?() ?? false
        guard isCurrentlyRecording else { return }

        if isLatched {
            if stopPending {
                // Single-tap during latched recording → submit on release
                isLatched = false
                stopPending = false
                DispatchQueue.main.async { [weak self] in self?.onToggle?() }
            }
            // Plain release while latched — no-op (latched recording stays)
            return
        }

        if duration < shortTapThreshold {
            // Brief tap — might be the first half of a double-tap. Keep the
            // recording going for `doubleTapWindow`; if a second press
            // arrives, we upgrade to latched. Otherwise, discard.
            latchTimeoutTask?.cancel()
            let task = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.latchTimeoutTask = nil
                if self.isRecordingCheck?() ?? false && !self.isLatched {
                    // No follow-up tap arrived → submit (stopRecording
                    // discards anything <0.5s itself, so accidental brief
                    // taps don't generate noise).
                    DispatchQueue.main.async { self.onToggle?() }
                }
            }
            latchTimeoutTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: task)
        } else {
            // Held long enough — push-to-talk submit
            DispatchQueue.main.async { [weak self] in self?.onToggle?() }
        }
    }
}
