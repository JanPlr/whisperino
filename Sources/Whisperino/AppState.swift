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

class AppState: ObservableObject {
    @Published var state: TranscriptionState = .idle
    @Published var audioLevel: Float = 0
    @Published var recordingStartTime: Date?
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

    var isSetUp: Bool { transcriber.isAvailable }

    /// Toggle recording (used by menu bar click and waveform tap)
    func toggleRecording() {
        switch state {
        case .idle, .result, .error, .dismissing:
            startRecording()
        case .recording, .paused:
            stopRecording()
        case .transcribing, .refining:
            break
        }
    }

    /// Called when the hotkey is pressed down
    func hotkeyPressed() {
        // Ignore key repeat events — only respond to the first press
        guard !isHotkeyHeld else { return }
        isHotkeyHeld = true
        hotkeyPressTime = Date()
        switch state {
        case .idle, .result, .error, .dismissing:
            startRecording()
        case .recording:
            // Require at least 300ms of recording before allowing a stop via hotkey.
            // This prevents key bounce or a spurious repeat press from immediately
            // stopping a recording that just started.
            guard let startTime = recordingStartTime,
                  Date().timeIntervalSince(startTime) >= 0.3 else { return }
            stopRecording()
        case .paused:
            stopRecording()
        case .transcribing, .refining:
            break
        }
    }

    /// Called when the hotkey is released — stops recording if held long enough (push-to-talk)
    func hotkeyReleased() {
        isHotkeyHeld = false
        guard case .recording = state,
              let pressTime = hotkeyPressTime,
              Date().timeIntervalSince(pressTime) > pushToTalkThreshold else {
            return
        }
        // Push-to-talk: held long enough, release stops recording
        stopRecording()
    }

    /// Pause the current recording
    func pauseRecording() {
        guard case .recording = state else { return }
        recorder.pause()
        audioLevel = 0.3
        state = .paused
    }

    /// Resume a paused recording
    func resumeRecording() {
        guard case .paused = state else { return }
        recorder.resume()
        state = .recording
    }

    /// Cancel recording and discard audio
    func cancelRecording() {
        if let url = recorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        audioLevel = 0
        recordingStartTime = nil
        state = .idle
    }

    private func startRecording() {
        guard isSetUp else {
            state = .error(message: "Run setup.sh first")
            autoDismiss(after: 4)
            return
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

        // Discard recordings shorter than 0.5s — likely a mis-tap or permission dialog timing
        guard duration >= 0.5 else {
            try? FileManager.default.removeItem(at: audioURL)
            state = .idle
            return
        }

        state = .transcribing

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

                // Optionally refine with LLM
                let finalText: String
                let settings = store.settings
                print("[whisperino] raw: \(rawText)")
                if settings.llmRefinementEnabled && !settings.apiKey.isEmpty {
                    print("[whisperino] refining with LLM (dictionary: \(store.dictionary.count) terms)…")
                    do {
                        let terms = store.dictionary.map { $0.term }
                        finalText = try await refiner.refine(text: rawText, apiKey: settings.apiKey, dictionaryTerms: terms)
                        print("[whisperino] refined: \(finalText)")
                    } catch {
                        print("[whisperino] LLM error: \(error) — using raw text")
                        finalText = rawText
                    }
                } else {
                    print("[whisperino] refinement off — using raw text")
                    finalText = rawText
                }

                await MainActor.run {
                    self.lastTranscriptionResult = finalText
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(finalText, forType: .string)
                    self.state = .result(text: finalText)
                    // Paste into focused text field
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.simulatePaste()
                    }
                    // Animated dismiss sequence: result → dismissing → idle
                    self.startDismissSequence()
                }
            } catch {
                await MainActor.run {
                    self.state = .error(message: "Transcription failed")
                    self.autoDismiss(after: 3)
                }
            }
        }
    }

    /// Animated dismiss: show result briefly, then shrink away
    private func startDismissSequence() {
        // Show "Copied to clipboard" for 1.2s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard case .result = self?.state else { return }
            self?.state = .dismissing
            // After shrink animation completes, fully hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard case .dismissing = self?.state else { return }
                self?.state = .idle
            }
        }
    }

    /// Request accessibility permission (shows system prompt if not yet granted)
    static func ensureAccessibility() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Copy snippet text to clipboard and paste it
    func insertSnippet(_ snippet: Snippet) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet.text, forType: .string)
        simulatePaste()
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
