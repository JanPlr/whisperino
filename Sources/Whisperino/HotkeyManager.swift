import AppKit
import CoreGraphics
import Foundation

/// Hotkey behaviour:
///
/// 1. **Hold trigger** (push-to-talk) - press to record, release to submit.
///    Double-tap latches for hands-free dictation.
/// 2. **Tap trigger** (optional) - a single press starts a latched recording;
///    the same shortcut again stops and submits. No need to hold.
/// 3. **Trigger + Shift** - instruction (AI) mode. Either press them together,
///    or add Shift during a recording - the mode upgrades and the recording
///    becomes latched.
/// 4. **Esc / Return** - cancel / submit while recording.
///
/// Triggers are configurable in Settings. Supported input types:
/// - **Modifier-only** (Fn) - driven by `flagsChanged`.
/// - **Modifier + key combo** (fn + space, ⌥D) - driven by a `CGEventTap`
///   that intercepts the keystroke so it isn't typed into the focused app.
/// - **Auxiliary mouse button** - driven by the same event tap.
class HotkeyManager {
    static let shared = HotkeyManager()

    private var onToggle: (() -> Void)?
    private var onInstructionToggle: (() -> Void)?
    private var onUpgradeToInstruction: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var onSubmit: (() -> Void)?
    private var onLatchChange: ((Bool) -> Void)?
    private var isRecordingCheck: (() -> Bool)?
    private var isOverlayInteractiveCheck: (() -> Bool)?

    // Modifier flag monitors
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var activeTrigger: TriggerShortcut?
    private var modifierTriggersDown = Set<TriggerShortcut>()
    private var shiftWasDown = false
    private var triggerPressTime: Date?

    // Double-tap toggle support
    private var isLatched = false
    private var stopPending = false
    private var latchTimeoutTask: DispatchWorkItem?

    // Time of the most recent *fresh* press (not a latch-stop tap, not the
    // second half of a double-tap). Double-tap detection is press-to-press
    // off this value, deliberately independent of whether the first tap's
    // recording is still alive - that decoupling is what makes the gesture
    // robust. Cleared whenever a press resolves to something that can't be
    // the first half of a pair (a deliberate hold, or a lone tap that timed
    // out), so press-and-hold can never be mistaken for a double-tap.
    private var lastPressTime: Date?

    // Mode-decision delay - gives Shift a chance to register if pressed
    // near-simultaneously with the trigger. Below human perception threshold.
    private var modeDecisionTask: DispatchWorkItem?
    private let modeDecisionDelay: TimeInterval = 0.018

    // A press held at least this long is an unambiguous push-to-talk hold:
    // release submits immediately. Anything shorter is ambiguous - it might
    // be the first half of a double-tap, so we wait out `doubleTapWindow`
    // before deciding what it was. Takes under 0.5s are discarded downstream
    // (AppState.stopRecording), so a hold that yields real dictation is
    // always longer than this - making 0.45 a divider that can never steal
    // a genuine push-to-talk.
    private let holdThreshold: TimeInterval = 0.45

    // Max gap (press-to-press) for two taps to count as a double-tap, and
    // how long a lone ambiguous tap waits for a partner before it submits
    // (and gets discarded if it was too short to be real dictation).
    private let doubleTapWindow: TimeInterval = 0.45

    // Enter / Esc monitors (work during recording)
    private var keyDownMonitor: Any?
    private var localKeyDownMonitor: Any?

    // CGEventTap for combo and mouse triggers. Matching keyboard events are
    // intercepted so the underlying character isn't typed.
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?

    /// Currently configured trigger inputs. Read live from settings on every
    /// event so user changes take effect without re-registering monitors.
    private var triggerKeys: [TriggerShortcut] {
        SettingsStore.shared.settings.triggerKeys
    }

    private var isTapActivation: Bool {
        SettingsStore.shared.settings.recordingActivation == .tap
    }

    /// Ignore trigger input while Settings is capturing a new shortcut, so
    /// the combo being recorded doesn't also start a dictation take.
    private var isSuspended = false

    func suspend() {
        isSuspended = true
        resetTriggerState()
    }

    func resume() {
        isSuspended = false
    }

    func register(
        onToggle: @escaping () -> Void,
        onInstructionToggle: @escaping () -> Void,
        onUpgradeToInstruction: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onSubmit: @escaping () -> Void,
        onLatchChange: @escaping (Bool) -> Void,
        isRecording: @escaping () -> Bool,
        isOverlayInteractive: @escaping () -> Bool
    ) {
        self.onToggle = onToggle
        self.onInstructionToggle = onInstructionToggle
        self.onUpgradeToInstruction = onUpgradeToInstruction
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        self.onLatchChange = onLatchChange
        self.isRecordingCheck = isRecording
        self.isOverlayInteractiveCheck = isOverlayInteractive
        installFlagsMonitor()
        installKeyMonitor()
        installEventTap()
    }

    /// Reset internal state when configured triggers change mid-session, so
    /// stale held-input state from an old button doesn't confuse the
    /// state machine after the swap. Also re-attempts to install the event
    /// tap, so a user who switches to a combo trigger right after granting
    /// Accessibility doesn't have to wait for the next retry tick.
    func resetTriggerState() {
        modeDecisionTask?.cancel()
        modeDecisionTask = nil
        latchTimeoutTask?.cancel()
        latchTimeoutTask = nil
        activeTrigger = nil
        modifierTriggersDown.removeAll()
        shiftWasDown = false
        triggerPressTime = nil
        lastPressTime = nil
        setLatched(false)
        stopPending = false
        installEventTap()
    }

    /// Promote an in-flight push-to-talk take to a latched one. Called when
    /// the mic produces no signal: the take must survive key release so the
    /// user can open the input-device selector and switch to a working mic
    /// instead of the recording ending the moment they let go of the trigger.
    /// Idempotent - safe to call when already latched.
    func promoteToLatched() {
        // A tap of the trigger from here on means "stop", matching how any
        // other latched take behaves.
        stopPending = false
        setLatched(true)
    }

    /// Single funnel for latch state - the overlay shows explicit
    /// cancel/submit controls during a latched recording, so the UI has
    /// to track every transition.
    private func setLatched(_ value: Bool) {
        isLatched = value
        DispatchQueue.main.async { [weak self] in self?.onLatchChange?(value) }
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
        guard !isSuspended else { return false }
        // Listen to Esc/Enter while *either* a recording is in flight
        // or an interactive overlay is up (the fallback rescue card).
        let recording = isRecordingCheck?() == true
        let overlayInteractive = isOverlayInteractiveCheck?() == true
        guard recording || overlayInteractive else { return false }
        switch event.keyCode {
        case 36, 76: // Return, Enter (numpad) → submit (recording) / dismiss (card)
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
        guard !isSuspended else { return }
        let shiftDown = event.modifierFlags.contains(.shift)
        let modifierTriggers = triggerKeys.filter { !$0.isCombo && !$0.isMouseButton }
        let nowDown = Set(modifierTriggers.filter { $0.isDown(in: event.modifierFlags) })

        // Combo presses arrive through the event tap, but releasing their
        // modifier before the ordinary key-up still counts as a release.
        if let activeTrigger, !activeTrigger.isMouseButton {
            let released = activeTrigger.isCombo
                ? !activeTrigger.isDown(in: event.modifierFlags)
                : !nowDown.contains(activeTrigger)
            if released {
                self.activeTrigger = nil
                handleTriggerRelease()
            }
        }

        // Pick the first newly pressed modifier trigger in the user's list.
        // A single active trigger owns the gesture until it is released.
        if activeTrigger == nil,
           let pressed = modifierTriggers.first(where: {
               nowDown.contains($0) && !modifierTriggersDown.contains($0)
           }) {
            activeTrigger = pressed
            let blocked = !event.modifierFlags.intersection(pressed.blockedFlags).isEmpty
            handleTriggerPress(blocked: blocked)
        }
        modifierTriggersDown = nowDown

        // Shift added while recording → upgrade to instruction (AI) mode.
        // Latched takes (tap activation, double-tap, or already upgraded)
        // don't require the trigger to still be held, so you can add Shift
        // after a tap-to-start.
        if shiftDown && !shiftWasDown
            && isRecordingCheck?() == true
            && (activeTrigger != nil || isLatched) {
            let blocker = activeTrigger ?? triggerKeys.first ?? .fn
            guard event.modifierFlags.intersection(blocker.blockedFlags).isEmpty else {
                shiftWasDown = shiftDown
                return
            }
            setLatched(true)
            DispatchQueue.main.async { [weak self] in
                self?.onUpgradeToInstruction?()
            }
        }
        shiftWasDown = shiftDown
    }

    private func handleTriggerPress(blocked: Bool) {
        let now = Date()
        triggerPressTime = now
        guard !blocked else { return }

        let isCurrentlyRecording = isRecordingCheck?() ?? false

        // A tap-to-toggle recording stops on the second press. Hold mode
        // keeps its existing release-to-stop behavior for latched takes.
        if isCurrentlyRecording && isLatched {
            if isTapActivation {
                setLatched(false)
                stopPending = false
                DispatchQueue.main.async { [weak self] in self?.onToggle?() }
                return
            }
            stopPending = true
            return
        }

        if isTapActivation {
            beginTapRecording()
            return
        }

        // - Second tap of a double-tap → latch. Detected purely from the
        //   press-to-press gap, so it fires whether or not the first tap's
        //   recording is still alive: a slightly-long first tap, a fast
        //   double-click that beat the mode-decision delay, anything. This
        //   is the decoupling that makes the gesture reliable. `lastPressTime`
        //   is only set on a fresh press and cleared once a press resolves to
        //   a deliberate hold, so a real push-to-talk never lands here. -
        if let last = lastPressTime, now.timeIntervalSince(last) < doubleTapWindow {
            lastPressTime = nil
            modeDecisionTask?.cancel(); modeDecisionTask = nil
            latchTimeoutTask?.cancel(); latchTimeoutTask = nil
            stopPending = false
            setLatched(true)
            if !isCurrentlyRecording {
                // First tap never produced a live recording (too fast, or it
                // already submitted) → start one now so the latch holds something.
                DispatchQueue.main.async { [weak self] in self?.onToggle?() }
            }
            return
        }

        // - Fresh press: remember it for double-tap detection, then start a
        //   new recording. Tiny delay so a Shift pressed near-simultaneously
        //   is captured, picking instruction mode. -
        lastPressTime = now
        modeDecisionTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Re-check live modifier state at the moment we actually fire
            let flags = NSEvent.modifierFlags
            guard let trigger = self.activeTrigger else { return }
            let stillTrigger = trigger.isMouseButton || trigger.isDown(in: flags)
            let nowShift = flags.contains(.shift)
            let blockedNow = !flags.intersection(trigger.blockedFlags).isEmpty
            guard stillTrigger, !blockedNow else { return }
            self.modeDecisionTask = nil
            self.stopPending = false
            // Instruction mode is always latched - release shouldn't
            // auto-submit, the user will explicitly submit when they're
            // done adding context.
            self.setLatched(nowShift)
            if nowShift {
                self.onInstructionToggle?()
            } else {
                self.onToggle?()
            }
        }
        modeDecisionTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + modeDecisionDelay, execute: task)
    }

    /// Single tap starts a latched take immediately. Delaying this until after
    /// key-up made fast modifier-only taps and some combo taps disappear.
    private func beginTapRecording() {
        lastPressTime = nil
        latchTimeoutTask?.cancel()
        latchTimeoutTask = nil
        modeDecisionTask?.cancel()
        modeDecisionTask = nil
        stopPending = false
        setLatched(true)

        if NSEvent.modifierFlags.contains(.shift) {
            onInstructionToggle?()
        } else {
            onToggle?()
        }
    }

    private func handleTriggerRelease() {
        if isTapActivation {
            // Tap mode acts on key-down: first press starts, second press
            // stops. Key-up is deliberately inert.
            return
        }

        // - Released before the mode-decision fired: recording never started.
        //   Discard the pending start, but KEEP `lastPressTime` so a fast
        //   follow-up press is still recognised as a double-tap (and starts
        //   the recording latched). -
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
                setLatched(false)
                stopPending = false
                DispatchQueue.main.async { [weak self] in self?.onToggle?() }
            }
            // Plain release while latched - no-op (latched recording stays)
            return
        }

        if duration >= holdThreshold {
            // Held long enough to be an unambiguous push-to-talk → submit
            // now. Clear `lastPressTime`: a deliberate hold is never the
            // first half of a double-tap, so a quick press afterwards must
            // start a fresh recording, not latch onto this one.
            lastPressTime = nil
            DispatchQueue.main.async { [weak self] in self?.onToggle?() }
            return
        }

        // Ambiguous short tap - might be the first half of a double-tap.
        // Keep the recording going for `doubleTapWindow`; the press handler
        // latches if a second tap arrives. Otherwise submit (stopRecording
        // discards anything <0.5s itself, so a lone brief tap is silent).
        latchTimeoutTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.latchTimeoutTask = nil
            self.lastPressTime = nil
            if self.isRecordingCheck?() ?? false && !self.isLatched {
                DispatchQueue.main.async { self.onToggle?() }
            }
        }
        latchTimeoutTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: task)
    }

    // MARK: - CGEventTap (keyboard combos and mouse buttons)

    private func installEventTap() {
        guard eventTap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)
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
            // Tap creation fails if Accessibility isn't granted yet - common
            // right after a fresh build (build.sh resets the permission).
            // Retry every 2s; the guard at the top makes this idempotent
            // once we eventually succeed.
            print("[whisperino] CGEventTap install failed - retrying once Accessibility is granted")
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
        print("[whisperino] CGEventTap installed - keyboard and mouse triggers active")
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

        if isSuspended {
            return Unmanaged.passUnretained(event)
        }

        // Bridge CGEventFlags → NSEvent.ModifierFlags (the device-independent
        // bits use the same layout, so a raw cast is safe for our checks).
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        switch type {
        case .keyDown:
            let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard let trigger = triggerKeys.first(where: {
                $0.comboKeyCode == eventKeyCode
                    && $0.isDown(in: flags)
                    && flags.intersection($0.blockedFlags).isEmpty
            }) else {
                return Unmanaged.passUnretained(event)
            }
            // Auto-repeat fires keyDown repeatedly while held; only act on
            // the initial press so the state machine doesn't see a stream of
            // "presses".
            let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if let activeTrigger, activeTrigger != trigger {
                return Unmanaged.passUnretained(event)
            }
            if !isAutoRepeat && activeTrigger == nil {
                activeTrigger = trigger
                handleTriggerPress(blocked: false)
            }
            return nil  // consume so e.g. "∂" isn't typed
        case .keyUp:
            let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard activeTrigger?.comboKeyCode == eventKeyCode else {
                return Unmanaged.passUnretained(event)
            }
            if activeTrigger != nil {
                activeTrigger = nil
                handleTriggerRelease()
            }
            return nil  // consume keyUp for symmetry
        case .otherMouseDown:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard let trigger = triggerKeys.first(where: { $0.mouseButton == button }) else {
                return Unmanaged.passUnretained(event)
            }
            guard flags.intersection(trigger.blockedFlags).isEmpty else {
                return Unmanaged.passUnretained(event)
            }
            if let activeTrigger, activeTrigger != trigger {
                return Unmanaged.passUnretained(event)
            }
            if activeTrigger == nil {
                activeTrigger = trigger
                handleTriggerPress(blocked: false)
            }
            return nil
        case .otherMouseUp:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard activeTrigger?.mouseButton == button else {
                return Unmanaged.passUnretained(event)
            }
            activeTrigger = nil
            handleTriggerRelease()
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
