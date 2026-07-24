import Foundation

/// Thread-safe-by-convention buffer for piping stdout/stderr off the
/// process's drain queues into the termination handler. The DispatchGroup
/// around the reads establishes the happens-before ordering, so the
/// `@unchecked Sendable` is sound; it just spares us a captured-`var` data
/// race the strict-concurrency checker (correctly) can't prove safe.
private final class PipeBuffers: @unchecked Sendable {
    var out = Data()
    var err = Data()
}

enum TranscriberError: LocalizedError {
    case notInstalled
    case processFailed(status: Int32)
    case noOutput
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "whisper.cpp not installed. Run setup.sh first."
        case .processFailed(let status):
            return "Whisper process exited with status \(status)"
        case .noOutput:
            return "No transcription output"
        case .serverError(let message):
            return "Whisper server error: \(message)"
        }
    }
}

/// Transcription backend. Prefers a persistent `whisper-server` child
/// process - the model loads into memory once at warm-up instead of
/// being re-read from disk (~1.6GB) on every single take,
/// which is where almost all of the old per-transcription latency came
/// from. Every request falls back to a one-shot `whisper-cli` run if
/// the server is missing or misbehaving, so transcription keeps working
/// even when the server binary isn't installed yet.
class Transcriber {
    private let baseDir: URL
    private let whisperBinary: URL
    private let serverBinary: URL
    private let modelPath: URL

    /// Fixed local port for the persistent server. If it's taken the
    /// server fails to bind, warm-up reports failure, and we fall back
    /// to the CLI path - slower but functional.
    private static let serverPort = 52731

    private var serverProcess: Process?
    /// Single in-flight warm-up shared by all callers. Created on first
    /// demand; resolves true once the server answers HTTP.
    private var warmUpTask: Task<Bool, Never>?
    private let lock = NSLock()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        baseDir = home.appendingPathComponent(".whisperino")
        whisperBinary = baseDir.appendingPathComponent("bin/whisper-cli")
        serverBinary = baseDir.appendingPathComponent("bin/whisper-server")
        // Prefer large-v3-turbo (better accuracy at roughly medium's size);
        // fall back to an already-downloaded medium so existing installs
        // keep working without a re-download. When neither exists yet,
        // point at turbo - that's what setup.sh downloads now.
        let models = baseDir.appendingPathComponent("models")
        let turbo = models.appendingPathComponent("ggml-large-v3-turbo.bin")
        let medium = models.appendingPathComponent("ggml-medium.bin")
        if !FileManager.default.fileExists(atPath: turbo.path),
           FileManager.default.fileExists(atPath: medium.path) {
            modelPath = medium
        } else {
            modelPath = turbo
        }
    }

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: whisperBinary.path) &&
        FileManager.default.fileExists(atPath: modelPath.path)
    }

    private var threads: Int {
        min(8, max(4, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    // MARK: - Lifecycle

    /// Kick off the server in the background so the model is resident
    /// before the first dictation. Call once at app launch.
    func warmUp() {
        Task.detached(priority: .utility) { [weak self] in
            _ = await self?.ensureServer()
        }
    }

    /// Terminate the child server. Call from applicationWillTerminate.
    /// (Orphans from a crashed run are reaped by the pkill in
    /// `startServer` on next launch.)
    func shutdown() {
        serverProcess?.terminate()
        serverProcess = nil
    }

    // MARK: - Transcription

    /// Transcribe one audio file. The caller owns the file - it is never
    /// deleted here, so a failed run can't destroy the user's audio.
    func transcribe(audioURL: URL) async throws -> String {
        guard isAvailable else { throw TranscriberError.notInstalled }

        if await ensureServer() {
            do {
                return try await transcribeViaServer(audioURL: audioURL)
            } catch {
                print("[whisperino] server transcription failed (\(error.localizedDescription)) - falling back to whisper-cli")
            }
        }
        return try await transcribeViaCLI(audioURL: audioURL)
    }

    // MARK: - Server path

    private func ensureServer() async -> Bool {
        lock.lock()
        let task: Task<Bool, Never>
        if let existing = warmUpTask {
            task = existing
        } else {
            let newTask = Task { [weak self] in
                await self?.startServer() ?? false
            }
            warmUpTask = newTask
            task = newTask
        }
        lock.unlock()
        return await task.value
    }

    private func startServer() async -> Bool {
        guard FileManager.default.fileExists(atPath: serverBinary.path),
              FileManager.default.fileExists(atPath: modelPath.path) else {
            print("[whisperino] whisper-server not installed - using whisper-cli per take (run setup.sh to speed this up)")
            return false
        }

        // Reap any orphaned server from a crashed previous run before
        // binding the port ourselves.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "\\.whisperino/bin/whisper-server"]
        try? pkill.run()
        pkill.waitUntilExit()

        let process = Process()
        process.executableURL = serverBinary
        process.arguments = [
            "--model", modelPath.path,
            "--host", "127.0.0.1",
            "--port", String(Self.serverPort),
            "--threads", String(threads),
            "--language", "auto",
            // Greedy decoding - dictation doesn't need a 5-way beam
            // search, and this cuts decode time by a large factor.
            "--beam-size", "1",
            "--best-of", "1",
            "--no-timestamps",
        ]
        // Silence the server's logging.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            print("[whisperino] failed to launch whisper-server: \(error)")
            return false
        }
        serverProcess = process

        // Poll until the HTTP endpoint answers - covers the model load.
        let deadline = Date().addingTimeInterval(60)
        var probe = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.serverPort)/")!)
        probe.timeoutInterval = 1
        while Date() < deadline {
            if !process.isRunning {
                print("[whisperino] whisper-server exited during startup (port \(Self.serverPort) taken?)")
                serverProcess = nil
                return false
            }
            if let (_, response) = try? await URLSession.shared.data(for: probe),
               response is HTTPURLResponse {
                print("[whisperino] whisper-server warm on port \(Self.serverPort)")
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        print("[whisperino] whisper-server never became ready - using whisper-cli")
        process.terminate()
        serverProcess = nil
        return false
    }

    private func transcribeViaServer(audioURL: URL) async throws -> String {
        let audioData = try Data(contentsOf: audioURL)

        let boundary = "whisperino-\(UUID().uuidString)"
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        appendField("response_format", "text")
        appendField("temperature", "0.0")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.serverPort)/inference")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "status \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            throw TranscriberError.serverError(String(detail.prefix(200)))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw TranscriberError.noOutput
        }
        return Self.cleanOutput(text)
    }

    // MARK: - CLI fallback path

    private func transcribeViaCLI(audioURL: URL) async throws -> String {
        let threads = self.threads
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
                "--threads", String(threads),
                // Greedy decoding - same speed rationale as the server.
                "--beam-size", "1",
                "--best-of", "1",
            ]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            // Drain both pipes concurrently while the process runs. Reading
            // only after termination deadlocks on long recordings: once the
            // transcript exceeds the 64KB pipe buffer, whisper blocks on
            // write and never exits, so the termination handler never fires.
            let buffers = PipeBuffers()
            let drainGroup = DispatchGroup()
            drainGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                buffers.out = stdout.fileHandleForReading.readDataToEndOfFile()
                drainGroup.leave()
            }
            drainGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                buffers.err = stderr.fileHandleForReading.readDataToEndOfFile()
                drainGroup.leave()
            }

            process.terminationHandler = { _ in
                // Pipes hit EOF when the process exits, so this returns fast.
                drainGroup.wait()
                let output = Self.cleanOutput(
                    String(data: buffers.out, encoding: .utf8) ?? ""
                )

                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    if let err = String(data: buffers.err, encoding: .utf8), !err.isEmpty {
                        print("[whisperino] whisper-cli stderr: \(err.suffix(500))")
                    }
                    continuation.resume(throwing: TranscriberError.processFailed(
                        status: process.terminationStatus
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Strip whisper special tokens and trim whitespace.
    private static func cleanOutput(_ raw: String) -> String {
        var output = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in ["[EOT]", "[SOT]", "[BEG]", "[END]", "[BLANK_AUDIO]"] {
            output = output.replacingOccurrences(of: token, with: "")
        }
        // Also strip bracket tokens like [_TT_123]
        output = output.replacingOccurrences(
            of: "\\[_[A-Z]+_\\d*\\]",
            with: "",
            options: .regularExpression
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
