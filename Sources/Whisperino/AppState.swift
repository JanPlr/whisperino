import AppKit
import Carbon
import Combine
import CoreGraphics
import SwiftUI
enum TranscriptionState: Equatable {
    case idle
    case recording
    case paused
    case transcribing
    case refining
    case result(text: String)
    case dismissing
    case cancelled
    case error(message: String)
}

/// What the clipboard attachment contains
enum ClipboardContent {
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

/// A single attached context item (clipboard text or image)
struct AttachedContext: Identifiable {
    let id = UUID()
    let content: ClipboardContent
    let preview: String
    /// A small pre-rendered preview for the attachment chip. Rendering a
    /// full-resolution screenshot at 24pt and re-scaling it on every
    /// relayout/animation frame is what made attaching feel laggy; we
    /// downsize once at attach time and show this instead. `nil` for text.
    var thumbnail: NSImage? = nil
}

/// One entry in an AI-mode conversation. Ephemeral - never persisted -
/// so we can keep `NSImage` references in attachments without worrying
/// about Codable.
struct ChatTurn: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    /// True while tokens are still streaming in. Lets the UI render a
    /// blinking caret and disables interactions on the in-flight bubble.
    var isStreaming: Bool = false
    /// User-side only. Captured at submit time so the bubble can show
    /// what was attached for that turn.
    var attachments: [AttachedContext] = []
    /// Assistant-side, agent runs only. Each entry is one step the
    /// agent went through (web search, data analysis, …). Rendered as
    /// a tiny timeline above the final text in the bubble.
    var agentSteps: [AgentStepEvent] = []
}

/// One row in the agent step timeline. `completed` flips to true when
/// the agent moves on to the next step. Carries both the SF Symbol the
/// UI should render and a human title (no trailing dots, title-case).
struct AgentStepEvent: Identifiable, Equatable {
    let id = UUID()
    let icon: String
    let title: String
    var completed: Bool = false
}

class AppState: ObservableObject {
    @Published var state: TranscriptionState = .idle
    @Published var audioLevel: Float = 0
    /// Rolling buffer of recent audio levels for the waveform display.
    /// Index 0 = newest (leftmost bar), last index = oldest. Updated at a
    /// fixed rate so the visual rolls smoothly even when the recorder
    /// callback bursts.
    @Published var audioSamples: [Float] = Array(repeating: 0, count: AppState.waveformBarCount)
    @Published var recordingStartTime: Date?
    /// Accumulated clipboard attachments for instruction mode
    @Published var attachedContexts: [AttachedContext] = []
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
    /// Seconds the fallback card lingers before auto-dismissing. The
    /// overlay's countdown ring animates over this same duration.
    static let fallbackTimeout: TimeInterval = 8
    private var fallbackTimer: Timer?
    /// Dynamic status text during agent execution (e.g. "Searching the web…")
    @Published var agentStatus: String? = nil
    /// Name of the currently active agent (shown in overlay)
    @Published var activeAgentName: String? = nil
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
    /// Chunk progress for the transcribing pill ("3/5"). Total counts
    /// every chunk submitted so far; done counts completed whisper runs.
    @Published var chunksDone: Int = 0
    @Published var chunksTotal: Int = 0

    /// Maximum number of attachments allowed
    static let maxAttachments = 5

    /// Number of bars shown in the waveform display.
    static let waveformBarCount = 13

    // MARK: - Chat (AI mode multi-turn)

    /// All turns in the current AI-mode conversation. Empty = no chat
    /// active. Adding to this opens the chat overlay; clearing closes it.
    @Published var chatHistory: [ChatTurn] = []

    /// True when an assistant turn is being streamed. Used for the
    /// "generating" indicator under the chat bubbles.
    @Published var isStreamingResponse: Bool = false

    /// Convenience: chat is active iff any turns exist.
    var isChatActive: Bool { !chatHistory.isEmpty }

    /// 20s after the last activity, the chat auto-dismisses.
    private var chatIdleTimer: Timer?
    private static let chatIdleTimeout: TimeInterval = 20

    // MARK: Hands-free conversation
    //
    // After the model finishes a reply we re-open the mic automatically so
    // the user can just keep talking - no key press between turns. A short
    // pause after they speak auto-submits the turn; if they never speak we
    // give up and fall back to the normal idle countdown.
    /// True while an auto-started follow-up listen is in flight. Only these
    /// takes auto-submit on silence - manual takes never do.
    @Published private(set) var isAutoListening = false
    private var autoListenMonitor: Timer?
    private var autoListenSawSpeech = false
    private var autoListenLastVoice: Date?
    private var autoListenStarted: Date?
    /// Audio level above which we count the user as actively speaking.
    private static let autoListenSpeechLevel: Float = 0.06
    /// Silence after speech that ends (auto-submits) the turn.
    private static let autoListenSilenceSeconds: TimeInterval = 1.6
    /// If no speech arrives this soon after the mic re-opens, stop listening
    /// and hand back to the idle countdown rather than record the room.
    private static let autoListenGiveUpSeconds: TimeInterval = 6

    private(set) var lastTranscriptionResult: String?
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let refiner = LLMRefiner()
    private let agentClient = AgentClient()
    private let store = SettingsStore.shared

    /// PID of the app that was frontmost when recording started
    private var recordingTargetPID: pid_t?

    /// Whether, at the moment recording started, the target app had a
    /// focused editable text element. Captured then - not at paste time -
    /// because that's when the target is reliably frontmost and its field
    /// genuinely focused (our overlay is non-activating and the detached
    /// chat tile hasn't stolen focus yet). Defaults to true so we paste
    /// whenever the answer is unknown rather than withholding.
    private var recordingTargetEditable = true

    // MARK: Rolling chunked transcription

    /// Pipeline transcribing finished chunks in the background while the
    /// user is still speaking. One per take; nil when not recording.
    private var transcriptionSession: TranscriptionSession?
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

    /// Live streaming (raw dictation only): paste each chunk's text into
    /// the focused field as it finishes transcribing. Latched at record
    /// start so flipping the setting mid-take can't produce half-modes.
    private var liveInsertActive = false
    /// How many segments have already been pasted, to space-join them.
    private var liveInsertedSegments = 0

    /// Drives the waveform's rolling history. The leftmost bar tracks
    /// audio level in real-time via the recorder callback; this timer just
    /// shifts the value into history at a fixed cadence so the wave
    /// visibly travels left-to-right.
    private var sampleTimer: Timer?

    /// Polls the system pasteboard during instruction mode so that anything
    /// the user copies (Cmd+C) gets auto-attached as context. Saves manual
    /// clicks on the paperclip.
    private var clipboardWatchTimer: Timer?
    private var clipboardBaselineChangeCount: Int = 0
    /// While we're driving the pasteboard ourselves (auto-paste of an
    /// AI reply, restore of the user's prior clipboard), the watcher
    /// must ignore the resulting changes - otherwise our own paste
    /// gets captured as a context chip on the next turn.
    private var clipboardWatchSuppressed: Bool = false

    var isSetUp: Bool { transcriber.isAvailable }

    /// Pre-load the whisper model into the persistent server so the
    /// first dictation doesn't pay the model-load cost. Call at launch.
    func warmUpTranscriber() {
        transcriber.warmUp()
    }

    /// Tear down the persistent whisper server. Call at app termination.
    func shutdownTranscriber() {
        transcriber.shutdown()
    }

    // MARK: - Input Device Management

    /// Refresh the list of available input devices and mark the current default
    func refreshInputDevices() {
        inputDevices = AudioRecorder.availableInputDevices()
        // If no explicit selection, highlight the system default
        if selectedInputDevice == nil, let defaultID = AudioRecorder.defaultInputDeviceID() {
            selectedInputDevice = inputDevices.first { $0.id == defaultID }
        }
        // If selected device disappeared, reset to default
        if let selected = selectedInputDevice, !inputDevices.contains(where: { $0.id == selected.id }) {
            if let defaultID = AudioRecorder.defaultInputDeviceID() {
                selectedInputDevice = inputDevices.first { $0.id == defaultID }
            } else {
                selectedInputDevice = inputDevices.first
            }
        }
    }

    /// Select a specific input device for recording.
    /// If currently recording, restarts the engine on the new device seamlessly.
    func selectInputDevice(_ device: AudioInputDevice) {
        selectedInputDevice = device

        // If recording is active, hot-swap the input device by restarting the engine
        guard case .recording = state else { return }
        do {
            try recorder.switchDevice(deviceID: device.id) { [weak self] level in
                DispatchQueue.main.async {
                    self?.audioLevel = level
                }
            }
        } catch {
            print("[whisperino] failed to switch device mid-recording: \(error)")
        }
    }

    // MARK: - Hotkey handlers

    func hotkeyToggle() {
        // While a chat is active, a bare trigger press continues the
        // existing AI conversation rather than starting a fresh raw
        // dictation. Saves the user from holding Shift on every turn.
        if isChatActive {
            toggleRecording(instruction: true)
        } else {
            toggleRecording(instruction: false)
        }
    }

    func instructionHotkeyToggle() {
        toggleRecording(instruction: true)
    }

    /// Upgrade an in-progress dictation session to instruction (AI) mode.
    /// Called when the user adds Shift while already holding Fn and
    /// recording. Validates the LLM is configured, flips the mode flag (so
    /// the gradient border animates in via SwiftUI), and starts the
    /// clipboard auto-capture so subsequent Cmd+C presses attach context.
    func upgradeToInstructionMode() {
        guard case .recording = state else { return }
        guard !isInstructionMode else { return }

        let settings = store.settings
        // Require API key + AI mode enabled, just like a fresh AI-mode start
        guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              settings.aiModeEnabled else { return }

        isInstructionMode = true
        startClipboardWatching()
    }

    private func toggleRecording(instruction: Bool) {
        switch state {
        case .idle, .result, .error, .dismissing, .cancelled:
            startRecording(instruction: instruction)
        case .recording:
            // No min-duration gate here - push-to-talk users may briefly
            // tap Fn. stopRecording() discards anything <0.5s itself.
            stopRecording()
        case .paused:
            stopRecording()
        case .transcribing, .refining:
            break
        }
    }

    // MARK: - Toggle Recording (waveform tap)

    func toggleRecording() {
        toggleRecording(instruction: isInstructionMode)
    }

    // MARK: - Pause / Resume

    func pauseRecording() {
        guard case .recording = state else { return }
        recorder.pause()
        audioLevel = 0.3
        state = .paused
    }

    func resumeRecording() {
        guard case .paused = state else { return }
        recorder.resume()
        state = .recording
    }

    // MARK: - Cancel

    func cancelRecording() {
        stopAutoListenMonitor()
        // Esc while the fallback result card is up = close the card.
        // Nothing else can be in flight in that state.
        if fallbackResult != nil {
            dismissFallback()
            return
        }
        // Esc with chat open and no recording = close the conversation.
        // Have to branch here so cancelRecording stays the single Esc
        // sink - the alternative is forking the hotkey wiring per-state.
        let isRecordingNow: Bool
        switch state {
        case .recording, .paused: isRecordingNow = true
        default: isRecordingNow = false
        }
        if !isRecordingNow && isChatActive {
            closeChat()
            return
        }

        showingInputPicker = false
        isLatchedRecording = false
        stopClipboardWatching()
        abandonTranscriptionSession()
        if let url = recorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        stopWaveformSampling()
        audioLevel = 0
        recordingStartTime = nil
        recordingTargetPID = nil
        resetInstructionMode()

        // Don't show the cancel-flash animation when a chat is up - it
        // collides visually with the bubbles. Just go back to chat-idle.
        if isChatActive {
            state = .idle
            bumpChatIdleTimer()
        } else {
            state = .cancelled
        }
    }

    /// Enter / "finish" gesture (the ✓ button / Enter). While recording,
    /// submits the current take. While chat-idle, "accept": paste the
    /// latest answer into the target app, then close the conversation -
    /// the affirmative counterpart to ✕ (discard everything).
    func submitOrFinish() {
        switch state {
        case .recording, .paused:
            stopRecording()
        default:
            if isChatActive {
                if let latest = chatHistory.last(where: { $0.role == .assistant }),
                   !latest.text.isEmpty {
                    pasteIntoTargetApp(latest.text)
                }
                closeChat()
            } else if fallbackResult != nil {
                dismissFallback()
            }
        }
    }

    // MARK: - Hands-free follow-up listening

    /// Called when a chat reply finishes. Re-opens the mic so the user can
    /// answer without pressing anything; a pause after they speak submits
    /// the turn. Falls back to the idle countdown if we can't (or the user
    /// stays silent), so a one-off chat still closes itself.
    private func beginFollowUpListening() {
        guard isChatActive, case .idle = state else { bumpChatIdleTimer(); return }
        startRecording(instruction: true)
        // start may have bailed (mic error, missing key) - if it didn't put
        // us into recording, don't pretend we're listening.
        guard case .recording = state else { bumpChatIdleTimer(); return }

        isAutoListening = true
        autoListenSawSpeech = false
        autoListenLastVoice = nil
        autoListenStarted = Date()
        autoListenMonitor?.invalidate()
        autoListenMonitor = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.autoListenTick()
        }
    }

    private func autoListenTick() {
        guard isAutoListening, case .recording = state else {
            stopAutoListenMonitor()
            return
        }
        let now = Date()
        if audioLevel >= Self.autoListenSpeechLevel {
            autoListenSawSpeech = true
            autoListenLastVoice = now
        }
        if autoListenSawSpeech {
            // Spoke, then paused → submit the turn (loops back to a fresh
            // listen once the reply lands).
            if let last = autoListenLastVoice,
               now.timeIntervalSince(last) >= Self.autoListenSilenceSeconds {
                stopAutoListenMonitor()
                stopRecording()
            }
        } else if let started = autoListenStarted,
                  now.timeIntervalSince(started) >= Self.autoListenGiveUpSeconds {
            // Never spoke → stop listening without submitting an empty take.
            // cancelRecording leaves us in chat-idle with the idle countdown.
            stopAutoListenMonitor()
            cancelRecording()
        }
    }

    private func stopAutoListenMonitor() {
        autoListenMonitor?.invalidate()
        autoListenMonitor = nil
        isAutoListening = false
    }

    // MARK: - Waveform sampling

    private func startWaveformSampling() {
        audioSamples = Array(repeating: 0, count: Self.waveformBarCount)
        sampleTimer?.invalidate()
        // 22 Hz - every ~45ms the wave rolls one step. With a per-step decay
        // factor, the historical "trail" fades AND moves left, so when voice
        // stops the pill clears within ~250ms instead of holding stale
        // snapshots until they roll off.
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 22.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            var s = self.audioSamples
            // Gentle per-tick fade - the wave keeps enough amplitude to
            // visibly travel across the pill before it disappears off the
            // right edge (after ~9 ticks ≈ 410ms total visible duration).
            for i in 0..<s.count { s[i] *= 0.92 }
            // Roll right + insert the current live level at the front
            // (overwritten by the next audio callback, so the leftmost
            // bar stays real-time). Newest-first → the wave travels
            // left to right.
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

    // MARK: - Clipboard Attachments (instruction mode only)

    /// Add current clipboard content as a new attachment. No-op if at max.
    func addClipboardAttachment() {
        guard attachedContexts.count < Self.maxAttachments else { return }

        let pb = NSPasteboard.general
        if let image = NSImage(pasteboard: pb) {
            let w = Int(image.size.width)
            let h = Int(image.size.height)
            let ctx = AttachedContext(
                content: .image(image),
                preview: "Image (\(w)×\(h))",
                thumbnail: image.downscaled(maxDimension: 48)
            )
            attachedContexts.append(ctx)
        } else if let text = pb.string(forType: .string), !text.isEmpty {
            let preview = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))
            let ctx = AttachedContext(content: .text(text), preview: preview)
            attachedContexts.append(ctx)
        }
    }

    /// Remove a specific attachment by ID.
    func removeAttachment(id: UUID) {
        attachedContexts.removeAll { $0.id == id }
    }

    /// Clear all attachments (used internally on reset and by the overlay toggle).
    func clearAllAttachments() {
        attachedContexts.removeAll()
    }

    // MARK: - Pasteboard auto-capture (instruction mode only)

    /// Begin watching the system pasteboard. Anything copied while this is
    /// running gets auto-attached as context - no manual paperclip click.
    /// Started when instruction mode begins, stopped when recording ends.
    private func startClipboardWatching() {
        // Snapshot the current change count so we only react to *new* copies.
        clipboardBaselineChangeCount = NSPasteboard.general.changeCount
        clipboardWatchTimer?.invalidate()
        clipboardWatchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, !self.clipboardWatchSuppressed else { return }
            let current = NSPasteboard.general.changeCount
            guard current > self.clipboardBaselineChangeCount else { return }
            self.clipboardBaselineChangeCount = current
            self.addClipboardAttachment()
        }
    }

    private func stopClipboardWatching() {
        clipboardWatchTimer?.invalidate()
        clipboardWatchTimer = nil
    }

    // MARK: - Chat lifecycle

    /// Tear down the chat conversation and dismiss the overlay. Used by
    /// Esc, the X button, Enter while chat-idle, and the idle timeout.
    func closeChat() {
        stopAutoListenMonitor()
        chatIdleTimer?.invalidate()
        chatIdleTimer = nil

        // If a recording is in flight, stop the recorder silently - we're
        // tearing the whole UI down, no need for the cancel-flash animation.
        switch state {
        case .recording, .paused:
            showingInputPicker = false
            abandonTranscriptionSession()
            if let url = recorder.stop() {
                try? FileManager.default.removeItem(at: url)
            }
            stopWaveformSampling()
            audioLevel = 0
            recordingStartTime = nil
            recordingTargetPID = nil
        default:
            break
        }

        chatHistory.removeAll()
        isStreamingResponse = false
        // Chat is the lifecycle owner of clipboard watching during AI
        // sessions - when chat ends, watching ends. Random Cmd+Cs after
        // the user closes shouldn't accumulate as attachments.
        stopClipboardWatching()
        resetInstructionMode()
        state = .idle
    }

    /// Restart the 20s idle countdown. Called whenever the user
    /// interacts with the chat (new turn, hover ends, etc.).
    func bumpChatIdleTimer() {
        chatIdleTimer?.invalidate()
        guard isChatActive else { return }
        chatIdleTimer = Timer.scheduledTimer(withTimeInterval: Self.chatIdleTimeout, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.closeChat() }
        }
    }

    /// Pause the idle countdown without rescheduling. Used while the
    /// user is hovering the panel (reading / scrolling) - they're
    /// engaged, so we shouldn't tick toward auto-close.
    func pauseChatIdleTimer() {
        chatIdleTimer?.invalidate()
        chatIdleTimer = nil
    }

    /// Append (or de-dup) an agent step on the most recent assistant
    /// turn. Each phase change from `AgentClient.onStatusUpdate` flows
    /// through here so the bubble can render a tool-call timeline.
    fileprivate func appendAgentStep(phase: AgentPhase) {
        guard let lastIdx = chatHistory.indices.last,
              chatHistory[lastIdx].role == .assistant else { return }

        // "Thinking" is too generic to deserve a row - every phase
        // change between tool calls would emit one and the timeline
        // would be all thinking.
        if case .thinking = phase { return }

        // "Generating response" is the moment the assistant starts
        // producing the answer - the answer text appearing IS the
        // signal, so a separate row would just clutter the timeline.
        // We still need to mark the previous tool call as completed so
        // it stops pulsing, even though we don't add a row.
        if case .generating = phase {
            if !chatHistory[lastIdx].agentSteps.isEmpty {
                let prev = chatHistory[lastIdx].agentSteps.count - 1
                chatHistory[lastIdx].agentSteps[prev].completed = true
            }
            return
        }

        let title = phase.stepTitle
        if let last = chatHistory[lastIdx].agentSteps.last, last.title == title {
            // Same phase fired twice - ignore the duplicate.
            return
        }

        // Mark the previous step done before adding the next so the UI
        // can render a clean "→ done → in-progress" sequence.
        if !chatHistory[lastIdx].agentSteps.isEmpty {
            let prev = chatHistory[lastIdx].agentSteps.count - 1
            chatHistory[lastIdx].agentSteps[prev].completed = true
        }

        chatHistory[lastIdx].agentSteps.append(
            AgentStepEvent(icon: phase.stepIcon, title: title)
        )
    }

    // MARK: - Recording

    private func startRecording(instruction: Bool) {
        // Clear any prior hands-free monitor; beginFollowUpListening
        // re-arms it after this call when it's an auto-started take.
        stopAutoListenMonitor()
        // A fresh take supersedes a lingering fallback card.
        fallbackResult = nil
        guard isSetUp else {
            state = .error(message: "Run setup.sh first")
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
                state = .error(message: "Enable AI mode in Settings first")
                autoDismiss(after: 3)
                return
            }
            // Fresh AI session resets stale attachments. A chat already
            // in flight keeps whatever the user pre-attached via Cmd+C
            // between turns - those count as context for *this* turn.
            if !isChatActive {
                clearAllAttachments()
            }
        }

        // Recording counts as activity - pause the chat idle countdown so
        // a slow speaker doesn't get the conversation closed under them.
        if isChatActive {
            chatIdleTimer?.invalidate()
            chatIdleTimer = nil
        }

        // Capture the frontmost app so we can re-activate it before pasting,
        // and whether it has a focused editable field *right now* - while the
        // target is frontmost and its caret is live, which is the only moment
        // this can be read reliably.
        recordingTargetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        recordingTargetEditable = Self.focusedElementIsEditable()

        do {
            try recorder.start(deviceID: selectedInputDevice?.id) { [weak self] level in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.audioLevel = level
                    // Real-time tracking: leftmost bar reflects live voice
                    // immediately, no timer-tick wait. The timer below only
                    // handles rolling history from left to right.
                    if !self.audioSamples.isEmpty {
                        self.audioSamples[0] = level
                    }
                }
            }
            startWaveformSampling()
            startTranscriptionSession(instruction: instruction)
            // Auto-attach anything the user copies while in instruction mode
            if instruction { startClipboardWatching() }
            SoundEffects.playStart()
            recordingStartTime = Date()
            state = .recording
        } catch {
            state = .error(message: "Mic error: \(error.localizedDescription)")
            autoDismiss(after: 4)
        }
    }

    // MARK: - Rolling chunked transcription

    /// Create the per-take pipeline and start the rotation timer. Long
    /// recordings get transcribed in ~40–90s chunks *while the user is
    /// still talking*, so stopping a 30-minute take only waits on the
    /// final chunk instead of one giant multi-minute whisper run.
    private func startTranscriptionSession(instruction: Bool) {
        liveTranscript = ""
        chunksDone = 0
        chunksTotal = 0
        liveInsertedSegments = 0
        liveInsertActive = !instruction && store.settings.liveStreamingEnabled

        let session = TranscriptionSession(transcriber: transcriber)
        session.onProgress = { [weak self] progress in
            guard let self = self else { return }
            self.liveTranscript = progress.text
            self.chunksDone = progress.chunksDone
            self.chunksTotal = max(self.chunksTotal, progress.chunksTotal)
            // Live streaming: commit this chunk's text to the focused
            // field right away. Fires both while recording and while the
            // tail chunks finish after stop - the final path then skips
            // its own paste because everything already landed.
            if self.liveInsertActive, !progress.newSegment.isEmpty {
                let prefix = self.liveInsertedSegments == 0 ? "" : " "
                self.liveInsertedSegments += 1
                self.pasteIntoTargetApp(prefix + progress.newSegment)
            }
        }
        transcriptionSession = session

        currentChunkStart = Date()
        chunkTimer?.invalidate()
        chunkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.chunkTimerTick()
        }
    }

    private func chunkTimerTick() {
        guard case .recording = state,
              let chunkStart = currentChunkStart,
              let session = transcriptionSession else { return }

        let elapsed = Date().timeIntervalSince(chunkStart)
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
        liveTranscript = ""
        liveInsertActive = false
        chunksDone = 0
        chunksTotal = 0
    }

    private func stopRecording() {
        // The take is ending - whether by auto-submit, Fn, or ✓ - so the
        // hands-free monitor's job is done either way.
        stopAutoListenMonitor()
        showingInputPicker = false
        // The latch ends with the take (Enter-submit bypasses the
        // HotkeyManager release path, so clear it here too).
        isLatchedRecording = false
        // Instruction mode means a chat will (or already does) carry
        // forward - keep clipboard watching alive so the user can
        // pre-attach context for the next turn between recordings.
        // Plain dictation has no notion of follow-up, so it stops.
        if !isInstructionMode {
            stopClipboardWatching()
        }
        // Recording is over - no more rotations. The session itself stays
        // alive: it still has to chew through any queued chunks plus the
        // final one we're about to hand it.
        chunkTimer?.invalidate()
        chunkTimer = nil
        currentChunkStart = nil

        guard let audioURL = recorder.stop() else {
            abandonTranscriptionSession()
            stopWaveformSampling()
            resetInstructionMode()
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
            state = .idle
            return
        }

        state = .transcribing

        let instructionMode = isInstructionMode
        let attachments = attachedContexts
        // Snapshot history *before* this turn - drives both the API call
        // (Anthropic Messages format wants prior turns ordered chronologically)
        // and the auto-paste decision (only paste if this is the first turn).
        let preChatHistory = chatHistory
        let isFirstChatTurn = preChatHistory.isEmpty

        // Delay clearing attachments so the content cross-fades first,
        // then the panel smoothly collapses to its base height
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.clearAllAttachments()
        }

        // Hand the final chunk to the rolling pipeline. Everything before
        // it has been transcribing in the background since ~40s into the
        // take, so even an hour-long recording only waits on the tail.
        let session = transcriptionSession ?? TranscriptionSession(transcriber: transcriber)
        transcriptionSession = nil
        session.submit(chunkURL: audioURL)
        chunksTotal = session.chunksSubmitted
        // Stays true through the tail chunks so onProgress keeps pasting
        // them; cleared once finish() resolves.
        let liveInsertWasActive = liveInsertActive

        Task {
            do {
                let rawText = try await session.finish()
                await MainActor.run { self.liveInsertActive = false }

                guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    await MainActor.run {
                        if !self.isChatActive {
                            self.state = .error(message: "No speech detected")
                            self.resetInstructionMode()
                            self.autoDismiss(after: 2)
                        } else {
                            // Chat is open - silently drop the empty take.
                            self.resetInstructionMode()
                            self.state = .idle
                            self.bumpChatIdleTimer()
                        }
                    }
                    return
                }

                await MainActor.run {
                    self.state = .refining
                }

                let settings = store.settings

                // Agent path: only on the *first* turn, since agents own
                // their own conversation semantics. Once we're in a Claude
                // chat we don't suddenly hand over to an agent mid-thread.
                // Renders inside the chat panel - user bubble, then a
                // small step timeline (web search, data analysis, …)
                // that resolves into the final text bubble.
                if instructionMode, isFirstChatTurn, !settings.apiKey.isEmpty,
                   let match = await detectAgent(in: rawText, apiKey: settings.apiKey) {
                    await MainActor.run {
                        let userTurn = ChatTurn(role: .user, text: match.cleanedText, attachments: attachments)
                        let assistantTurn = ChatTurn(role: .assistant, text: "", isStreaming: true)
                        self.chatHistory.append(userTurn)
                        self.chatHistory.append(assistantTurn)
                        self.isStreamingResponse = true
                        self.isAgentMode = true
                        self.activeAgentName = match.agent.name
                        self.chatIdleTimer?.invalidate()
                        self.chatIdleTimer = nil
                    }

                    let finalText = try await agentClient.execute(
                        agentId: match.agent.agentId,
                        userMessage: match.cleanedText,
                        attachments: attachments,
                        apiKey: settings.apiKey,
                        onStatusUpdate: { [weak self] phase in
                            DispatchQueue.main.async { [weak self] in
                                self?.appendAgentStep(phase: phase)
                            }
                        }
                    )

                    await MainActor.run {
                        if let lastIdx = self.chatHistory.indices.last,
                           self.chatHistory[lastIdx].role == .assistant {
                            // Mark the trailing step as completed before
                            // flipping the bubble out of streaming mode.
                            if !self.chatHistory[lastIdx].agentSteps.isEmpty {
                                let stepIdx = self.chatHistory[lastIdx].agentSteps.count - 1
                                self.chatHistory[lastIdx].agentSteps[stepIdx].completed = true
                            }
                            self.chatHistory[lastIdx].text = finalText
                            self.chatHistory[lastIdx].isStreaming = false
                        }
                        self.isStreamingResponse = false

                        // Same close-mid-stream guard as the Claude path.
                        guard self.isChatActive else { return }

                        self.lastTranscriptionResult = finalText
                        self.store.addTranscript(finalText, isInstruction: true)

                        // First turn → auto-paste once, then stay in chat
                        // so the user can iterate (the iteration goes back
                        // to plain Claude, since agent runs are one-shot).
                        self.state = .result(text: finalText)
                        self.insertResult(finalText)
                        self.state = .idle
                        // Reply done → re-open the mic for a hands-free
                        // follow-up (falls back to the idle countdown).
                        self.beginFollowUpListening()
                    }
                } else if instructionMode {
                    // Chat path: append user turn + streaming assistant turn,
                    // mutate the assistant turn's text as deltas arrive, then
                    // either paste-and-stay (first turn) or just stay (later).
                    await MainActor.run {
                        let userTurn = ChatTurn(role: .user, text: rawText, attachments: attachments)
                        let assistantTurn = ChatTurn(role: .assistant, text: "", isStreaming: true)
                        self.chatHistory.append(userTurn)
                        self.chatHistory.append(assistantTurn)
                        self.isStreamingResponse = true
                        // Pause the idle timer while the model is generating.
                        self.chatIdleTimer?.invalidate()
                        self.chatIdleTimer = nil
                    }

                    let terms = store.dictionary.map { $0.term }
                    let snips = store.snippets.map { (name: $0.name, text: $0.text) }
                    let finalText = try await refiner.instructConversation(
                        history: preChatHistory,
                        newTurnText: rawText,
                        newTurnAttachments: attachments,
                        apiKey: settings.apiKey,
                        dictionaryTerms: terms,
                        snippets: snips,
                        onChunk: { [weak self] fullStrippedText in
                            // The refiner hands us the full accumulated
                            // text (markdown-stripped) on every tick, so
                            // we replace rather than append. This avoids
                            // a brief flash of raw `**bold**` while
                            // partial chunks haven't yet closed their
                            // delimiters.
                            DispatchQueue.main.async {
                                guard let self = self else { return }
                                guard let lastIdx = self.chatHistory.indices.last,
                                      self.chatHistory[lastIdx].role == .assistant,
                                      self.chatHistory[lastIdx].isStreaming else { return }
                                self.chatHistory[lastIdx].text = fullStrippedText
                            }
                        }
                    )

                    await MainActor.run {
                        // Replace with the trimmed final text (chunks may
                        // have left whitespace at the edges) and clear
                        // the streaming flag.
                        if let lastIdx = self.chatHistory.indices.last,
                           self.chatHistory[lastIdx].role == .assistant {
                            self.chatHistory[lastIdx].text = finalText
                            self.chatHistory[lastIdx].isStreaming = false
                        }
                        self.isStreamingResponse = false

                        // Bail out if the user closed the chat mid-stream
                        // (Esc / X). closeChat already cleared chatHistory
                        // and set state to .idle - don't paste after the
                        // user just told us they're done.
                        guard self.isChatActive else { return }

                        self.lastTranscriptionResult = finalText
                        self.store.addTranscript(finalText, isInstruction: true)

                        if isFirstChatTurn {
                            // First reply pastes once into the focused app -
                            // the user can keep iterating in the chat to
                            // refine, but we don't keep stamping new pastes.
                            self.state = .result(text: finalText)
                            self.insertResult(finalText)
                        } else {
                            self.resetInstructionMode()
                        }
                        self.state = .idle
                        // Reply done → re-open the mic for a hands-free
                        // follow-up (falls back to the idle countdown).
                        self.beginFollowUpListening()
                    }
                } else if liveInsertWasActive {
                    // Live streaming already pasted every chunk into the
                    // focused field as it finished - including the tail,
                    // whose onProgress fired before finish() resolved.
                    // Nothing left to insert; just record and dismiss.
                    await MainActor.run {
                        self.lastTranscriptionResult = rawText
                        self.store.addTranscript(rawText, isInstruction: false)
                        self.state = .result(text: rawText)
                        self.startDismissSequence()
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
                        self.state = .result(text: finalText)
                        if self.insertResult(finalText) {
                            self.startDismissSequence()
                        } else {
                            // No editable field was focused when recording
                            // began - surface the take in the rescue card so
                            // the user can copy it manually.
                            self.showFallback(finalText)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    // If a streaming assistant turn was added but never
                    // completed, drop it so the chat doesn't show an
                    // empty bubble next to an error.
                    if let lastIdx = self.chatHistory.indices.last,
                       self.chatHistory[lastIdx].role == .assistant,
                       self.chatHistory[lastIdx].isStreaming {
                        self.chatHistory.remove(at: lastIdx)
                    }
                    self.isStreamingResponse = false
                    self.resetInstructionMode()
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

    private func resetInstructionMode() {
        isInstructionMode = false
        isAgentMode = false
        agentStatus = nil
        activeAgentName = nil
        // Don't wipe attachments when chat is open - the user may have
        // pre-attached new clipboard items between turns and is waiting
        // to send them in the next follow-up. The deferred clear in
        // stopRecording handles consuming attachments for the current
        // turn; we don't want a second clear stomping new ones.
        if !isChatActive {
            clearAllAttachments()
        }
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

    /// Paste the finished take into the app that was frontmost when
    /// recording began. Returns false only when we positively determined -
    /// at record start, the one reliable moment - that there was no editable
    /// field focused; the caller then shows the rescue card instead. In
    /// every other case (a field was focused, OR we couldn't tell) we paste,
    /// so a real text field never gets withheld.
    @discardableResult
    private func insertResult(_ text: String) -> Bool {
        let targetPID = recordingTargetPID
        let editable = recordingTargetEditable
        recordingTargetPID = nil
        resetInstructionMode()

        guard editable else { return false }

        deliverPaste(text, reactivating: targetPID)
        return true
    }

    /// Whether the system-wide focused UI element is an editable text
    /// surface. Read at record start, when the target app is frontmost and
    /// its caret is live - the only point this is dependable.
    ///
    /// Biases hard toward "yes": no Accessibility grant, an app that doesn't
    /// speak AX, or any failed query all return true so we never withhold a
    /// paste. We only return false when the API positively tells us either
    /// that nothing is focused or that the focused thing has no text
    /// behaviour at all.
    private static func focusedElementIsEditable() -> Bool {
        guard AXIsProcessTrusted() else { return true }

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
        guard err == .success else { return true }
        // Attribute present but empty → genuinely nothing focused.
        guard let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return false
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

        return classifyEditable(role: role, subrole: subrole, valueSettable: valueSettable, element: element)
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

    /// The single paste path: stash the clipboard, bring the target app
    /// forward, synthesize Cmd+V, then restore the clipboard. Used by both
    /// the auto-paste of a finished take and the per-bubble "paste this
    /// version" action.
    private func deliverPaste(_ text: String, reactivating pid: pid_t?) {
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

        // Mute the watcher across the entire paste-and-restore window
        // so our own clipboard mutations don't get captured as chips.
        clipboardWatchSuppressed = true

        // Bring the target app forward. It's usually still frontmost (our
        // overlay is a non-activating panel), but the detached chat tile
        // can take activation - so re-assert it and give the OS a beat to
        // make the app key before the keystroke lands, otherwise Cmd+V is
        // delivered to the wrong place.
        let reactivated: Bool
        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
            reactivated = true
        } else {
            reactivated = false
        }

        let fire: () -> Void = { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.pasteClipboard()

            // Restore the previous clipboard once the paste has landed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                NSPasteboard.general.clearContents()
                for itemDict in savedItems {
                    let item = NSPasteboardItem()
                    for (type, data) in itemDict {
                        item.setData(data, forType: NSPasteboard.PasteboardType(type))
                    }
                    NSPasteboard.general.writeObjects([item])
                }
                // Snap the watcher's baseline forward and re-enable it.
                // Anything copied after this point is a real attachment.
                self?.clipboardBaselineChangeCount = NSPasteboard.general.changeCount
                self?.clipboardWatchSuppressed = false
            }
        }

        if reactivated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: fire)
        } else {
            fire()
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
        // Tiny hold so the paste visibly lands, then the pill exits -
        // slight scale-down + blur + fade, 0.14s (OverlayView's
        // unified-pill exit) - before the panel goes idle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard case .result = self?.state else { return }
            self?.state = .dismissing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard case .dismissing = self?.state else { return }
                self?.state = .idle
            }
        }
    }

    // MARK: - Accessibility

    static func ensureAccessibility() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    private func pasteClipboard() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    func insertSnippet(_ snippet: Snippet) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet.text, forType: .string)
        pasteClipboard()
    }

    /// Send `text` to the focused app via the clipboard, then restore
    /// whatever was there. Used by the per-bubble "paste this version"
    /// action so the user can commit a later iteration of an AI reply.
    func pasteIntoTargetApp(_ text: String) {
        // Re-activate the original target if we still know it; otherwise
        // deliverPaste falls through to whatever is currently frontmost.
        deliverPaste(text, reactivating: recordingTargetPID)
    }

    /// Copy `text` to the system clipboard, no paste. Lightweight
    /// counterpart to pasteIntoTargetApp for the chat bubble actions.
    /// Same suppression dance as the auto-paste - if we don't mute the
    /// watcher across our own write, the watcher's next tick captures
    /// the copied text as a context chip on the next turn.
    func copyToClipboard(_ text: String) {
        clipboardWatchSuppressed = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.clipboardBaselineChangeCount = NSPasteboard.general.changeCount
            self?.clipboardWatchSuppressed = false
        }
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
