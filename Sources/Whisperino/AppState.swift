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
    @Published var audioLevel: Float = 0
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
        showingInputPicker = false
        isLatchedRecording = false
        windowHighlighter.dismiss()
        screenshotTask?.cancel()
        screenshotTask = nil
        abandonTranscriptionSession()
        if let url = recorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        stopWaveformSampling()
        audioLevel = 0
        recordingStartTime = nil
        recordingTargetPID = nil
        resetInstructionMode()
        state = finalState
    }

    /// Enter / "finish" gesture (the ✓ button / Enter). While recording,
    /// submits the current take. Otherwise dismisses the fallback card if up.
    func submitOrFinish() {
        switch state {
        case .recording:
            stopRecording()
        default:
            if fallbackResult != nil {
                dismissFallback()
            }
        }
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

    // MARK: - Recording

    private func startRecording(instruction: Bool) {
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
        }

        // Capture the frontmost app so we can re-activate it before pasting,
        // and whether it has a focused editable field *right now* - while the
        // target is frontmost and its caret is live, which is the only moment
        // this can be read reliably.
        recordingTargetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        recordingTargetEditable = Self.focusedElementIsEditable()

        // AI mode: silently grab the current screen as image context and flash
        // a frame around the window we captured, so the user can just talk to
        // whatever's on screen. Done before recording so the model reasons
        // about the screen as it looked when the user started, not after any
        // reaction to the pill.
        if instruction {
            captureScreenContext(pid: recordingTargetPID)
        }

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
            SoundEffects.playStart()
            recordingStartTime = Date()
            state = .recording
        } catch {
            state = .error(message: "Mic error: \(error.localizedDescription)")
            autoDismiss(after: 4)
        }
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
        showingInputPicker = false
        // The latch ends with the take (Enter-submit bypasses the
        // HotkeyManager release path, so clear it here too).
        isLatchedRecording = false
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
        // Snapshot the in-flight screen capture on the main actor so the
        // response Task reads a stable reference (resetInstructionMode may
        // clear the property concurrently).
        let pendingShot = screenshotTask

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
                        self.state = .error(message: "No speech detected")
                        self.resetInstructionMode()
                        self.autoDismiss(after: 2)
                    }
                    return
                }

                await MainActor.run {
                    self.state = .refining
                }

                let settings = store.settings

                // AI mode is one-shot: transcription + the screen screenshot go
                // to the agent (if named) or Claude, and the answer is pasted
                // straight into the focused field. No conversation is kept - to
                // iterate, the user starts AI mode again and the fresh
                // screenshot captures whatever's now on screen (including the
                // last answer).
                if instructionMode {
                    // The screen capture is the only context for the take.
                    var contextAttachments: [AttachedContext] = []
                    if let shot = await Self.resolveScreenshotAttachment(pendingShot) {
                        contextAttachments.append(shot)
                    }

                    if !settings.apiKey.isEmpty,
                       let match = await detectAgent(in: rawText, apiKey: settings.apiKey) {
                        await MainActor.run {
                            self.isAgentMode = true
                            self.activeAgentName = match.agent.name
                        }

                        let finalText = try await agentClient.execute(
                            agentId: match.agent.agentId,
                            userMessage: match.cleanedText,
                            attachments: contextAttachments,
                            apiKey: settings.apiKey,
                            onStatusUpdate: { _ in }
                        )

                        await MainActor.run {
                            self.deliverAIResult(finalText)
                        }
                    } else {
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

                        await MainActor.run {
                            self.deliverAIResult(finalText)
                        }
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
                        // Chunks were pasted individually as they finished;
                        // fire a single Return now if the target auto-submits.
                        if self.shouldAutoSubmit(pid: self.recordingTargetPID) {
                            self.autoSubmitReturn(reactivating: self.recordingTargetPID)
                        }
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

    /// Finish an AI-mode take: record the answer, paste it into the focused
    /// field, and take the pill down - or fall back to the rescue card when
    /// there was nowhere to paste. The one-shot counterpart to the raw
    /// dictation finish path.
    private func deliverAIResult(_ finalText: String) {
        lastTranscriptionResult = finalText
        store.addTranscript(finalText, isInstruction: true)
        state = .result(text: finalText)
        if insertResult(finalText) {
            startDismissSequence()
        } else {
            showFallback(finalText)
        }
    }

    private func resetInstructionMode() {
        isInstructionMode = false
        isAgentMode = false
        agentStatus = nil
        activeAgentName = nil
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

        deliverPaste(text, reactivating: targetPID, submitAfter: shouldAutoSubmit(pid: targetPID))
        return true
    }

    /// Whether the app that was frontmost at record start is on the
    /// auto-submit list, so we should press Return once the paste lands
    /// (submitting the chat message for the user).
    private func shouldAutoSubmit(pid: pid_t?) -> Bool {
        guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return store.autoSubmitEnabled(forBundleId: app.bundleIdentifier)
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
    /// forward, synthesize Cmd+V, then restore the clipboard.
    private func deliverPaste(_ text: String, reactivating pid: pid_t?, submitAfter: Bool = false) {
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
        // overlay is a non-activating panel), but re-assert it and give the OS
        // a beat to make the app key before the keystroke lands, otherwise
        // Cmd+V is delivered to the wrong place.
        let reactivated: Bool
        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
            reactivated = true
        } else {
            reactivated = false
        }

        let fire: () -> Void = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.pasteClipboard()

            // Auto-submit: press Return after the paste lands so the chat
            // message is sent. Sits between paste and clipboard restore -
            // Return touches no pasteboard, so ordering is safe.
            if submitAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    self.pressReturn()
                }
            }

            // Restore the previous clipboard once the paste has landed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
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

    /// Re-activate the target app and press Return, for the live-streaming
    /// path where chunks were pasted separately and no final `deliverPaste`
    /// carried the submit keystroke.
    private func autoSubmitReturn(reactivating pid: pid_t?) {
        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.pressReturn()
            }
        } else {
            pressReturn()
        }
    }

    /// Synthesize a Return keystroke - used to auto-submit a pasted
    /// dictation in apps the user configured for it (chat inputs).
    private func pressReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Return), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Return), keyDown: false)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Send `text` to the focused app via the clipboard, then restore
    /// whatever was there. Used by the per-bubble "paste this version"
    /// action so the user can commit a later iteration of an AI reply.
    func pasteIntoTargetApp(_ text: String) {
        // Re-activate the original target if we still know it; otherwise
        // deliverPaste falls through to whatever is currently frontmost.
        deliverPaste(text, reactivating: recordingTargetPID)
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
