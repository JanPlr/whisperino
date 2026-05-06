import AppKit
import CoreGraphics
import Foundation

/// Hotkey behaviour:
///
/// 1. **Hold trigger** (push-to-talk) — press to record, release to submit.
/// 2. **Double-tap trigger** (toggle) — quickly tap twice to enter a latched
///    recording, then a single tap stops and submits. Useful for hands-free
///    long dictation.
/// 3. **Trigger + Shift** — instruction (AI) mode. Either press them together,
///    or start with the trigger alone and add Shift at any point during the
///    recording — the mode upgrades and the recording becomes latched
///    (release won't auto-submit; tap trigger again or press Enter to submit).
/// 4. **Esc / Return** — cancel / submit while recording.
///
/// The trigger is configurable in Settings. Two flavours:
/// - **Modifier-only** (Fn) — driven by `flagsChanged`.
/// - **Modifier + key combo** (⌥D) — driven by a `CGEventTap` that
///   intercepts the keystroke so the underlying character (e.g. "∂" for
///   ⌥D) isn't typed into the focused app.
class HotkeyManager {
    static let shared = HotkeyManager()

    private var onToggle: (() -> Void)?
    private var onInstructionToggle: (() -> Void)?
    private var onUpgradeToInstruction: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var onSubmit: (() -> Void)?
    private var isRecordingCheck: (() -> Bool)?
    private var isChatActiveCheck: (() -> Bool)?

    // Modifier flag monitors
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var triggerIsDown = false
    private var shiftWasDown = false
    private var triggerPressTime: Date?

    // Double-tap toggle support
    private var isLatched = false
    private var stopPending = false
    private var latchTimeoutTask: DispatchWorkItem?

    // Mode-decision delay — gives Shift a chance to register if pressed
    // near-simultaneously with the trigger. Below human perception threshold.
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

    // CGEventTap for combo triggers (intercepts the keystroke so the
    // underlying character isn't typed). Always installed; the callback
    // short-circuits if the current trigger isn't a combo.
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?

    /// Currently configured trigger key. Read live from settings on every
    /// event so user changes take effect without re-registering monitors.
    private var triggerKey: TriggerKey {
        SettingsStore.shared.settings.triggerKey
    }

    func register(
        onToggle: @escaping () -> Void,
        onInstructionToggle: @escaping () -> Void,
        onUpgradeToInstruction: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onSubmit: @escaping () -> Void,
        isRecording: @escaping () -> Bool,
        isChatActive: @escaping () -> Bool
    ) {
        self.onToggle = onToggle
        self.onInstructionToggle = onInstructionToggle
        self.onUpgradeToInstruction = onUpgradeToInstruction
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        self.isRecordingCheck = isRecording
        self.isChatActiveCheck = isChatActive
        installFlagsMonitor()
        installKeyMonitor()
        installEventTap()
    }

    /// Reset internal state when the trigger key changes mid-session, so a
    /// stale "trigger is held" flag from the old key doesn't confuse the
    /// state machine after the swap. Also re-attempts to install the event
    /// tap, so a user who switches to a combo trigger right after granting
    /// Accessibility doesn't have to wait for the next retry tick.
    func resetTriggerState() {
        modeDecisionTask?.cancel()
        modeDecisionTask = nil
        latchTimeoutTask?.cancel()
        latchTimeoutTask = nil
        triggerIsDown = false
        shiftWasDown = false
        triggerPressTime = nil
        isLatched = false
        stopPending = false
        installEventTap()
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
        // Listen to Esc/Enter while *either* a recording is in flight
        // or the chat overlay is open (the chat-idle case).
        let recording = isRecordingCheck?() == true
        let chatActive = isChatActiveCheck?() == true
        guard recording || chatActive else { return false }
        switch event.keyCode {
        case 36, 76: // Return, Enter (numpad) → submit (recording) / finish (chat)
            DispatchQueue.main.async { [weak self] in self?.onSubmit?() }
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
        let trigger = triggerKey
        let shiftDown = event.modifierFlags.contains(.shift)
        let hasBlockedModifiers = !event.modifierFlags.intersection(trigger.blockedFlags).isEmpty

        if !trigger.isCombo {
            // Modifier-only triggers: press/release tracked here.
            let triggerDown = trigger.isDown(in: event.modifierFlags)
            if triggerDown && !triggerIsDown {
                triggerIsDown = true
                handleTriggerPress(blocked: hasBlockedModifiers)
            } else if !triggerDown && triggerIsDown {
                triggerIsDown = false
                handleTriggerRelease()
            }
        } else {
            // Combo triggers: press/release come from the event tap. But if
            // the user releases the modifier (e.g. Option) without releasing
            // the combo key first, the tap won't see a keyUp with the
            // modifier — so we treat modifier release as an implicit release
            // of the trigger.
            if triggerIsDown && !trigger.isDown(in: event.modifierFlags) {
                triggerIsDown = false
                handleTriggerRelease()
            }
        }

        // Shift added while we're already holding the trigger and recording
        // in dictation mode → upgrade to instruction (AI) mode.
        // The session also becomes latched: release won't auto-submit,
        // because the typical AI-mode flow is to keep adding context
        // (Cmd+C selections) and then explicitly submit.
        if triggerIsDown && shiftDown && !shiftWasDown
            && !hasBlockedModifiers
            && isRecordingCheck?() == true {
            isLatched = true
            DispatchQueue.main.async { [weak self] in
                self?.onUpgradeToInstruction?()
            }
        }
        shiftWasDown = shiftDown
    }

    private func handleTriggerPress(blocked: Bool) {
        triggerPressTime = Date()
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
            let trigger = self.triggerKey
            let stillTrigger = trigger.isDown(in: flags)
            let nowShift = flags.contains(.shift)
            let blockedNow = !flags.intersection(trigger.blockedFlags).isEmpty
            guard stillTrigger, !blockedNow else { return }
            self.modeDecisionTask = nil
            self.stopPending = false
            // Instruction mode is always latched — release shouldn't
            // auto-submit, the user will explicitly submit when they're
            // done adding context.
            self.isLatched = nowShift
            if nowShift {
                self.onInstructionToggle?()
            } else {
                self.onToggle?()
            }
        }
        modeDecisionTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + modeDecisionDelay, execute: task)
    }

    private func handleTriggerRelease() {
        // — If user released before the mode-decision fired, recording
        //   never started; just discard the pending task —
        if let task = modeDecisionTask {
            task.cancel()
            modeDecisionTask = nil
            return
        }

        guard let pressTime = triggerPressTime else { return }
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

    // MARK: - CGEventTap (combo triggers)

    private func installEventTap() {
        guard eventTap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleTapEvent(type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            // Tap creation fails if Accessibility isn't granted yet — common
            // right after a fresh build (build.sh resets the permission).
            // Retry every 2s; the guard at the top makes this idempotent
            // once we eventually succeed.
            print("[whisperino] CGEventTap install failed — retrying once Accessibility is granted")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.installEventTap()
            }
            return
        }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        eventTapRunLoopSource = source
        print("[whisperino] CGEventTap installed — combo triggers active")
    }

    /// Tap callback: decides whether to consume the event (combo match) or
    /// pass it through. Runs on the main thread because we install the
    /// run-loop source on the main run loop.
    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system can disable our tap if it thinks we're slow. Re-enable
        // if that happens. Other event types we don't care about.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let trigger = triggerKey
        guard let comboKeyCode = trigger.comboKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard eventKeyCode == comboKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        // Bridge CGEventFlags → NSEvent.ModifierFlags (the device-independent
        // bits use the same layout, so a raw cast is safe for our checks).
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        guard trigger.isDown(in: flags) else {
            // Combo key pressed without the required modifier — let it
            // through as a normal keystroke.
            return Unmanaged.passUnretained(event)
        }

        let hasBlockedModifiers = !flags.intersection(trigger.blockedFlags).isEmpty

        switch type {
        case .keyDown:
            // Auto-repeat fires keyDown repeatedly while held; only act on
            // the initial press so the state machine doesn't see a stream of
            // "presses".
            let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isAutoRepeat {
                if !triggerIsDown {
                    triggerIsDown = true
                    handleTriggerPress(blocked: hasBlockedModifiers)
                }
            }
            return nil  // consume so e.g. "∂" isn't typed
        case .keyUp:
            if triggerIsDown {
                triggerIsDown = false
                handleTriggerRelease()
            }
            return nil  // consume keyUp for symmetry
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
