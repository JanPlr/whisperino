import AppKit
import Carbon
import Combine
import CoreGraphics

enum TranscriptionState: Equatable {
    case idle
    case recording
    case paused
    case transcribing
    case result(text: String)
    case dismissing
    case error(message: String)
}

class AppState: ObservableObject {
    @Published var state: TranscriptionState = .idle
    @Published var audioLevel: Float = 0
    @Published var recordingStartTime: Date?

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()

    /// Timestamp when the hotkey was pressed (for push-to-talk detection)
    private var hotkeyPressTime: Date?
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
        case .transcribing:
            break
        }
    }

    /// Called when the hotkey is pressed down
    func hotkeyPressed() {
        hotkeyPressTime = Date()
        switch state {
        case .idle, .result, .error, .dismissing:
            startRecording()
        case .recording, .paused:
            stopRecording()
        case .transcribing:
            break
        }
    }

    /// Called when the hotkey is released — stops recording if held long enough (push-to-talk)
    func hotkeyReleased() {
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
        do {
            try recorder.resume()
            state = .recording
        } catch {
            state = .error(message: "Resume failed")
            autoDismiss(after: 3)
        }
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
        recordingStartTime = nil
        state = .transcribing

        Task {
            do {
                let text = try await transcriber.transcribe(audioURL: audioURL)
                await MainActor.run {
                    guard !text.isEmpty else {
                        self.state = .error(message: "No speech detected")
                        self.autoDismiss(after: 2)
                        return
                    }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    self.state = .result(text: text)
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

    private func autoDismiss(after seconds: Double) {
        let currentState = state
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.state == currentState {
                self?.state = .idle
            }
        }
    }
}
