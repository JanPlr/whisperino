import Foundation

enum TranscriberError: LocalizedError {
    case notInstalled
    case processFailed(status: Int32)
    case noOutput

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "whisper.cpp not installed. Run setup.sh first."
        case .processFailed(let status):
            return "Whisper process exited with status \(status)"
        case .noOutput:
            return "No transcription output"
        }
    }
}

class Transcriber {
    private let baseDir: URL
    private let whisperBinary: URL
    private let modelPath: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        baseDir = home.appendingPathComponent(".whisper-flow")
        whisperBinary = baseDir.appendingPathComponent("bin/whisper-cli")
        modelPath = baseDir.appendingPathComponent("models/ggml-small.bin")
    }

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: whisperBinary.path) &&
        FileManager.default.fileExists(atPath: modelPath.path)
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard isAvailable else { throw TranscriberError.notInstalled }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = whisperBinary
            process.arguments = [
                "--model", modelPath.path,
                "--file", audioURL.path,
                "--no-timestamps",
                "--print-progress", "false",
                "--print-special", "false",
                "--language", "auto",
                "--threads", "4",
            ]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { _ in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                var output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                // Strip whisper special tokens
                for token in ["[EOT]", "[SOT]", "[BEG]", "[END]", "[BLANK_AUDIO]"] {
                    output = output.replacingOccurrences(of: token, with: "")
                }
                // Also strip bracket tokens like [_TT_123]
                output = output.replacingOccurrences(
                    of: "\\[_[A-Z]+_\\d*\\]",
                    with: "",
                    options: .regularExpression
                )
                output = output.trimmingCharacters(in: .whitespacesAndNewlines)

                // Clean up temp audio file
                try? FileManager.default.removeItem(at: audioURL)

                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: TranscriberError.processFailed(
                        status: process.terminationStatus
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: audioURL)
                continuation.resume(throwing: error)
            }
        }
    }
}
