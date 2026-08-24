import AppKit
import Carbon
import Combine
import CoreGraphics
import SwiftUI
enum TranscriptionState: Equatable {
    case idle
    case recording
    case transcribing
    case refining
    case result(text: String)
    case dismissing
    case cancelled
    case error(message: String)
}

/// What an attachment carries. AI mode only ever produces `.image` (the screen
/// capture); `.text` remains for the LLM message builder's general shape.
enum AttachmentContent {
    case text(String)
    case image(NSImage)
}

extension NSImage {
    /// A copy scaled so its longest side is at most `maxDimension` points.
    /// Used to make tiny attachment thumbnails once, instead of handing a
    /// full-resolution screenshot to a 24pt image view that re-scales it
    /// on every frame. Returns self if already small enough.
    func downscaled(maxDimension: CGFloat) -> NSImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return self }
        let scale = maxDimension / longest
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        thumb.unlockFocus()
        return thumb
    }
}

/// A single piece of context sent to the LLM. In AI mode this is the screen
/// capture; the type stays general so the message builder is unchanged.
struct AttachedContext: Identifiable {
    let id = UUID()
    let content: AttachmentContent
    let preview: String
    /// A small pre-rendered preview. `nil` for text.
    var thumbnail: NSImage? = nil
}

/// One turn handed to the LLM. AI mode is one-shot, so we only ever build a
/// single user turn per request - but the refiner's message builder is written
/// against this shape (role + text + attachments), so we keep it.
struct ChatTurn: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    /// The image/text context attached for this turn.
    var attachments: [AttachedContext] = []
}

class AppState: ObservableObject {
    @Published var state: TranscriptionState = .idle
    // CoreAudio updates this roughly 90 times per second. It is sampled into
    // `audioSamples` below, so publishing every raw callback only invalidates
    // the entire overlay repeatedly and makes the meter visibly stutter.
    private(set) var audioLevel: Float = 0
    /// True while recording but the mic has produced no real signal since the
    /// take began - almost always the wrong/dead input device. Drives the
    /// "check your mic" nudge above the pill. Cleared the instant real audio
    /// arrives, and reset at the start/end of every take.
    @Published var noAudioDetected: Bool = false
    /// Rolling buffer of recent audio levels for the waveform display.
    /// Index 0 = newest (leftmost bar), last index = oldest. Updated at a
    /// fixed rate so the visual rolls smoothly even when the recorder
    /// callback bursts.
    @Published var audioSamples: [Float] = Array(repeating: 0, count: AppState.waveformBarCount)
    @Published var recordingStartTime: Date?
    /// Whether we are currently in instruction mode (Shift+hotkey)
    @Published var isInstructionMode: Bool = false
    /// Whether the current request is routed to a Langdock Agent
    @Published var isAgentMode: Bool = false
    /// True while the current recording is latched ("press and stay" -
    /// double-tap or AI-mode upgrade): no held key anchors the session,
    /// so the pill shows explicit ✕ / ✓ controls. Driven by HotkeyManager.
    @Published var isLatchedRecording: Bool = false
    /// Raw dictation that had nowhere to go - no focused text field at
    /// paste time. Non-nil shows the fallback result card so the take
    /// isn't lost; Copy or ✕ (or Esc) clears it.
    @Published var fallbackResult: String? = nil
    /// Native tool result / confirmation UI. Tool reads can populate this
    /// directly; side effects must first move through a confirmation card.
    @Published var assistantCard: AssistantCard? = nil
    /// Geometry supplied by OverlayPanel for the display it is anchored to.
    /// On a notched Mac the visible surface starts at y=0 and reserves this
    /// inset for the camera housing, making the UI one continuous silhouette
    /// with the hardware rather than a pill floating underneath it.
    @Published var overlayHasPhysicalNotch = false
    /// True when the live surface should merge into the display's top edge.
    /// This includes both a real MacBook notch and the virtual island used on
    /// an attached external display.
    @Published var overlayUsesTopEdgeSurface = false
    @Published var overlayNotchInset: CGFloat = 0
    /// Camera-housing width measured from the display's auxiliary menu-bar
    /// regions. Compact notch UI grows outward from this exact width.
    @Published var overlayPhysicalNotchWidth: CGFloat = 210
    /// Display chosen from the focused text caret/window when a take begins.
    /// OverlayPanel uses this stable CG display id for the full take so the
    /// notch appears beside the field being dictated into, regardless of
    /// which display macOS considers "main" or whether an external exists.
    @Published private(set) var overlayTargetDisplayID: CGDirectDisplayID?
    /// Explicit lifecycle for agent/edit sessions. Dictation keeps using the
    /// lightweight transcription state; every assistant callback must match
    /// this session id before it can mutate the surface.
    @Published private(set) var assistantSession: AssistantSessionState? = nil
    /// Seconds the fallback card lingers before auto-dismissing. The
    /// overlay's countdown ring animates over this same duration.
    static let fallbackTimeout: TimeInterval = 8
    private var fallbackTimer: Timer?
    /// Available audio input devices
    @Published var inputDevices: [AudioInputDevice] = []
    /// Currently selected input device (nil = system default)
    @Published var selectedInputDevice: AudioInputDevice?
    /// Whether the input device picker is currently shown in the overlay
    @Published var showingInputPicker = false
    /// When true, the overlay skips state-change animation (used for cancel)
    var suppressStateAnimation = false

    /// Raw text transcribed so far in the current take (rolling chunks).
    /// Drives the live preview strip in the overlay and doubles as the
    /// partial result we can salvage if a later stage fails.
    @Published var liveTranscript: String = ""
    /// True while streaming partials are being rendered directly in the text
    /// element that was focused when the take began. When false, the overlay
    /// owns the visual preview instead.
    @Published private(set) var streamsTranscriptIntoFocusedField = false
    /// Chunk progress for the transcribing pill ("3/5"). Total counts
    /// every chunk submitted so far; done counts completed whisper runs.
    @Published var chunksDone: Int = 0
    @Published var chunksTotal: Int = 0

    /// Number of bars shown in the waveform display.
    static let waveformBarCount = 13

    // MARK: - AI mode (one-shot, screenshot-grounded)

    /// Draws the brief frame around the window AI mode screenshotted.
    private let windowHighlighter = WindowHighlighter()
    /// The in-flight screen capture for the current AI take. Kicked off at
    /// record start and awaited at submit, so even a very short take still
    /// gets the screenshot as context - and it never shows as a chip, keeping
    /// the pill identical to plain dictation.
    private var screenshotTask: Task<NSImage?, Never>?
    /// We only pop the Screen Recording prompt once per launch. Without this,
    /// every AI-mode press while ungranted re-opens System Settings.
    private var didRequestScreenPermission = false

    private(set) var lastTranscriptionResult: String?
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let refiner = LLMRefiner()
    private let agentClient = AgentClient()
    private let store = SettingsStore.shared
    private let assistantTools = AssistantToolRegistry(tools: [
        LocalFinderAssistantTool(),
        OpenLocalFileAssistantTool(),
        CreateCalendarEventAssistantTool(),
        WebSearchAssistantTool(),
    ])
    private lazy var assistantPlanner = AssistantPlanner(descriptors: assistantTools.descriptors)
    private var assistantResponseTask: Task<Void, Never>?
    private var pendingAssistantInvocation: PreparedToolInvocation?

    /// PID of the app that was frontmost when recording started. Final
    /// delivery reactivates this process before posting Cmd+V; Accessibility
    /// elements in Electron and terminal surfaces are too transient to use as
    /// a cross-take identity boundary.
    private var recordingTargetPID: pid_t?

    /// Identifies both microphone setup and the live take it produces. Audio
    /// startup is asynchronous because CoreAudio can block after device churn;
    /// this token prevents a cancelled or timed-out attempt from updating a
    /// newer take.
    private var recordingToken: UUID?

    /// Owns the confirmed pause/resume lease for the current take. Playback is
    /// resumed only when this controller positively observed and paused it.
    private let mediaPlaybackController = MediaPlaybackController()

    /// Language is snapshotted once per take so a Settings change cannot make
    /// later rolling chunks use a different recognizer language.
    private var recordingLanguageCodes: [String] = []

    /// Whether, at the moment recording started, the target app had a
    /// focused editable text element. Captured then - not at paste time -
    /// because that's when the target is reliably frontmost and its field
    /// genuinely focused (our overlay is non-activating and the detached
    /// chat tile hasn't stolen focus yet). Defaults to true so we paste
    /// whenever the answer is unknown rather than withholding.
    private var recordingTargetEditable = true
    /// Accessibility-backed provisional range used by streaming recognizers.
    /// It survives recording stop so the final/refined text can replace the
    /// partial hypothesis without a second paste.
    private var liveTextInserter: LiveTextInserter?
    /// Partial hypotheses can arrive every ~80 ms. Limit visible field edits
    /// to a steady cadence and coalesce superseded tails so synthetic keyboard
    /// events never pile up behind the recognizer.
    private var pendingLiveTextInsertion: DispatchWorkItem?
    private var lastLiveTextInsertionTime: TimeInterval = 0
    private let liveTextInsertionInterval: TimeInterval = 0.12
    /// Cross-process AX calls occasionally return a transient failure while a
    /// browser applies the previous edit. Keep the owned field alive long
    /// enough for the next complete hypothesis to retry it.
    private var consecutiveLiveTextInsertionFailures = 0
    /// A provisional range could not be restored after the target editor was
    /// changed externally. The final result must use the rescue card instead
    /// of risking a duplicate clipboard paste.
    private var liveTextInsertionRequiresRescue = false

    // MARK: Rolling chunked transcription

    /// Pipeline transcribing finished chunks in the background while the
    /// user is still speaking. One per take; nil when not recording.
    private var transcriptionSession: TranscriptionSession?
    /// True when this take feeds live PCM into a transcribe.cpp stream
    /// (Nemotron) instead of rotating WAV chunks.
    private var streamingTake = false
    /// Snapshot of the user-visible streaming preference for this take. The
    /// model can keep its streaming decoder internally while partial words are
    /// hidden until finalization.
    private var publishesStreamingPartialsForTake = false
    private var settingsObserver: AnyCancellable?
    /// Ticks once a second during recording to decide when to rotate the
    /// audio file into a new chunk.
    private var chunkTimer: Timer?
    private var currentChunkStart: Date?
    /// From this age on, the chunk is cut at the next silence so words
    /// aren't clipped mid-sentence.
    private static let chunkSoftSeconds: TimeInterval = 40
    /// Absolute cap - rotate even mid-speech. Keeps every whisper run
    /// bounded no matter how long the user talks without pausing.
    private static let chunkHardSeconds: TimeInterval = 90
    /// Below this gated level the room is considered silent (the meter
    /// noise gate already forces ambient noise to 0).
    private static let chunkSilenceLevel: Float = 0.02

    // MARK: No-audio nudge

    /// Set true once the current take produces genuine captured audio. A mic
    /// that's actually working trips this within a beat, so the nudge never
    /// nags a live session.
    private var heardRealAudio = false
    /// Fires at most once per take. The nudge is a one-shot: after its
    /// auto-dismiss clears `noAudioDetected`, this stops the timer tick from
    /// re-raising it every second.
    private var didNudgeNoAudio = false
    /// Auto-dismisses the nudge a few seconds after it appears.
    private var noAudioNudgeTimer: Timer?
    /// How long the nudge lingers before fading out on its own.
    private static let noAudioNudgeDuration: TimeInterval = 3
    /// A gated level at/above this counts as genuine captured audio. This is
    /// intentionally below the chunk-rotation silence threshold: softly
    /// spoken words should prove the microphone is alive even when they are
    /// not strong enough to influence long-recording chunk boundaries.
    private static let noAudioLevelThreshold: Float = 0.012
    /// How long the mic may stay completely silent from take start before we
    /// surface the nudge. Deliberately generous - this should fire for a
    /// wrong/dead device, not for a thoughtful pause before speaking.
    private static let noAudioGraceSeconds: TimeInterval = 3

    /// Drives the waveform's rolling history at a deliberately calm cadence.
    /// Keeping UI publication on this timer (rather than every CoreAudio
    /// buffer) prevents the compact notch indicator from flickering.
    private var sampleTimer: Timer?

    var isSetUp: Bool { transcriber.isAvailable }

    /// Pre-load the selected GGUF onto Metal so the first dictation
    /// does not pay the model-load cost. Call at launch.
    func warmUpTranscriber() {
        transcriber.warmUp()
        if settingsObserver == nil {
            settingsObserver = store.$settings
                .map(\.asrModel)
                .removeDuplicates()
                .dropFirst()
                .sink { [weak self] id in
                    self?.transcriber.select(id)
                }
        }
    }

    /// Drop the resident Metal model. Call at app termination.
    func shutdownTranscriber() {
        transcriber.shutdown()
    }

    // MARK: - Input Device Management

    /// Whether the user has pinned a preferred mic (vs. following the system
    /// default). Drives the "Follow system default" row's checkmark.
    var hasPreferredInputDevice: Bool {
        store.settings.preferredInputDeviceUID != nil
    }

    /// Refresh the list of available input devices and resolve the current
    /// selection. A pinned preferred mic (stored by UID) always wins when it's
    /// connected - this is what survives a display/dock unplug-replug that
    /// resets the macOS default back to the built-in mic. When no preference is
    /// set, or the preferred mic is currently absent, we follow the system
    /// default instead.
    func refreshInputDevices() {
        inputDevices = AudioRecorder.availableInputDevices()

        // A connected preferred mic always wins - re-resolving by UID also
        // refreshes its (transient) AudioDeviceID after a reconnect.
        if let uid = store.settings.preferredInputDeviceUID,
           let preferred = inputDevices.first(where: { $0.uid == uid }) {
            selectedInputDevice = preferred
            return
        }

        // No preference (or the preferred mic is unplugged): follow the system
        // default. The preference stays stored so it re-applies the moment the
        // mic comes back.
        if let defaultID = AudioRecorder.defaultInputDeviceID() {
            selectedInputDevice = inputDevices.first { $0.id == defaultID }
        } else {
            selectedInputDevice = inputDevices.first
        }
    }

    /// Persist the choice immediately, but defer the observable row selection
    /// and CoreAudio graph rebuild until the notch has finished collapsing.
    /// Updating the selected row in the same transaction as dismissal made its
    /// icon and label animate sideways with the disappearing list.
    func selectInputDeviceAfterPickerCollapse(_ device: AudioInputDevice) {
        store.settings.preferredInputDeviceUID = device.uid
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            guard let self,
                  self.store.settings.preferredInputDeviceUID == device.uid else { return }
            self.selectedInputDevice = device
            self.applyInputDeviceNow(device)
        }
    }

    func clearPreferredInputDeviceAfterPickerCollapse() {
        store.settings.preferredInputDeviceUID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            guard let self,
                  self.store.settings.preferredInputDeviceUID == nil else { return }
            self.selectedInputDevice = nil
            self.refreshInputDevices()
            guard let device = self.selectedInputDevice else { return }
            self.applyInputDeviceNow(device)
        }
    }

    private func applyInputDeviceNow(_ device: AudioInputDevice) {
        guard case .recording = state else { return }
        recorder.switchDevice(device)
    }

    // MARK: - Hotkey handlers

    func hotkeyToggle() {
        toggleRecording(instruction: false)
    }

    func instructionHotkeyToggle() {
        toggleRecording(instruction: true)
    }

    /// Upgrade an in-progress dictation session to instruction (AI) mode.
    /// Called when the user adds Shift while already holding Fn and
    /// recording. Validates the LLM is configured, flips the mode flag (so
    /// the gradient border animates in via SwiftUI), grabs the screen as
    /// context, and starts clipboard auto-capture.
    func upgradeToInstructionMode() {
        guard case .recording = state else { return }
        guard !isInstructionMode else { return }

        let settings = store.settings
        // Require API key + AI mode enabled, just like a fresh AI-mode start
        guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              settings.aiModeEnabled else { return }
        // Needs Screen Recording. Without it, fire the prompt and abort the
        // take entirely - the user pressed ⇧ meaning "AI", and AI isn't usable
        // yet, so we tear down the in-flight dictation rather than leaving its
        // pill on screen next to the permission dialog. Silent (→ .idle) so no
        // cancel flash. Once granted + relaunched, the next press records.
        guard ScreenCapture.hasPermission() else {
            requestScreenPermissionOnce()
            teardownRecording(finalState: .idle)
            return
        }

        // Raw ASR partials belong in the target field only for plain
        // dictation. Upgrading to AI mode restores the original selection;
        // the spoken instruction will now stream in the overlay instead.
        discardLiveTextInsertion(protectFinalDelivery: true)
        isInstructionMode = true
        // Same screen grab a fresh AI take does - the user just decided this
        // take is a question about what's on screen.
        captureScreenContext(pid: recordingTargetPID)
    }

    private func toggleRecording(instruction: Bool) {
        switch state {
        case .idle, .result, .error, .dismissing, .cancelled:
            startRecording(instruction: instruction)
        case .recording:
            // No min-duration gate here - push-to-talk users may briefly
            // tap Fn. stopRecording() discards anything <0.5s itself.
            stopRecording()
        case .transcribing, .refining:
            break
        }
    }

    // MARK: - Toggle Recording (waveform tap)

    func toggleRecording() {
        toggleRecording(instruction: isInstructionMode)
    }

    // MARK: - Cancel

    func cancelRecording() {
        if assistantCard != nil {
            dismissAssistantCard()
            return
        }
        // Esc while the fallback result card is up = close the card.
        // Nothing else can be in flight in that state.
        if fallbackResult != nil {
            dismissFallback()
            return
        }
        teardownRecording(finalState: .cancelled)
    }

    /// Stop the recorder and reset everything, ending in `finalState`.
    /// `.cancelled` plays the cancel flash; `.idle` tears down silently (used
    /// when a take is aborted with no user-facing "cancelled" feedback).
    private func teardownRecording(finalState: TranscriptionState) {
        assistantResponseTask?.cancel()
        assistantResponseTask = nil
        pendingAssistantInvocation = nil
        if var session = assistantSession {
            session.transition(to: .cancelled, label: "Cancelled")
            assistantSession = session
        }
        showingInputPicker = false
        isLatchedRecording = false
        noAudioDetected = false
        noAudioNudgeTimer?.invalidate()
        noAudioNudgeTimer = nil
        windowHighlighter.dismiss()
        screenshotTask?.cancel()
        screenshotTask = nil
        abandonTranscriptionSession()
        recordingToken = nil
        if let url = recorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        resumeMediaAfterRecordingIfNeeded()
        stopWaveformSampling()
        audioLevel = 0
        recordingStartTime = nil
        recordingTargetPID = nil
        resetInstructionMode()
        state = finalState
    }

    /// Enter / "finish" gesture. While recording it submits the take; while a
    /// prepared action card is visible it approves that exact invocation.
    func submitOrFinish() {
        switch state {
        case .recording:
            stopRecording()
        default:
            if assistantCard != nil, pendingAssistantInvocation != nil {
                approveAssistantAction()
            } else if assistantCard != nil {
                dismissAssistantCard()
            } else if fallbackResult != nil {
                dismissFallback()
            }
        }
    }

    // MARK: - Waveform sampling

    private func startWaveformSampling() {
        audioSamples = Array(repeating: 0, count: Self.waveformBarCount)
        sampleTimer?.invalidate()
        // Publish at 30 Hz so speech and silence reach the notch within one
        // display frame or two. The meter applies its own restrained visual
        // envelope, so this higher cadence stays smooth without feeling late.
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            var s = self.audioSamples
            // Store the real envelope without an artificial historical fade.
            // Newest-first means each actual spoken peak advances one fixed
            // position to the right per tick, then leaves the meter promptly.
            s.removeLast()
            s.insert(self.audioLevel, at: 0)
            self.audioSamples = s
        }
    }

    private func stopWaveformSampling() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        audioSamples = Array(repeating: 0, count: Self.waveformBarCount)
    }

    // MARK: - Recording

    /// Single sink for the recorder's level callback (both fresh start and
    /// mid-take device switch). Feeds the live waveform and clears the
    /// no-audio nudge the moment genuine signal arrives.
    private func handleAudioLevel(_ level: Float) {
        audioLevel = level
        // Waveform publication is intentionally left to the 30 Hz sampler.
        // Publishing on every CoreAudio buffer made the whole overlay redraw
        // roughly 90 times per second and caused the indicator to feel laggy.
        // Any real signal means the mic is alive: latch that for the take and
        // retract the nudge if it had appeared.
        if level >= Self.noAudioLevelThreshold {
            heardRealAudio = true
            if noAudioDetected { noAudioDetected = false }
        }
    }

    private func startRecording(instruction: Bool) {
        // v3.2.5 could begin a take in the brief half-authorized state after a
        // fresh Accessibility toggle. With no exact AX element captured, its
        // safety gate correctly withheld the final paste. Do not record until
        // the grant is active in a freshly relaunched process.
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.async {
                AccessibilityPermissionController.shared.requestIfNeeded()
            }
            return
        }

        // Clear presentation data before `discardLiveTextInsertion()` flips
        // the destination flag. Otherwise SwiftUI can briefly render the
        // previous take in the notch while microphone setup is starting.
        liveTranscript = ""
        chunksDone = 0
        chunksTotal = 0
        discardLiveTextInsertion()
        // A fresh take supersedes a lingering fallback card.
        fallbackResult = nil
        assistantCard = nil
        assistantResponseTask?.cancel()
        assistantResponseTask = nil
        pendingAssistantInvocation = nil
        assistantSession = nil
        // Reset per-take mic-liveness tracking.
        heardRealAudio = false
        didNudgeNoAudio = false
        noAudioDetected = false
        noAudioNudgeTimer?.invalidate()
        noAudioNudgeTimer = nil
        guard isSetUp else {
            let name = transcriber.selectedDescriptor.shortLabel
            if case .downloading = ModelDownloader.shared.status {
                state = .error(message: "Downloading \(name)…")
            } else {
                state = .error(message: "Download \(name) in Settings")
            }
            autoDismiss(after: 4)
            return
        }

        isInstructionMode = instruction

        if instruction {
            // AI mode requires API key + the AI-mode toggle. Refinement
            // is independent - users may want raw transcription but still
            // use AI mode, or vice versa.
            let settings = store.settings
            if settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state = .error(message: "Add API key in Settings first")
                autoDismiss(after: 3)
                return
            }
            guard settings.aiModeEnabled else {
                state = .error(message: "Enable Talk to your screen in Settings first")
                autoDismiss(after: 3)
                return
            }
            // AI mode needs Screen Recording for the screenshot. Until it's
            // granted, don't start a take at all - just fire the prompt. A
            // recording here would drop the pill into the permission dialog and
            // capture a useless (screenshot-less) take. Once granted and the
            // app is relaunched, the next press records normally.
            guard ScreenCapture.hasPermission() else {
                requestScreenPermissionOnce()
                isInstructionMode = false
                state = .idle
                return
            }

            assistantSession = AssistantSessionState(phase: .listening)
        }

        // Capture the frontmost app so we can reactivate it before pasting,
        // plus whether it has a focused editable field *right now* - while the
        // target is frontmost and its caret is live, which is the only moment
        // this can be read reliably.
        recordingTargetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focusedTarget = Self.focusedEditableTarget()
        overlayTargetDisplayID = ScreenCapture.targetDisplayID(
            focusedElement: focusedTarget.element,
            pid: recordingTargetPID
        )
        recordingTargetEditable = focusedTarget.editable
        // Offline models do not need a writable Accessibility range. When the
        // frontmost app exists and focus was not positively classified as
        // non-editable, the compatibility path will reactivate that app and
        // paste there. Reserve that destination now so a transient/missing AX
        // element in Cursor or a terminal does not flash the transcript card
        // immediately before the paste.
        streamsTranscriptIntoFocusedField = !instruction
            && focusedTarget.editable
            && recordingTargetPID != nil
        publishesStreamingPartialsForTake = transcriber.supportsStreaming
            && store.settings.streamingTranscriptionEnabled
        if publishesStreamingPartialsForTake, !instruction {
            if focusedTarget.supportsLiveInsertion,
               let element = focusedTarget.element,
               let inserter = LiveTextInserter(element: element) {
                liveTextInserter = inserter
                consecutiveLiveTextInsertionFailures = 0
                recordingTargetEditable = true
                streamsTranscriptIntoFocusedField = true
            } else if !AXIsProcessTrusted() {
                streamsTranscriptIntoFocusedField = false
                NSLog("[whisperino] live field unavailable: Accessibility permission is not active")
            } else {
                streamsTranscriptIntoFocusedField = false
                NSLog("[whisperino] live field unavailable: focused element exposes no writable text range")
            }
        }

        // Pause before AVAudioEngine and the optional start sound become
        // active, otherwise our own audio session could make the output query
        // look busy and turn an idle Play/Pause toggle into accidental play.
        recordingLanguageCodes = store.settings.transcriptionLanguageCodes
        if store.settings.pauseMediaOnRecordingStart {
            mediaPlaybackController.pauseIfPlaying()
        }

        // AI mode: silently grab the current screen as image context and flash
        // a frame around the window we captured, so the user can just talk to
        // whatever's on screen. Done before recording so the model reasons
        // about the screen as it looked when the user started, not after any
        // reaction to the pill.
        if instruction {
            captureScreenContext(pid: recordingTargetPID)
        }

        // AVAudioEngine.inputNode may block indefinitely inside CoreAudio after
        // sleep or device churn. Treat setup as part of the recording state so
        // releasing Fn/Esc can cancel it, but do the HAL work off-main. The
        // recorder resolves the persistent UID at the last possible moment,
        // rather than trusting a cached AudioDeviceID.
        let token = UUID()
        recordingToken = token
        recordingStartTime = nil
        state = .recording
        transcriber.prepareTake()
        recorder.start(
            preferredDeviceUID: store.settings.preferredInputDeviceUID,
            levelCallback: { [weak self] level in
                DispatchQueue.main.async {
                    guard let self,
                          self.recordingToken == token,
                          case .recording = self.state else { return }
                    self.handleAudioLevel(level)
                }
            },
            recoveredChunkCallback: { [weak self] url in
                self?.handleRecoveredRecorderChunk(url, token: token)
            },
            streamFailureCallback: { [weak self] error in
                self?.handleRecorderStreamFailure(error, token: token)
            },
            pcmCallback: { [weak self] samples in
                self?.transcriber.feedPCM(samples)
            },
            completion: { [weak self] result in
                guard let self,
                      self.recordingToken == token,
                      case .recording = self.state else { return }
                switch result {
                case .success:
                    self.startWaveformSampling()
                    self.startTranscriptionSession(instruction: instruction)
                    SoundEffects.playStart()
                    self.recordingStartTime = Date()
                case .failure(let error):
                    self.recordingToken = nil
                    self.resumeMediaAfterRecordingIfNeeded()
                    self.isLatchedRecording = false
                    HotkeyManager.shared.resetTriggerState()
                    self.windowHighlighter.dismiss()
                    self.screenshotTask?.cancel()
                    self.screenshotTask = nil
                    self.discardLiveTextInsertion()
                    self.recordingTargetPID = nil
                    self.resetInstructionMode()
                    if var session = self.assistantSession {
                        session.transition(
                            to: .failed(error.localizedDescription),
                            label: "Microphone failed"
                        )
                        self.assistantSession = session
                    }
                    self.state = .error(message: "Mic error: \(error.localizedDescription)")
                    self.autoDismiss(after: 4)
                }
            }
        )
    }

    /// A Bluetooth route rebuild may change sample rate. AudioRecorder closes
    /// the old WAV before rebuilding and hands any useful prefix back here so
    /// it enters the same ordered transcription pipeline as a timed chunk.
    private func handleRecoveredRecorderChunk(_ url: URL, token: UUID) {
        guard recordingToken == token,
              case .recording = state,
              !streamingTake,
              let session = transcriptionSession else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        currentChunkStart = Date()
        session.submit(chunkURL: url)
        chunksTotal = session.chunksSubmitted
    }

    private func handleRecorderStreamFailure(_ error: Error, token: UUID) {
        guard recordingToken == token, case .recording = state else { return }
        recordingToken = nil
        if let url = recorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        resumeMediaAfterRecordingIfNeeded()
        stopWaveformSampling()
        abandonTranscriptionSession()
        audioLevel = 0
        recordingStartTime = nil
        recordingTargetPID = nil
        isLatchedRecording = false
        showingInputPicker = false
        resetInstructionMode()
        state = .error(message: "Mic error: \(error.localizedDescription)")
        autoDismiss(after: 4)
    }

    // MARK: - AI screen context

    /// Start grabbing the current display as image context for AI mode and
    /// flash a frame around the focused window. Both are best-effort: no Screen
    /// Recording grant (or any failure) just means this take goes without a
    /// screenshot. The capture runs concurrently and is awaited at submit.
    /// Only called once Screen Recording is granted (callers gate on it), so the
    /// capture is expected to succeed. Flash a frame around the focused window
    /// and kick off the capture to be awaited at submit.
    private func captureScreenContext(pid: pid_t?) {
        screenshotTask?.cancel()
        let windowFrame = ScreenCapture.focusedWindowFrame(pid: pid)
        if let windowFrame {
            windowHighlighter.flash(frame: windowFrame)
        }
        screenshotTask = Task {
            await ScreenCapture.captureActiveDisplay(windowFrame: windowFrame)
        }
    }

    /// Fire the Screen Recording prompt at most once per launch, so an
    /// ungranted user isn't sent to System Settings on every AI-mode press.
    private func requestScreenPermissionOnce() {
        guard !didRequestScreenPermission else { return }
        didRequestScreenPermission = true
        ScreenCapture.requestPermission()
    }

    /// Await the pending screen capture (if any) and wrap it as an attachment.
    /// Static so the response Task can call it without touching mutable
    /// instance state off the main actor.
    private static func resolveScreenshotAttachment(_ task: Task<NSImage?, Never>?) async -> AttachedContext? {
        guard let image = await task?.value else { return nil }
        let w = Int(image.size.width)
        let h = Int(image.size.height)
        return AttachedContext(
            content: .image(image),
            preview: "Screen (\(w)×\(h))",
            thumbnail: image.downscaled(maxDimension: 48)
        )
    }

    // MARK: - Rolling chunked transcription

    /// Create the per-take pipeline and start the rotation timer. Long
    /// recordings get transcribed in ~40–90s chunks *while the user is
    /// still talking*, so stopping a 30-minute take only waits on the
    /// final chunk instead of one giant multi-minute whisper run.
    /// Streaming models (Nemotron) skip the WAV chunks and consume PCM live.
    private func startTranscriptionSession(instruction: Bool) {
        liveTranscript = ""
        chunksDone = 0
        chunksTotal = 0
        streamingTake = transcriber.supportsStreaming

        if streamingTake {
            let languages = recordingLanguageCodes
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.transcriber.startStream(languages: languages) { [weak self] text in
                        DispatchQueue.main.async {
                            guard let self,
                                  case .recording = self.state,
                                  self.streamingTake else { return }
                            if self.publishesStreamingPartialsForTake {
                                self.handleStreamingPartial(text)
                            }
                            if !text.isEmpty {
                                let recovery = FileManager.default.homeDirectoryForCurrentUser
                                    .appendingPathComponent(".whisperino/recovery/last-raw-transcript.txt")
                                try? text.write(to: recovery, atomically: true, encoding: .utf8)
                            }
                        }
                    }
                } catch {
                    print("[whisperino] stream start failed (\(error.localizedDescription)) - falling back to offline chunks")
                    await MainActor.run { [weak self] in
                        guard let self, case .recording = self.state else { return }
                        self.streamingTake = false
                        self.publishesStreamingPartialsForTake = false
                        self.discardLiveTextInsertion(protectFinalDelivery: true)
                        self.beginChunkedSession()
                    }
                }
            }
        } else {
            beginChunkedSession()
        }

        currentChunkStart = Date()
        chunkTimer?.invalidate()
        chunkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.chunkTimerTick()
        }
    }

    private func beginChunkedSession() {
        let session = TranscriptionSession(
            transcriber: transcriber,
            languages: recordingLanguageCodes
        )
        session.onProgress = { [weak self] progress in
            guard let self = self else { return }
            self.liveTranscript = progress.text
            self.chunksDone = progress.chunksDone
            self.chunksTotal = max(self.chunksTotal, progress.chunksTotal)
        }
        transcriptionSession = session
    }

    /// Publish every revised streaming hypothesis to exactly one visual
    /// destination: the focused text range when AX editing is available, or
    /// the overlay when it is not. `liveTranscript` is always retained for
    /// recovery and finalization regardless of destination.
    private func handleStreamingPartial(_ text: String) {
        liveTranscript = text
        guard let inserter = liveTextInserter else { return }
        // Do not erase an existing selection for an initial empty hypothesis.
        guard !text.isEmpty || inserter.hasInsertedText else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let wait = liveTextInsertionInterval - (now - lastLiveTextInsertionTime)
        pendingLiveTextInsertion?.cancel()
        pendingLiveTextInsertion = nil
        if wait <= 0 {
            applyStreamingPartial(text, to: inserter)
            return
        }

        let work = DispatchWorkItem { [weak self, weak inserter] in
            guard let self, let inserter,
                  self.liveTextInserter === inserter else { return }
            self.pendingLiveTextInsertion = nil
            self.applyStreamingPartial(text, to: inserter)
        }
        pendingLiveTextInsertion = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func applyStreamingPartial(_ text: String, to inserter: LiveTextInserter) {
        guard liveTextInserter === inserter else { return }
        lastLiveTextInsertionTime = ProcessInfo.processInfo.systemUptime
        if inserter.replace(with: text) {
            consecutiveLiveTextInsertionFailures = 0
            return
        }

        consecutiveLiveTextInsertionFailures += 1
        guard consecutiveLiveTextInsertionFailures >= 3 else { return }

        // Three explicit AX errors in a row means the field genuinely
        // detached. A single stale/transient browser response no longer sends
        // all remaining speech to the notch.
        inserter.rollback()
        liveTextInsertionRequiresRescue = inserter.hasInsertedText
        liveTextInserter = nil
        streamsTranscriptIntoFocusedField = false
    }

    private func chunkTimerTick() {
        guard case .recording = state,
              let chunkStart = currentChunkStart,
              let session = transcriptionSession else { return }

        // Nudge check: if the mic hasn't produced any real signal within the
        // grace window, it's almost certainly the wrong/dead device. Surface
        // the "check your mic" hint; handleAudioLevel clears it if audio
        // starts flowing (e.g. the user switches to the right input).
        if !heardRealAudio, !didNudgeNoAudio,
           let start = recordingStartTime,
           Date().timeIntervalSince(start) >= Self.noAudioGraceSeconds {
            didNudgeNoAudio = true
            noAudioDetected = true
            // Promote a plain hold-to-talk take to a latched one so the
            // input-device selector appears alongside the nudge and the take
            // survives trigger release - the user can switch to a working mic
            // right there. Already-latched takes (double-tap / AI mode) keep
            // their selector, so they just get the nudge.
            if !isLatchedRecording {
                isLatchedRecording = true
                HotkeyManager.shared.promoteToLatched()
            }
            // Put the recovery action directly in front of the user. Device
            // enumeration was already refreshed when the recording panel was
            // presented, so this is a state-only, animation-safe operation.
            showingInputPicker = true
            // Fade it out on its own after a few seconds - the mic selector
            // stays open, so the hint has done its job.
            noAudioNudgeTimer?.invalidate()
            noAudioNudgeTimer = Timer.scheduledTimer(
                withTimeInterval: Self.noAudioNudgeDuration, repeats: false
            ) { [weak self] _ in
                self?.noAudioDetected = false
            }
        }

        let elapsed = Date().timeIntervalSince(chunkStart)
        // Streaming models consume PCM live; WAV rotation is only for
        // offline families (Whisper / Parakeet) that run on finished files.
        guard !streamingTake else { return }
        // Prefer cutting at silence so words aren't clipped; the hard cap
        // guarantees rotation even if the user never pauses for breath.
        let silent = audioLevel < Self.chunkSilenceLevel
        let shouldRotate = (elapsed >= Self.chunkSoftSeconds && silent)
            || elapsed >= Self.chunkHardSeconds
        guard shouldRotate, let finishedChunk = recorder.rotateChunk() else { return }

        currentChunkStart = Date()
        session.submit(chunkURL: finishedChunk)
        chunksTotal = session.chunksSubmitted
    }

    /// Tear down the rolling pipeline without consuming its result
    /// (cancel / close-chat paths).
    private func abandonTranscriptionSession() {
        chunkTimer?.invalidate()
        chunkTimer = nil
        currentChunkStart = nil
        transcriptionSession?.cancel()
        transcriptionSession = nil
        transcriber.cancelStream()
        streamingTake = false
        publishesStreamingPartialsForTake = false
        discardLiveTextInsertion()
        liveTranscript = ""
        chunksDone = 0
        chunksTotal = 0
    }

    /// Resume only playback that this take actually paused. The explicit Play
    /// command is idempotent, unlike a Play/Pause toggle, so a player that has
    /// already resumed itself remains playing.
    private func resumeMediaAfterRecordingIfNeeded() {
        mediaPlaybackController.resumeIfWePaused()
    }

    private func stopRecording() {
        showingInputPicker = false
        noAudioDetected = false
        noAudioNudgeTimer?.invalidate()
        noAudioNudgeTimer = nil
        // The latch ends with the take (Enter-submit bypasses the
        // HotkeyManager release path, so clear it here too).
        isLatchedRecording = false
        // Recording is over - no more rotations. The session itself stays
        // alive: it still has to chew through any queued chunks plus the
        // final one we're about to hand it.
        chunkTimer?.invalidate()
        chunkTimer = nil
        currentChunkStart = nil

        // Cancels an in-flight CoreAudio setup as well as identifying late
        // level/completion callbacks from this take as stale.
        recordingToken = nil

        let stoppedAudioURL = recorder.stop()
        resumeMediaAfterRecordingIfNeeded()
        guard let audioURL = stoppedAudioURL else {
            abandonTranscriptionSession()
            stopWaveformSampling()
            resetInstructionMode()
            assistantSession = nil
            state = .idle
            return
        }
        stopWaveformSampling()
        SoundEffects.playStop()
        audioLevel = 0
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartTime = nil

        guard duration >= 0.5 else {
            try? FileManager.default.removeItem(at: audioURL)
            abandonTranscriptionSession()
            resetInstructionMode()
            assistantSession = nil
            state = .idle
            return
        }

        state = .transcribing

        let instructionMode = isInstructionMode
        let assistantSessionID = instructionMode ? assistantSession?.id : nil
        if instructionMode, var assistantSession {
            assistantSession.transition(to: .transcribing, label: "Transcribing locally")
            self.assistantSession = assistantSession
        }
        // Snapshot the in-flight screen capture on the main actor so the
        // response Task reads a stable reference (resetInstructionMode may
        // clear the property concurrently).
        let pendingShot = screenshotTask

        // Streaming models finalize the same live stream on release.
        // Offline models hand the file to the rolling pipeline.
        let usedStreaming = streamingTake
        let pipeline: TranscriptionSession?
        if usedStreaming {
            transcriptionSession = nil
            streamingTake = false
            pipeline = nil
        } else {
            let session = transcriptionSession ?? TranscriptionSession(
                transcriber: transcriber,
                languages: recordingLanguageCodes
            )
            transcriptionSession = nil
            streamingTake = false
            session.submit(chunkURL: audioURL)
            chunksTotal = session.chunksSubmitted
            pipeline = session
        }

        assistantResponseTask = Task {
            do {
                let rawText: String
                if usedStreaming {
                    rawText = try await self.transcriber.finishTake(
                        audioURL: audioURL,
                        languages: recordingLanguageCodes
                    )
                    try? FileManager.default.removeItem(at: audioURL)
                } else if let pipeline {
                    rawText = try await pipeline.finish()
                } else {
                    rawText = ""
                }
                try Task.checkCancellation()

                guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    await MainActor.run {
                        self.discardLiveTextInsertion()
                        self.state = .error(message: "No speech detected")
                        if let assistantSessionID {
                            _ = self.updateAssistantSession(
                                assistantSessionID,
                                phase: .failed("No speech detected"),
                                label: "No speech detected"
                            )
                        }
                        self.resetInstructionMode()
                        self.autoDismiss(after: 2)
                    }
                    return
                }

                await MainActor.run {
                    self.state = .refining
                    if let assistantSessionID {
                        if var session = self.assistantSession,
                           session.id == assistantSessionID {
                            session.transcript = rawText
                            self.assistantSession = session
                        }
                        self.updateAssistantSession(
                            assistantSessionID,
                            phase: .planning,
                            label: "Planning"
                        )
                    }
                }

                let settings = store.settings

                // AI mode is one-shot: transcription + the screen screenshot go
                // to the agent (if named) or Claude, and the answer is pasted
                // straight into the focused field. No conversation is kept - to
                // iterate, the user starts AI mode again and the fresh
                // screenshot captures whatever's now on screen (including the
                // last answer).
                if instructionMode {
                    guard let assistantSessionID else { throw CancellationError() }

                    // Local plans run through the allowlisted typed registry.
                    // Reads execute immediately; external actions can only be
                    // resumed from a host-owned confirmation card.
                    if let plan = await MainActor.run(body: {
                        self.assistantPlanner.plan(rawText)
                    }) {
                        try await self.executeAssistantPlan(
                            plan,
                            sessionID: assistantSessionID,
                            transcript: rawText
                        )
                        return
                    }

                    // The screen capture is the only context for the take.
                    var contextAttachments: [AttachedContext] = []
                    if let shot = await Self.resolveScreenshotAttachment(pendingShot) {
                        contextAttachments.append(shot)
                    }

                    // Local parsing deliberately stays conservative. For
                    // screen-relative commands such as "open this person's
                    // LinkedIn", the model may resolve the visible subject and
                    // emit one typed request. Registry validation still rejects
                    // invented tools/arguments, and every external action lands
                    // on a host-owned confirmation card before execution.
                    if !settings.apiKey.isEmpty,
                       await MainActor.run(body: {
                           self.assistantPlanner.shouldAttemptModelPlanning(rawText)
                       }) {
                        do {
                            let modelTools = assistantTools.descriptors.filter {
                                $0.id != OpenLocalFileAssistantTool.id
                            }
                            if let request = try await refiner.planToolCall(
                                transcription: rawText,
                                attachments: contextAttachments,
                                descriptors: modelTools,
                                apiKey: settings.apiKey
                            ) {
                                let plan = AssistantPlan(
                                    summary: "Preparing \(request.toolID)",
                                    requests: [request]
                                )
                                try await self.executeAssistantPlan(
                                    plan,
                                    sessionID: assistantSessionID,
                                    transcript: rawText
                                )
                                return
                            }
                        } catch is AssistantRuntimeError {
                            await MainActor.run {
                                _ = self.updateAssistantSession(
                                    assistantSessionID,
                                    phase: .planning,
                                    label: "Rejected an invalid tool request"
                                )
                            }
                            // A rejected model plan is not fatal. Continue to
                            // the ordinary screen-aware answer path.
                        }
                    }

                    if !settings.apiKey.isEmpty,
                       let match = await detectAgent(in: rawText, apiKey: settings.apiKey) {
                        let shouldExecute = await MainActor.run {
                            guard self.updateAssistantSession(
                                assistantSessionID,
                                phase: .executing(toolID: "langdock.agent"),
                                label: "Asked \(match.agent.name)"
                            ) else { return false }
                            self.isAgentMode = true
                            return true
                        }
                        guard shouldExecute else { throw CancellationError() }

                        let finalText = try await agentClient.execute(
                            agentId: match.agent.agentId,
                            userMessage: match.cleanedText,
                            attachments: contextAttachments,
                            apiKey: settings.apiKey
                        )
                        try Task.checkCancellation()

                        await MainActor.run {
                            guard self.updateAssistantSession(
                                assistantSessionID,
                                phase: .presenting,
                                label: "Presented answer"
                            ) else { return }
                            self.deliverAIResult(finalText)
                        }
                    } else {
                        let shouldExecute = await MainActor.run {
                            self.updateAssistantSession(
                                assistantSessionID,
                                phase: .executing(toolID: "langdock.answer"),
                                label: "Answering with screen context"
                            )
                        }
                        guard shouldExecute else { throw CancellationError() }
                        let terms = store.dictionary.map { $0.term }
                        let snips = store.snippets.map { (name: $0.name, text: $0.text) }
                        let finalText = try await refiner.instructConversation(
                            history: [],
                            newTurnText: rawText,
                            newTurnAttachments: contextAttachments,
                            apiKey: settings.apiKey,
                            dictionaryTerms: terms,
                            snippets: snips,
                            onChunk: { _ in }
                        )
                        try Task.checkCancellation()

                        await MainActor.run {
                            guard self.updateAssistantSession(
                                assistantSessionID,
                                phase: .presenting,
                                label: "Presented answer"
                            ) else { return }
                            self.deliverAIResult(finalText)
                        }
                    }
                } else {
                    // Raw transcription (non-AI) path - Haiku cleanup if
                    // enabled, paste, dismiss as before.
                    let finalText: String
                    if settings.llmRefinementEnabled && !settings.apiKey.isEmpty {
                        do {
                            let terms = store.dictionary.map { $0.term }
                            finalText = try await refiner.refine(
                                text: rawText,
                                apiKey: settings.apiKey,
                                dictionaryTerms: terms
                            )
                        } catch {
                            finalText = rawText
                        }
                    } else {
                        finalText = rawText
                    }

                    await MainActor.run {
                        self.lastTranscriptionResult = finalText
                        self.store.addTranscript(finalText, isInstruction: false)
                        if self.insertResult(finalText) {
                            // A real target field owns the result. Stay in the
                            // compact processing surface until the paste fires,
                            // then shrink away without ever rendering the
                            // transcript rescue card for a single frame.
                            self.startDismissSequence()
                        } else {
                            // No editable field was focused when recording
                            // began - surface the take in the rescue card so
                            // the user can copy it manually.
                            self.state = .result(text: finalText)
                            self.showFallback(finalText)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.discardLiveTextInsertion()
                    self.resetInstructionMode()
                    if let assistantSessionID,
                       !(error is CancellationError) {
                        _ = self.updateAssistantSession(
                            assistantSessionID,
                            phase: .failed(error.localizedDescription),
                            label: "Failed"
                        )
                    }
                    guard !(error is CancellationError) else { return }
                    // Salvage whatever the rolling pipeline got through
                    // before the failure (e.g. the AI call died after a
                    // 20-minute dictation). The raw text also survives in
                    // ~/.whisperino/recovery/last-raw-transcript.txt.
                    if !self.liveTranscript.isEmpty {
                        self.copyToClipboard(self.liveTranscript)
                        self.state = .error(message: "Failed - raw transcript copied to clipboard")
                        self.autoDismiss(after: 4)
                    } else {
                        self.state = .error(message: error.localizedDescription)
                        self.autoDismiss(after: 3)
                    }
                }
            }
        }
    }

    /// Finish an AI-mode take: record the answer, paste it into the focused
    /// field, and take the pill down - or fall back to the rescue card when
    /// there was nowhere to paste. The one-shot counterpart to the raw
    /// dictation finish path.
    private func deliverAIResult(_ finalText: String) {
        lastTranscriptionResult = finalText
        store.addTranscript(finalText, isInstruction: true)
        if insertResult(finalText) {
            startDismissSequence()
        } else {
            state = .result(text: finalText)
            showFallback(finalText)
        }
    }

    // MARK: - Native assistant cards

    /// Selecting a file is still only intent: surface the exact target and ask
    /// before crossing the side-effect boundary.
    func requestOpen(_ result: LocalFileResult) {
        guard let sessionID = assistantSession?.id else { return }
        do {
            let request = ToolRequest(
                toolID: OpenLocalFileAssistantTool.id,
                arguments: [
                    "path": .string(result.path),
                    "name": .string(result.name),
                    "detail": .string(result.detail),
                    "symbol": .string(result.symbolName),
                ]
            )
            let invocation = try assistantTools.prepare(request, sessionID: sessionID)
            pendingAssistantInvocation = invocation
            guard updateAssistantSession(
                sessionID,
                phase: .awaitingConfirmation(invocation),
                label: "Waiting for approval to open \(result.name)"
            ) else { return }
            assistantCard = .confirmOpen(result)
        } catch {
            _ = updateAssistantSession(
                sessionID,
                phase: .failed(error.localizedDescription),
                label: "Could not prepare action"
            )
            assistantCard = .message(
                symbol: "exclamationmark.triangle.fill",
                title: "Can’t open that file",
                detail: error.localizedDescription
            )
        }
    }

    func approveAssistantAction() {
        guard assistantCard != nil,
              let invocation = pendingAssistantInvocation,
              invocation.sessionID == assistantSession?.id else { return }
        pendingAssistantInvocation = nil
        guard updateAssistantSession(
            invocation.sessionID,
            phase: .executing(toolID: invocation.toolID),
            label: "Approved action"
        ) else { return }

        assistantResponseTask?.cancel()
        assistantResponseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.assistantTools.execute(invocation, confirmed: true)
                try Task.checkCancellation()
                guard self.updateAssistantSession(
                    invocation.sessionID,
                    phase: .presenting,
                    label: "Action completed"
                ) else { return }
                self.presentAssistantToolResult(result)

                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard case .message = self?.assistantCard else { return }
                    self?.dismissAssistantCard()
                }
            } catch {
                guard !(error is CancellationError) else { return }
                _ = self.updateAssistantSession(
                    invocation.sessionID,
                    phase: .failed(error.localizedDescription),
                    label: "Action failed"
                )
                self.assistantCard = .message(
                    symbol: "exclamationmark.triangle.fill",
                    title: "Action failed",
                    detail: error.localizedDescription
                )
                self.state = .result(text: error.localizedDescription)
            }
        }
    }

    func dismissAssistantCard() {
        assistantResponseTask?.cancel()
        assistantResponseTask = nil
        pendingAssistantInvocation = nil
        assistantCard = nil
        assistantSession = nil
        if case .result = state { state = .idle }
    }

    @discardableResult
    private func updateAssistantSession(
        _ id: UUID,
        phase: AssistantSessionPhase,
        label: String
    ) -> Bool {
        guard var session = assistantSession, session.id == id else { return false }
        session.transition(to: phase, label: label)
        assistantSession = session
        return true
    }

    private func presentAssistantToolResult(_ result: AssistantToolResult) {
        switch result {
        case .localFiles(let query, let results):
            assistantCard = .fileResults(query: query, results: results)
            state = .result(text: "Found \(results.count) files")
        case .actionMessage(let symbol, let title, let detail):
            assistantCard = .message(symbol: symbol, title: title, detail: detail)
            state = .result(text: title)
        }
    }

    private func executeAssistantPlan(
        _ plan: AssistantPlan,
        sessionID: UUID,
        transcript: String
    ) async throws {
        var lastResult: AssistantToolResult?
        for request in plan.requests {
            try Task.checkCancellation()
            let invocation = try await MainActor.run {
                try self.assistantTools.prepare(request, sessionID: sessionID)
            }

            if invocation.effect == .externalAction {
                let didPresent = await MainActor.run {
                    self.pendingAssistantInvocation = invocation
                    guard self.updateAssistantSession(
                        sessionID,
                        phase: .awaitingConfirmation(invocation),
                        label: plan.summary
                    ) else { return false }
                    self.recordingTargetPID = nil
                    self.resetInstructionMode()
                    self.store.addTranscript(transcript, isInstruction: true)
                    self.presentAssistantConfirmation(invocation)
                    return true
                }
                guard didPresent else { throw CancellationError() }
                return
            }

            let isCurrent = await MainActor.run {
                self.updateAssistantSession(
                    sessionID,
                    phase: .executing(toolID: invocation.toolID),
                    label: plan.summary
                )
            }
            guard isCurrent else { throw CancellationError() }
            lastResult = try await assistantTools.execute(invocation, confirmed: false)
        }

        try Task.checkCancellation()
        guard let result = lastResult else {
            throw AssistantRuntimeError.invalidArgument(
                tool: "Assistant plan",
                argument: "requests"
            )
        }
        await MainActor.run {
            guard self.updateAssistantSession(
                sessionID,
                phase: .presenting,
                label: "Tool completed"
            ) else { return }
            self.recordingTargetPID = nil
            self.resetInstructionMode()
            self.store.addTranscript(transcript, isInstruction: true)
            self.presentAssistantToolResult(result)
        }
    }

    private func presentAssistantConfirmation(_ invocation: PreparedToolInvocation) {
        switch invocation.toolID {
        case CreateCalendarEventAssistantTool.id:
            guard let draft = CreateCalendarEventAssistantTool.draft(from: invocation.arguments) else {
                assistantCard = .message(
                    symbol: "exclamationmark.triangle.fill",
                    title: "Invalid calendar event",
                    detail: "The proposed event could not be displayed safely."
                )
                return
            }
            assistantCard = .calendarDraft(draft)
            state = .result(text: "Review calendar event")

        case WebSearchAssistantTool.id:
            guard let query = invocation.arguments["query"]?.stringValue else { return }
            assistantCard = .webSearch(WebSearchDraft(query: query))
            state = .result(text: "Review web search")

        default:
            assistantCard = .message(
                symbol: "exclamationmark.shield.fill",
                title: "Unsupported action",
                detail: invocation.toolID
            )
            state = .result(text: "Unsupported action")
        }
    }

    private func resetInstructionMode() {
        isInstructionMode = false
        isAgentMode = false
        screenshotTask?.cancel()
        screenshotTask = nil
    }

    /// Check if the transcription mentions a configured agent.
    /// Triggers when the word "agent" appears in the transcription, then uses an LLM call
    /// to fuzzy-match the intended agent name against the configured list.
    private func detectAgent(in transcription: String, apiKey: String) async -> (agent: AgentEntry, cleanedText: String)? {
        let agents = store.agents
        guard !agents.isEmpty else { return nil }

        // Only attempt detection when the user says "agent"
        guard transcription.lowercased().contains("agent") else { return nil }

        let agentNames = agents.map { $0.name }.joined(separator: ", ")
        let systemPrompt = """
            You are an agent-name matcher for a voice dictation app. The user spoke an instruction \
            that contains the word "agent". Determine if they want to INVOKE a configured agent, \
            or if they are merely TALKING ABOUT agents in general.

            Available agents: \(agentNames)

            Rules:
            - Only match if the user clearly wants to USE/INVOKE/ASK one of the available agents \
              (e.g., "use the X agent to...", "ask the X agent...", "have the X agent...")
            - Do NOT match if the user is talking ABOUT agents in general \
              (e.g., "fix the agent code", "the agent framework needs...", "improve agent detection")
            - Match even if the transcription misspells or slightly alters the agent name
            - Reply with EXACTLY two lines and nothing else:
              Line 1: The exact agent name from the list above (or NONE if no match)
              Line 2: The user's instruction with the agent reference removed (the clean task)
            - If no agent is being invoked, reply with just: NONE
            """

        do {
            var request = URLRequest(url: URL(string: "https://api.langdock.com/anthropic/eu/v1/messages")!,
                                     timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "model": "claude-haiku-4-5-20251001",
                "max_tokens": 256,
                "temperature": 0,
                "system": systemPrompt,
                "messages": [["role": "user", "content": transcription]]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let first = content.first,
                  let text = first["text"] as? String else {
                return nil
            }

            let lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard let matchedName = lines.first, matchedName != "NONE" else {
                return nil
            }

            // Find the agent whose name matches the LLM response (case-insensitive)
            guard let agent = agents.first(where: { $0.name.lowercased() == matchedName.lowercased() }) else {
                return nil
            }

            let cleaned = lines.count > 1 ? lines[1] : transcription
            return (agent, cleaned.isEmpty ? transcription : cleaned)
        } catch {
            return nil
        }
    }

    // MARK: - Paste

    /// Remove provisional live text and restore whatever was selected before
    /// dictation. Safe to call repeatedly across every teardown path.
    private func discardLiveTextInsertion(protectFinalDelivery: Bool = false) {
        pendingLiveTextInsertion?.cancel()
        pendingLiveTextInsertion = nil
        lastLiveTextInsertionTime = 0
        let inserter = liveTextInserter
        inserter?.rollback()
        liveTextInserter = nil
        consecutiveLiveTextInsertionFailures = 0
        liveTextInsertionRequiresRescue = protectFinalDelivery
            && (inserter?.hasInsertedText ?? false)
        streamsTranscriptIntoFocusedField = false
    }

    /// Paste the finished take into the app that was frontmost when recording
    /// began. Returns false only when we positively determined at record start
    /// that there was no editable field. Accessibility elements in Electron
    /// and terminal surfaces can be recreated while the visible caret remains
    /// in place, so they are not a dependable final-delivery identity check.
    @discardableResult
    private func insertResult(_ text: String) -> Bool {
        pendingLiveTextInsertion?.cancel()
        pendingLiveTextInsertion = nil
        lastLiveTextInsertionTime = 0
        let targetPID = recordingTargetPID
        let editable = recordingTargetEditable
        let liveInserter = liveTextInserter
        let requiresRescue = liveTextInsertionRequiresRescue
        liveTextInserter = nil
        consecutiveLiveTextInsertionFailures = 0
        liveTextInsertionRequiresRescue = false
        recordingTargetPID = nil
        resetInstructionMode()

        guard editable else {
            streamsTranscriptIntoFocusedField = false
            return false
        }
        guard !requiresRescue else {
            streamsTranscriptIntoFocusedField = false
            return false
        }
        // TCC grants are tied to the exact signed app bundle. A rebuild or a
        // signing-identity transition can leave the row in System Settings
        // looking enabled while this running process is not actually trusted.
        // Preserve the text in the rescue card instead of silently firing an
        // event macOS will discard.
        guard AXIsProcessTrusted() else {
            NSLog("[whisperino] paste withheld: Accessibility is not trusted for \(Bundle.main.bundleURL.path)")
            streamsTranscriptIntoFocusedField = false
            return false
        }

        // A streaming take already owns a provisional range in this editor.
        // Replace that range with the finalized (and possibly LLM-refined)
        // result instead of pasting a duplicate after it.
        if let liveInserter {
            let hadPartialText = liveInserter.hasInsertedText
            if liveInserter.replace(with: text) {
                if shouldAutoSubmit(pid: targetPID) {
                    deliverAutoSubmit(reactivating: targetPID)
                }
                return true
            }

            liveInserter.rollback()
            // If provisional text had already landed, a blind full paste could
            // duplicate or overwrite a user edit. Preserve the final text in
            // the rescue card instead. Before the first partial, the ordinary
            // clipboard path remains safe as a compatibility fallback.
            if hadPartialText {
                streamsTranscriptIntoFocusedField = false
                return false
            }
        }

        streamsTranscriptIntoFocusedField = false
        deliverPaste(
            text,
            reactivating: targetPID,
            submitAfter: shouldAutoSubmit(pid: targetPID)
        )
        return true
    }

    /// Whether the app that was frontmost at record start is on the
    /// auto-submit list, so we press Return once the paste lands (submitting
    /// the chat message, or queuing it in a busy coding agent).
    private func shouldAutoSubmit(pid: pid_t?) -> Bool {
        guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return store.autoSubmitEnabled(forBundleId: app.bundleIdentifier)
    }

    /// Whether the system-wide focused UI element is an editable text
    /// surface. Read at record start, when the target app is frontmost and
    /// its caret is live - the only point this is dependable.
    ///
    /// Biases toward yes: a failed Accessibility query remains eligible for
    /// the compatibility paste path. Only a positively non-editable focused
    /// control produces the rescue card.
    private static func focusedEditableTarget() -> (
        editable: Bool,
        element: AXUIElement?,
        supportsLiveInsertion: Bool
    ) {
        guard AXIsProcessTrusted() else { return (true, nil, false) }

        // System-wide focused element = the focused element of the frontmost
        // app. This is the robust query (the per-app variant returns stale /
        // no value when the app isn't key). At record start the target *is*
        // frontmost, so this is exactly the field the user is dictating into.
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        // Couldn't read focus at all (AX disabled for the app, opaque
        // Electron, transient error) → assume editable and paste.
        guard err == .success else { return (true, nil, false) }
        // Attribute present but empty → genuinely nothing focused.
        guard let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return (false, nil, false)
        }
        let element = focused as! AXUIElement

        func stringAttr(_ attr: String) -> String? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
            return ref as? String
        }

        let role = stringAttr(kAXRoleAttribute as String)
        let subrole = stringAttr(kAXSubroleAttribute as String)
        var settable = DarwinBoolean(false)
        let valueSettable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue

        let editable = classifyEditable(
            role: role,
            subrole: subrole,
            valueSettable: valueSettable,
            element: element
        )
        // Password fields remain valid final-paste targets, but never expose a
        // live provisional transcript through Accessibility.
        // Even if role classification says this is a container, pass the
        // focused element to LiveTextInserter. Web chat composers often put
        // the writable text range on an ancestor or descendant; the inserter
        // performs its own bounded, non-destructive capability probe.
        let supportsLiveInsertion = subrole != "AXSecureTextField"
        return (editable, element, supportsLiveInsertion)
    }

    /// Decide editability from role first. Real text-input roles/subroles
    /// are editable; container surfaces (a web document, scroll area, group,
    /// window…) are NOT - they expose a text-selection range for page-text
    /// selection, but you can't type into them, so treating that range as
    /// "editable" was what suppressed the rescue card when no input was
    /// focused. Unknown roles fall back to capability checks.
    private static func classifyEditable(role: String?, subrole: String?, valueSettable: Bool, element: AXUIElement) -> Bool {
        if let subrole, ["AXSecureTextField", "AXSearchField", "AXTextField", "AXTextArea"].contains(subrole) {
            return true
        }
        if let role {
            let inputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
            if inputRoles.contains(role) { return true }

            // Container / non-input focus targets. A web area is the whole
            // document, never a typeable field, so reject it even if its
            // value happens to be settable.
            let containerRoles: Set<String> = [
                "AXWebArea", "AXScrollArea", "AXGroup", "AXSplitGroup", "AXWindow",
                "AXStaticText", "AXImage", "AXButton", "AXList", "AXTable", "AXOutline",
                "AXLink", "AXHeading", "AXMenuBar", "AXMenu", "AXMenuItem", "AXMenuButton",
                "AXCell", "AXRow", "AXColumn", "AXToolbar", "AXTabGroup", "AXRadioButton",
                "AXCheckBox", "AXPopUpButton", "AXSlider", "AXDisclosureTriangle", "AXUnknown",
            ]
            if containerRoles.contains(role) { return false }
        }

        // Unknown / unlisted role: trust a writable value (native editors
        // that don't advertise a standard role).
        return valueSettable
    }

    /// The compatibility paste path: stash the clipboard, bring the app that
    /// owned the take forward, synthesize Cmd+V, then restore the clipboard.
    private func deliverPaste(
        _ text: String,
        reactivating pid: pid_t?,
        submitAfter: Bool = false
    ) {
        // Snapshot the clipboard so we can put it back afterwards.
        let savedItems = NSPasteboard.general.pasteboardItems?.compactMap { item -> [String: Data]? in
            var dict = [String: Data]()
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type.rawValue] = data
                }
            }
            return dict.isEmpty ? nil : dict
        } ?? []

        // Bring the target app forward. It's usually still frontmost (our
        // overlay is non-activating), but reassert it and wait for macOS to
        // make it key before the synthetic paste is posted.
        let reactivatedPID: pid_t?
        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
            reactivatedPID = pid
        } else {
            reactivatedPID = nil
        }

        let fire: () -> Void = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let injectedChangeCount = NSPasteboard.general.changeCount
            self.pasteClipboard()

            if submitAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    self.pressReturn()
                }
            }

            // Electron/web editors can consume the synthetic paste later than
            // native fields. Leave the value available for a full beat.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                guard NSPasteboard.general.changeCount == injectedChangeCount else { return }
                NSPasteboard.general.clearContents()
                for itemDict in savedItems {
                    let item = NSPasteboardItem()
                    for (type, data) in itemDict {
                        item.setData(data, forType: NSPasteboard.PasteboardType(type))
                    }
                    NSPasteboard.general.writeObjects([item])
                }
            }
        }

        if let reactivatedPID {
            waitUntilFrontmost(pid: reactivatedPID, attemptsRemaining: 8, completion: fire)
        } else {
            fire()
        }
    }

    /// Auto-submit after a successful live insertion. Mirror final-paste app
    /// activation without touching the pasteboard again.
    private func deliverAutoSubmit(reactivating pid: pid_t?) {
        let fire: () -> Void = {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self.pressReturn()
            }
        }

        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
            waitUntilFrontmost(pid: pid, attemptsRemaining: 8, completion: fire)
        } else {
            fire()
        }
    }

    /// App activation is asynchronous. Wait up to 400ms for the intended
    /// target before sending paste or Return.
    private func waitUntilFrontmost(
        pid: pid_t,
        attemptsRemaining: Int,
        completion: @escaping () -> Void
    ) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            || attemptsRemaining <= 0 {
            completion()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitUntilFrontmost(
                pid: pid,
                attemptsRemaining: attemptsRemaining - 1,
                completion: completion
            )
        }
    }

    /// Show the rescue card and arm the auto-dismiss timer so it never
    /// lingers forever.
    private func showFallback(_ text: String) {
        fallbackResult = text
        fallbackTimer?.invalidate()
        fallbackTimer = Timer.scheduledTimer(
            withTimeInterval: Self.fallbackTimeout, repeats: false
        ) { [weak self] _ in
            self?.dismissFallback()
        }
    }

    /// Close the fallback result card and take the panel down.
    func dismissFallback() {
        guard fallbackResult != nil else { return }
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        fallbackResult = nil
        if case .result = state { state = .idle }
    }

    private func startDismissSequence() {
        // Tiny hold so the paste visibly lands, then the pill exits directly
        // from processing. Successful insertion must never pass through
        // `.result`: that state owns the visible rescue transcript card and
        // caused a one-frame popup even when a target field received the text.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            switch self.state {
            case .refining, .result:
                self.state = .dismissing
            default:
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard case .dismissing = self?.state else { return }
                self?.state = .idle
                self?.streamsTranscriptIntoFocusedField = false
            }
        }
    }

    // MARK: - Accessibility

    static func ensureAccessibility() {
        DispatchQueue.main.async {
            AccessibilityPermissionController.shared.requestIfNeeded()
        }
    }

    private func pasteClipboard() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let commandDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: UInt16(kVK_Command),
            keyDown: true
        )
        commandDown?.flags = .maskCommand
        let vDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: UInt16(kVK_ANSI_V),
            keyDown: true
        )
        vDown?.flags = .maskCommand
        let vUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: UInt16(kVK_ANSI_V),
            keyDown: false
        )
        vUp?.flags = .maskCommand
        let commandUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: UInt16(kVK_Command),
            keyDown: false
        )
        commandUp?.flags = []

        commandDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        commandUp?.post(tap: .cghidEventTap)
    }

    /// Synthesize a Return keystroke - used to auto-submit (or, for a busy
    /// coding agent, queue) a pasted dictation in apps the user set up.
    ///
    /// Flags are forced empty so Return remains unmodified even if the user is
    /// physically holding another modifier. `pasteClipboard()` also posts a
    /// complete Command-down / Command-up sequence so the synthetic paste
    /// cannot leave the combined keyboard state stuck on Command.
    private func pressReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Return), keyDown: true)
        keyDown?.flags = []
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Return), keyDown: false)
        keyUp?.flags = []
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Copy `text` to the system clipboard, no paste. Used to salvage a
    /// transcript when the AI call fails.
    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func autoDismiss(after seconds: Double) {
        let currentState = state
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.state == currentState {
                self?.state = .idle
            }
        }
    }
}
