import Foundation
import SpeakerFilteringCore
import TranscribeCpp

enum TranscriptionSessionError: LocalizedError {
    case allChunksFailed

    var errorDescription: String? {
        switch self {
        case .allChunksFailed:
            return "Transcription failed - audio kept in ~/.whisperino/recovery"
        }
    }
}

/// Rolling transcription pipeline for arbitrarily long recordings.
///
/// Instead of feeding one giant WAV to whisper after the user stops,
/// `AppState` rotates the recording into ~40s chunks at silence
/// boundaries and submits each finished chunk here while the user is
/// still speaking. Chunks are transcribed strictly in order on a serial
/// task chain, so by the time recording ends only the final chunk is
/// left to process - a 30-minute take resolves in seconds, with constant
/// memory, instead of a multi-minute single whisper run.
///
/// Nothing is lost on failure:
/// - After every chunk, the joined raw text so far is written to
///   `~/.whisperino/recovery/last-raw-transcript.txt`.
/// - A chunk whose whisper run fails keeps its WAV in the same folder
///   (`failed-chunk-N.wav`) and the rest of the take continues.
final class TranscriptionSession {
    struct Progress {
        let chunksDone: Int
        let chunksTotal: Int
        /// Joined raw text of every chunk transcribed so far.
        let text: String
    }

    /// Fired on the main thread after each chunk completes.
    var onProgress: ((Progress) -> Void)?

    private let transcriber: Transcriber
    private let languages: [String]
    private let filterToEnrolledSpeaker: Bool
    private let recoveryDir: URL
    private let recoveryFile: URL

    // `segments`/`failedCount`/`doneCount` are only touched inside the
    // serial task chain; `submittedCount`/`cancelled` only on the main
    // thread. The chain reads the latter two, which is benign - a stale
    // total just means the next progress event corrects it.
    private var segments: [String] = []
    private var failedCount = 0
    private var doneCount = 0
    private var submittedCount = 0
    private var cancelled = false
    private var chain: Task<Void, Never>?

    init(
        transcriber: Transcriber,
        languages: [String] = [],
        filterToEnrolledSpeaker: Bool = false
    ) {
        self.transcriber = transcriber
        self.languages = languages
        self.filterToEnrolledSpeaker = filterToEnrolledSpeaker
        let home = FileManager.default.homeDirectoryForCurrentUser
        recoveryDir = home.appendingPathComponent(".whisperino/recovery")
        recoveryFile = recoveryDir.appendingPathComponent("last-raw-transcript.txt")
        try? FileManager.default.createDirectory(at: recoveryDir, withIntermediateDirectories: true)

        // Clear failed-chunk audio from previous sessions so the folder
        // doesn't grow without bound. The text recovery file is only
        // overwritten once this session produces text, so the previous
        // transcript survives until there's something to replace it.
        if let leftovers = try? FileManager.default.contentsOfDirectory(at: recoveryDir, includingPropertiesForKeys: nil) {
            for file in leftovers where file.pathExtension == "wav" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    var chunksSubmitted: Int { submittedCount }

    /// Queue a finished chunk for transcription. Call from the main thread.
    func submit(chunkURL: URL) {
        submittedCount += 1
        let index = submittedCount
        let previous = chain
        chain = Task { [self] in
            await previous?.value
            guard !cancelled else {
                try? FileManager.default.removeItem(at: chunkURL)
                return
            }
            do {
                let text: String
                if filterToEnrolledSpeaker {
                    let analysisTask = Task {
                        await SpeakerProfileManager.shared.analyze(audioURL: chunkURL)
                    }
                    do {
                        let transcript = try await transcriber.transcribeDetailed(
                            audioURL: chunkURL,
                            languages: languages,
                            timestamps: .word
                        )
                        let fullText = Transcriber.cleanOutput(transcript.text)
                        let units: [TimedTranscriptUnit]
                        if !transcript.words.isEmpty {
                            units = transcript.words.map {
                                TimedTranscriptUnit(
                                    startMs: $0.t0Ms,
                                    endMs: $0.t1Ms,
                                    text: $0.text
                                )
                            }
                        } else {
                            units = transcript.segments.map {
                                TimedTranscriptUnit(
                                    startMs: $0.t0Ms,
                                    endMs: $0.t1Ms,
                                    text: $0.text
                                )
                            }
                        }
                        text = SpeakerTranscriptSelector.select(
                            fullText: fullText,
                            units: units,
                            analysis: await analysisTask.value
                        )
                    } catch {
                        // Some ASR families cannot produce word timestamps. The
                        // filter must never turn that capability gap into a lost
                        // dictation, so immediately retry the ordinary path.
                        analysisTask.cancel()
                        print("[whisperino] timestamped transcription unavailable; speaker filter failed open: \(error.localizedDescription)")
                        text = try await transcriber.transcribe(
                            audioURL: chunkURL,
                            languages: languages
                        )
                    }
                } else {
                    text = try await transcriber.transcribe(
                        audioURL: chunkURL,
                        languages: languages
                    )
                }
                try? FileManager.default.removeItem(at: chunkURL)
                doneCount += 1
                if !text.isEmpty {
                    segments.append(text)
                }
                let joined = segments.joined(separator: " ")
                if !joined.isEmpty {
                    try? joined.write(to: recoveryFile, atomically: true, encoding: .utf8)
                }
                let progress = Progress(
                    chunksDone: doneCount,
                    chunksTotal: max(submittedCount, doneCount),
                    text: joined
                )
                await MainActor.run { self.onProgress?(progress) }
            } catch {
                doneCount += 1
                failedCount += 1
                let kept = recoveryDir.appendingPathComponent("failed-chunk-\(index).wav")
                try? FileManager.default.moveItem(at: chunkURL, to: kept)
                print("[whisperino] chunk \(index) failed (\(error.localizedDescription)) - audio kept at \(kept.path)")
            }
        }
    }

    /// Wait for every submitted chunk and return the joined raw
    /// transcript. If some chunks failed but others produced text, the
    /// partial transcript is returned rather than throwing - the failed
    /// audio is preserved in the recovery folder either way.
    func finish() async throws -> String {
        await chain?.value
        let joined = segments.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.isEmpty && failedCount > 0 {
            throw TranscriptionSessionError.allChunksFailed
        }
        return joined
    }

    /// Abandon the session: chunks not yet started are deleted instead
    /// of transcribed. An in-flight whisper run finishes on its own (it
    /// is at most one chunk's worth of work) but its result is ignored
    /// because the owner drops its reference.
    func cancel() {
        cancelled = true
        onProgress = nil
    }
}
