import AppKit
import Carbon
import Combine
import CoreGraphics

enum TranscriptionState: Equatable {
    case idle
    case recording
    case paused
    case transcribing
    case refining
    case result(text: String)
    case dismissing
    case error(message: String)
}

/// What the clipboard attachment contains
enum ClipboardContent {
    case text(String)
    case image(NSImage)
}

class AppState: ObservableObject {
    @Published var state: TranscriptionState = .idle
    @Published var audioLevel: Float = 0
    @Published var recordingStartTime: Date?
    /// Non-nil when clipboard is attached in instruction mode; contains a short preview string
    @Published var clipboardPreview: String? = nil
    /// Whether we are currently in instruction mode (Shift+hotkey)
    @Published var isInstructionMode: Bool = false

    private(set) var lastTranscriptionResult: String?
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let refiner = LLMRefiner()
    private let store = SettingsStore.shared

    /// Timestamp when the hotkey was pressed (for push-to-talk detection)
    private var hotkeyPressTime: Date?
    /// Whether the hotkey is currently held (to ignore key repeat events)
    private var isHotkeyHeld = false
    /// Hold longer than this to activate push-to-talk mode
    private let pushToTalkThreshold: TimeInterval = 0.4
    /// PID of the app that was frontmost when recording started
    private var recordingTargetPID: pid_t?
    /// Text context extracted from the frontmost app for LLM context awareness
    private var extractedContext: String?
    /// Clipboard content attached by user for instruction mode
    private var clipboardContent: ClipboardContent? = nil

    var isSetUp: Bool { transcriber.isAvailable }

    // MARK: - Hotkey handlers

    func hotkeyPressed() {
        guard !isHotkeyHeld else { return }
        isHotkeyHeld = true
        hotkeyPressTime = Date()
        handlePress(instruction: false)
    }

    func hotkeyReleased() {
        isHotkeyHeld = false
        handleRelease()
    }

    func instructionHotkeyPressed() {
        guard !isHotkeyHeld else { return }
        isHotkeyHeld = true
        hotkeyPressTime = Date()
        handlePress(instruction: true)
    }

    func instructionHotkeyReleased() {
        isHotkeyHeld = false
        handleRelease()
    }

    private func handlePress(instruction: Bool) {
        switch state {
        case .idle, .result, .error, .dismissing:
            startRecording(instruction: instruction)
        case .recording:
            guard let startTime = recordingStartTime,
                  Date().timeIntervalSince(startTime) >= 0.3 else { return }
            stopRecording()
        case .paused:
            stopRecording()
        case .transcribing, .refining:
            break
        }
    }

    private func handleRelease() {
        isHotkeyHeld = false
        guard case .recording = state,
              let pressTime = hotkeyPressTime,
              Date().timeIntervalSince(pressTime) > pushToTalkThreshold else {
            return
        }
        stopRecording()
    }

    // MARK: - Toggle Recording (waveform tap)

    func toggleRecording() {
        switch state {
        case .idle, .result, .error, .dismissing:
            startRecording(instruction: isInstructionMode)
        case .recording, .paused:
            stopRecording()
        case .transcribing, .refining:
            break
        }
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
        if let url = recorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        audioLevel = 0
        recordingStartTime = nil
        recordingTargetPID = nil
        extractedContext = nil
        resetInstructionMode()
        state = .idle
    }

    // MARK: - Clipboard Attachment (instruction mode only)

    /// Toggle clipboard attachment on/off. Reads current clipboard content.
    func toggleClipboardAttachment() {
        if clipboardContent != nil {
            // Detach
            clipboardContent = nil
            clipboardPreview = nil
        } else {
            // Attach from clipboard
            let pb = NSPasteboard.general
            if let image = NSImage(pasteboard: pb) {
                clipboardContent = .image(image)
                clipboardPreview = "Image"
            } else if let text = pb.string(forType: .string), !text.isEmpty {
                clipboardContent = .text(text)
                let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
                clipboardPreview = String(preview.prefix(50))
            }
        }
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
            // In instruction mode, require LLM to be configured
            let settings = store.settings
            guard settings.llmRefinementEnabled && !settings.apiKey.isEmpty else {
                state = .error(message: "Instruction mode requires LLM — enable in Settings")
                autoDismiss(after: 4)
                return
            }
            // Reset clipboard attachment from any previous session
            clipboardContent = nil
            clipboardPreview = nil
        }

        // Capture the frontmost app so we can re-activate it before pasting
        recordingTargetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Extract text context (transcription mode only, when enabled)
        let settings = store.settings
        if !instruction && settings.contextAwarenessEnabled && settings.llmRefinementEnabled,
           let pid = recordingTargetPID {
            extractedContext = ContextExtractor.extractContext(from: pid)
            let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".whisperino")
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let msg = "[whisperino] Context extracted: \(extractedContext != nil ? "\(extractedContext!.prefix(300))…" : "nil")\n"
            let logFile = logDir.appendingPathComponent("debug.log")
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile(); handle.write(msg.data(using: .utf8)!); handle.closeFile()
            } else {
                try? msg.write(to: logFile, atomically: true, encoding: .utf8)
            }
        } else {
            extractedContext = nil
        }

        do {
            try recorder.start { [weak self] level in
                DispatchQueue.main.async {
                    self?.audioLevel = level
                }
            }
            recordingStartTime = Date()
            state = .recording
        } catch {
            state = .error(message: "Mic error: \(error.localizedDescription)")
            autoDismiss(after: 4)
        }
    }

    private func stopRecording() {
        guard let audioURL = recorder.stop() else {
            state = .idle
            return
        }
        audioLevel = 0
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartTime = nil

        guard duration >= 0.5 else {
            try? FileManager.default.removeItem(at: audioURL)
            state = .idle
            return
        }

        state = .transcribing

        let instructionMode = isInstructionMode
        let attachedClipboard = clipboardContent

        Task {
            do {
                let rawText = try await transcriber.transcribe(audioURL: audioURL)
                await MainActor.run {
                    guard !rawText.isEmpty else {
                        self.state = .error(message: "No speech detected")
                        self.autoDismiss(after: 2)
                        return
                    }
                    self.state = .refining
                }

                let finalText: String
                let settings = store.settings

                if instructionMode {
                    // Instruction mode: send spoken text as instructions to LLM
                    finalText = try await refiner.instruct(
                        transcription: rawText,
                        apiKey: settings.apiKey,
                        clipboardContent: attachedClipboard
                    )
                } else if settings.llmRefinementEnabled && !settings.apiKey.isEmpty {
                    // Transcription mode: clean up speech
                    do {
                        let terms = store.dictionary.map { $0.term }
                        finalText = try await refiner.refine(
                            text: rawText,
                            apiKey: settings.apiKey,
                            dictionaryTerms: terms,
                            surroundingContext: self.extractedContext
                        )
                    } catch {
                        print("[whisperino] LLM refinement failed — using raw text")
                        finalText = rawText
                    }
                } else {
                    finalText = rawText
                }

                await MainActor.run {
                    self.lastTranscriptionResult = finalText
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(finalText, forType: .string)
                    self.state = .result(text: finalText)
                    self.activateTargetAndPaste()
                    self.startDismissSequence()
                }
            } catch {
                await MainActor.run {
                    self.state = .error(message: instructionMode ? "Instruction failed" : "Transcription failed")
                    self.autoDismiss(after: 3)
                }
            }
        }
    }

    private func resetInstructionMode() {
        isInstructionMode = false
        clipboardContent = nil
        clipboardPreview = nil
    }

    // MARK: - Paste

    private func activateTargetAndPaste() {
        let targetPID = recordingTargetPID
        recordingTargetPID = nil
        extractedContext = nil
        resetInstructionMode()

        if let pid = targetPID,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }

        pasteClipboard()
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
