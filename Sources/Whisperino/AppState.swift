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
        toggleRecording(instruction: false)
    }

    func instructionHotkeyToggle() {
        toggleRecording(instruction: true)
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

        state = .cancelled
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

    /// Capture the current main display as an image and attach it. Lets the
    /// LLM "see your screen" alongside whatever you're saying. Requires
    /// Screen Recording permission — macOS prompts on first invocation.
    func addScreenshotAttachment() {
        guard attachedContexts.count < Self.maxAttachments else { return }
        let displayID = CGMainDisplayID()
        guard let cgImage = CGDisplayCreateImage(displayID) else {
            // Permission not granted yet — system prompt was just shown.
            // Open Privacy & Security so the user can flip the toggle.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        let nsImage = NSImage(cgImage: cgImage, size: size)
        let preview = "Screen (\(cgImage.width)×\(cgImage.height))"
        let ctx = AttachedContext(content: .image(nsImage), preview: preview)
        attachedContexts.append(ctx)
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
            guard let self = self else { return }
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

    // MARK: - Recording

    private func startRecording(instruction: Bool) {
        guard isSetUp else {
            state = .error(message: "Run setup.sh first")
            autoDismiss(after: 4)
            return
        }

        isInstructionMode = instruction

        if instruction {
            // In instruction mode, require API key + LLM to be configured
            let settings = store.settings
            if settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state = .error(message: "Add API key in Settings first")
                autoDismiss(after: 3)
                return
            }
            guard settings.llmRefinementEnabled else {
                state = .error(message: "Enable LLM refinement in Settings first")
                autoDismiss(after: 3)
                return
            }
            // Reset attachments from any previous session
            clearAllAttachments()
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
        stopClipboardWatching()
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
                        self.state = .error(message: "No speech detected")
                        self.resetInstructionMode()
                        self.autoDismiss(after: 2)
                    }
                    return
                }

                await MainActor.run {
                    self.state = .refining
                }

                let finalText: String
                let settings = store.settings

                if instructionMode, !settings.apiKey.isEmpty, let match = await detectAgent(in: rawText, apiKey: settings.apiKey) {
                    // Agent mode: route to Langdock Agent API with streaming
                    await MainActor.run {
                        self.isAgentMode = true
                        self.activeAgentName = match.agent.name
                        self.agentStatus = AgentPhase.thinking.displayText
                    }
                    finalText = try await agentClient.execute(
                        agentId: match.agent.agentId,
                        userMessage: match.cleanedText,
                        attachments: attachments,
                        apiKey: settings.apiKey,
                        onStatusUpdate: { [weak self] phase in
                            let text = phase.displayText
                            DispatchQueue.main.async { [weak self] in
                                self?.agentStatus = text
                            }
                        }
                    )
                } else if instructionMode {
                    // Instruction mode: send spoken text as instructions to LLM
                    let terms = store.dictionary.map { $0.term }
                    let snips = store.snippets.map { (name: $0.name, text: $0.text) }
                    finalText = try await refiner.instruct(
                        transcription: rawText,
                        apiKey: settings.apiKey,
                        attachments: attachments,
                        dictionaryTerms: terms,
                        snippets: snips
                    )
                } else if settings.llmRefinementEnabled && !settings.apiKey.isEmpty {
                    // Transcription mode: clean up speech
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
                    self.store.addTranscript(finalText, isInstruction: instructionMode)
                    self.state = .result(text: finalText)
                    self.insertResult(finalText)
                    self.startDismissSequence()
                }
            } catch {
                await MainActor.run {
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
        clearAllAttachments()
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

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        pasteClipboard()

        // Restore previous clipboard after paste completes
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

    private func autoDismiss(after seconds: Double) {
        let currentState = state
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.state == currentState {
                self?.state = .idle
            }
        }
    }
}
