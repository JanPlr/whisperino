import AppKit
import Combine

enum TranscriptionState: Equatable {
    case idle
    case recording
    case transcribing
    case result(text: String)
    case error(message: String)
}

@MainActor
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
                Task { @MainActor in
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
                guard !text.isEmpty else {
                    state = .error(message: "No speech detected")
                    autoDismiss(after: 2)
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                state = .result(text: text)
                autoDismiss(after: 3)
            } catch {
                state = .error(message: "Transcription failed")
                autoDismiss(after: 3)
            }
        }
    }

    private func autoDismiss(after seconds: Double) {
        let currentState = state
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if state == currentState {
                state = .idle
            }
        }
    }
}
