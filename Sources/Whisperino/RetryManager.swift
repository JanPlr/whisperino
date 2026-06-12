import Foundation

/// Re-runs the transcription pipeline on a retained recording from the
/// History tab (failed, cancelled, or crash-recovered dictations). Owns
/// its own transcriber/refiner so the Settings UI doesn't need a
/// reference to AppState.
@MainActor
final class RetryManager: ObservableObject {
    static let shared = RetryManager()

    /// ID of the history entry currently being retried (drives the
    /// spinner in the History tab). One retry at a time.
    @Published var retryingID: UUID?

    private let transcriber = Transcriber()
    private let refiner = LLMRefiner()
    private let store = SettingsStore.shared

    private init() {}

    func retry(_ entry: TranscriptEntry) {
        guard retryingID == nil, let filename = entry.audioFilename else { return }
        let audioURL = store.recordingsDir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            store.setFailureReason(id: entry.id, reason: "Recording file is missing")
            return
        }

        retryingID = entry.id
        Task {
            defer { retryingID = nil }
            do {
                let rawText = try await transcriber.transcribe(audioURL: audioURL)
                guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    store.setFailureReason(id: entry.id, reason: "No speech detected")
                    return
                }

                var finalText = rawText
                var rawForHistory: String? = nil
                let settings = store.settings
                if settings.llmRefinementEnabled, !settings.apiKey.isEmpty,
                   let refined = try? await refiner.refine(
                        text: rawText,
                        apiKey: settings.apiKey,
                        dictionaryTerms: store.dictionary.map { $0.term }
                   ),
                   refined != rawText {
                    finalText = refined
                    rawForHistory = rawText
                }

                store.resolveTranscript(id: entry.id, text: finalText, rawText: rawForHistory)
            } catch {
                store.setFailureReason(id: entry.id, reason: error.localizedDescription)
            }
        }
    }
}
