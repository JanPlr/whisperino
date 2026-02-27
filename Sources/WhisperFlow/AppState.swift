import AppKit
import Carbon
import Combine
import CoreGraphics

enum TranscriptionState: Equatable {
    case idle
    case recording
    case transcribing
    case result(text: String)
    case error(message: String)
}

class AppState: ObservableObject {
    @Published var state: TranscriptionState = .idle
    @Published var audioLevel: Float = 0
    @Published var recordingStartTime: Date?

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()

    var isSetUp: Bool { transcriber.isAvailable }

    func toggleRecording() {
        switch state {
        case .idle, .result, .error:
            startRecording()
        case .recording:
            stopRecording()
        case .transcribing:
            break
        }
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
                    self.autoDismiss(after: 3)
                }
            } catch {
                await MainActor.run {
                    self.state = .error(message: "Transcription failed")
                    self.autoDismiss(after: 3)
                }
            }
        }
    }

    /// Request accessibility permission (shows system prompt if not yet granted)
    static func ensureAccessibility() {
        let trusted = AXIsProcessTrusted()
        NSLog("[WhisperFlow] Accessibility trusted: \(trusted)")
        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    private func simulatePaste() {
        // CGEvent is instant; AppleScript spawns a subprocess and takes seconds
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
