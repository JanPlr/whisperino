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

/// A single attached context item (clipboard text or image)
struct AttachedContext: Identifiable {
    let id = UUID()
    let content: ClipboardContent
    let preview: String
}

/// One entry in an AI-mode conversation. Ephemeral — never persisted —
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
    /// Index 0 = oldest, last index = newest. Updated at a fixed rate so
    /// the visual rolls smoothly even when the recorder callback bursts.
    @Published var audioSamples: [Float] = Array(repeating: 0, count: AppState.waveformBarCount)
    @Published var recordingStartTime: Date?
    /// Accumulated clipboard attachments for instruction mode
    @Published var attachedContexts: [AttachedContext] = []
    /// Whether we are currently in instruction mode (Shift+hotkey)
    @Published var isInstructionMode: Bool = false
    /// Whether the current request is routed to a Langdock Agent
    @Published var isAgentMode: Bool = false
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

    /// Maximum number of attachments allowed
    static let maxAttachments = 5

    /// Number of bars shown in the waveform display.
    static let waveformBarCount = 9

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

    private(set) var lastTranscriptionResult: String?
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let refiner = LLMRefiner()
    private let agentClient = AgentClient()
    private let store = SettingsStore.shared

    /// PID of the app that was frontmost when recording started
    private var recordingTargetPID: pid_t?

    /// Drives the waveform's rolling history. The rightmost bar tracks
    /// audio level in real-time via the recorder callback; this timer just
    /// shifts the value into history at a fixed cadence so the wave
    /// visibly travels right-to-left.
    private var sampleTimer: Timer?

    /// Polls the system pasteboard during instruction mode so that anything
    /// the user copies (Cmd+C) gets auto-attached as context. Saves manual
    /// clicks on the paperclip.
    private var clipboardWatchTimer: Timer?
    private var clipboardBaselineChangeCount: Int = 0
    /// While we're driving the pasteboard ourselves (auto-paste of an
    /// AI reply, restore of the user's prior clipboard), the watcher
    /// must ignore the resulting changes — otherwise our own paste
    /// gets captured as a context chip on the next turn.
    private var clipboardWatchSuppressed: Bool = false

    var isSetUp: Bool { transcriber.isAvailable }

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
            // No min-duration gate here — push-to-talk users may briefly
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
        // Esc with chat open and no recording = close the conversation.
        // Have to branch here so cancelRecording stays the single Esc
        // sink — the alternative is forking the hotkey wiring per-state.
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
        stopClipboardWatching()
        if let url = recorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        stopWaveformSampling()
        audioLevel = 0
        recordingStartTime = nil
        recordingTargetPID = nil
        resetInstructionMode()

        // Don't show the cancel-flash animation when a chat is up — it
        // collides visually with the bubbles. Just go back to chat-idle.
        if isChatActive {
            state = .idle
            bumpChatIdleTimer()
        } else {
            state = .cancelled
        }
    }

    /// Enter / "finish" gesture. While recording, submits the current
    /// take. While chat-idle, closes the chat (the user is done).
    func submitOrFinish() {
        switch state {
        case .recording, .paused:
            stopRecording()
        default:
            if isChatActive { closeChat() }
        }
    }

    // MARK: - Waveform sampling

    private func startWaveformSampling() {
        audioSamples = Array(repeating: 0, count: Self.waveformBarCount)
        sampleTimer?.invalidate()
        // 22 Hz — every ~45ms the wave rolls one step. With a per-step decay
        // factor, the historical "trail" fades AND moves left, so when voice
        // stops the pill clears within ~250ms instead of holding stale
        // snapshots until they roll off.
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 22.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            var s = self.audioSamples
            // Gentle per-tick fade — the wave keeps enough amplitude to
            // visibly travel across the pill before it disappears off the
            // left edge (after ~9 ticks ≈ 410ms total visible duration).
            for i in 0..<s.count { s[i] *= 0.92 }
            // Roll left + append current live level (overwritten by next
            // audio callback, so the rightmost stays real-time).
            s.removeFirst()
            s.append(self.audioLevel)
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
            let ctx = AttachedContext(content: .image(image), preview: "Image (\(w)×\(h))")
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
    /// running gets auto-attached as context — no manual paperclip click.
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
        chatIdleTimer?.invalidate()
        chatIdleTimer = nil

        // If a recording is in flight, stop the recorder silently — we're
        // tearing the whole UI down, no need for the cancel-flash animation.
        switch state {
        case .recording, .paused:
            showingInputPicker = false
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
        // sessions — when chat ends, watching ends. Random Cmd+Cs after
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
    /// user is hovering the panel (reading / scrolling) — they're
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

        // "Thinking" is too generic to deserve a row — every phase
        // change between tool calls would emit one and the timeline
        // would be all thinking.
        if case .thinking = phase { return }

        // "Generating response" is the moment the assistant starts
        // producing the answer — the answer text appearing IS the
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
            // Same phase fired twice — ignore the duplicate.
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
        guard isSetUp else {
            state = .error(message: "Run setup.sh first")
            autoDismiss(after: 4)
            return
        }

        isInstructionMode = instruction

        if instruction {
            // AI mode requires API key + the AI-mode toggle. Refinement
            // is independent — users may want raw transcription but still
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
            // between turns — those count as context for *this* turn.
            if !isChatActive {
                clearAllAttachments()
            }
        }

        // Recording counts as activity — pause the chat idle countdown so
        // a slow speaker doesn't get the conversation closed under them.
        if isChatActive {
            chatIdleTimer?.invalidate()
            chatIdleTimer = nil
        }

        // Capture the frontmost app so we can re-activate it before pasting
        recordingTargetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        do {
            try recorder.start(deviceID: selectedInputDevice?.id) { [weak self] level in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.audioLevel = level
                    // Real-time tracking: rightmost bar reflects live voice
                    // immediately, no timer-tick wait. The timer below only
                    // handles rolling history from right to left.
                    if !self.audioSamples.isEmpty {
                        self.audioSamples[self.audioSamples.count - 1] = level
                    }
                }
            }
            startWaveformSampling()
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

    private func stopRecording() {
        showingInputPicker = false
        // Instruction mode means a chat will (or already does) carry
        // forward — keep clipboard watching alive so the user can
        // pre-attach context for the next turn between recordings.
        // Plain dictation has no notion of follow-up, so it stops.
        if !isInstructionMode {
            stopClipboardWatching()
        }
        guard let audioURL = recorder.stop() else {
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
            resetInstructionMode()
            state = .idle
            return
        }

        state = .transcribing

        let instructionMode = isInstructionMode
        let attachments = attachedContexts
        // Snapshot history *before* this turn — drives both the API call
        // (Anthropic Messages format wants prior turns ordered chronologically)
        // and the auto-paste decision (only paste if this is the first turn).
        let preChatHistory = chatHistory
        let isFirstChatTurn = preChatHistory.isEmpty

        // Delay clearing attachments so the content cross-fades first,
        // then the panel smoothly collapses to its base height
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.clearAllAttachments()
        }

        Task {
            do {
                let rawText = try await transcriber.transcribe(audioURL: audioURL)

                guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    await MainActor.run {
                        if !self.isChatActive {
                            self.state = .error(message: "No speech detected")
                            self.resetInstructionMode()
                            self.autoDismiss(after: 2)
                        } else {
                            // Chat is open — silently drop the empty take.
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
                // Renders inside the chat panel — user bubble, then a
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
                        self.bumpChatIdleTimer()
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
                        // and set state to .idle — don't paste after the
                        // user just told us they're done.
                        guard self.isChatActive else { return }

                        self.lastTranscriptionResult = finalText
                        self.store.addTranscript(finalText, isInstruction: true)

                        if isFirstChatTurn {
                            // First reply pastes once into the focused app —
                            // the user can keep iterating in the chat to
                            // refine, but we don't keep stamping new pastes.
                            self.state = .result(text: finalText)
                            self.insertResult(finalText)
                        } else {
                            self.resetInstructionMode()
                        }
                        self.state = .idle
                        self.bumpChatIdleTimer()
                    }
                } else {
                    // Raw transcription (non-AI) path — Haiku cleanup if
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
                        self.insertResult(finalText)
                        self.startDismissSequence()
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
                    self.state = .error(message: error.localizedDescription)
                    self.autoDismiss(after: 3)
                }
            }
        }
    }

    private func resetInstructionMode() {
        isInstructionMode = false
        isAgentMode = false
        agentStatus = nil
        activeAgentName = nil
        // Don't wipe attachments when chat is open — the user may have
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

    private func insertResult(_ text: String) {
        let targetPID = recordingTargetPID
        recordingTargetPID = nil
        resetInstructionMode()

        if let pid = targetPID,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }

        // Save current clipboard, paste transcription, then restore
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

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        pasteClipboard()

        // Restore previous clipboard after paste completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            NSPasteboard.general.clearContents()
            for itemDict in savedItems {
                let item = NSPasteboardItem()
                for (type, data) in itemDict {
                    item.setData(data, forType: NSPasteboard.PasteboardType(type))
                }
                NSPasteboard.general.writeObjects([item])
            }
            // Now that the dust has settled, snap the watcher's
            // baseline forward and re-enable it. Anything the user
            // copies after this point is a real attachment candidate.
            self?.clipboardBaselineChangeCount = NSPasteboard.general.changeCount
            self?.clipboardWatchSuppressed = false
        }
    }

    private func startDismissSequence() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard case .result = self?.state else { return }
            self?.state = .dismissing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
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
        // Re-activate the original target if we still know it. Otherwise
        // paste into whatever is currently frontmost.
        if let pid = recordingTargetPID,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }

        let savedItems = NSPasteboard.general.pasteboardItems?.compactMap { item -> [String: Data]? in
            var dict = [String: Data]()
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type.rawValue] = data
                }
            }
            return dict.isEmpty ? nil : dict
        } ?? []

        // Same suppression dance as insertResult — our own pasteboard
        // writes mustn't echo back as attachment chips.
        clipboardWatchSuppressed = true

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        pasteClipboard()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            NSPasteboard.general.clearContents()
            for itemDict in savedItems {
                let item = NSPasteboardItem()
                for (type, data) in itemDict {
                    item.setData(data, forType: NSPasteboard.PasteboardType(type))
                }
                NSPasteboard.general.writeObjects([item])
            }
            self?.clipboardBaselineChangeCount = NSPasteboard.general.changeCount
            self?.clipboardWatchSuppressed = false
        }
    }

    /// Copy `text` to the system clipboard, no paste. Lightweight
    /// counterpart to pasteIntoTargetApp for the chat bubble actions.
    /// Same suppression dance as the auto-paste — if we don't mute the
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
