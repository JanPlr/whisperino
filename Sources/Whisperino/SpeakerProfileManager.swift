import Combine
import CryptoKit
import Foundation
import SpeakerFilteringCore

final class SpeakerProfileManager: ObservableObject {
    static let shared = SpeakerProfileManager()

    enum Status: Equatable {
        case idle
        case downloading(String)
        case recording(secondsRemaining: Int)
        case processing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .recording, .processing: return true
            case .idle, .failed: return false
            }
        }
    }

    private struct ModelAsset {
        let displayName: String
        let fileName: String
        let url: URL
        let expectedBytes: Int64
        let sha256: String
    }

    private static let embeddingAsset = ModelAsset(
        displayName: "voice model",
        fileName: "3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx",
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx")!,
        expectedBytes: 29_596_978,
        sha256: "357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b"
    )
    private static let segmentationAsset = ModelAsset(
        displayName: "speaker segmentation model",
        fileName: "pyannote-segmentation-3.0.int8.onnx",
        url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/9403a69/model.int8.onnx?download=true")!,
        expectedBytes: 1_540_506,
        sha256: "d582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d"
    )

    @Published private(set) var status: Status = .idle
    @Published private(set) var isEnrolled = false
    @Published private(set) var enrollmentLevel: Float = 0

    private let home: URL
    private let recorder = AudioRecorder()
    private var countdownTimer: Timer?
    private var enrollmentTask: Task<Void, Never>?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        isEnrolled = profileIsValid
    }

    var isReadyForFiltering: Bool {
        profileIsValid && Self.assets.allSatisfy { assetIsValid($0) }
    }

    func startEnrollment(preferredDeviceUID: String?) {
        guard !status.isBusy else { return }
        enrollmentTask?.cancel()
        enrollmentTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureModels()
                try Task.checkCancellation()
                await MainActor.run { self.beginRecording(preferredDeviceUID: preferredDeviceUID) }
            } catch is CancellationError {
                await MainActor.run { self.status = .idle }
            } catch {
                await MainActor.run { self.status = .failed(error.localizedDescription) }
            }
        }
    }

    func cancelEnrollment() {
        enrollmentTask?.cancel()
        enrollmentTask = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        if let url = recorder.stop() { try? FileManager.default.removeItem(at: url) }
        enrollmentLevel = 0
        status = .idle
    }

    func deleteVoiceData() {
        cancelEnrollment()
        SettingsStore.shared.settings.voiceIsolationEnabled = false
        try? FileManager.default.removeItem(at: profileURL)
        for asset in Self.assets { try? FileManager.default.removeItem(at: modelURL(asset)) }
        isEnrolled = false
    }

    func analyze(audioURL: URL) async -> SpeakerAnalysis? {
        guard isReadyForFiltering else { return nil }
        do {
            return try await runWorker(
                SpeakerAnalysis.self,
                command: "analyze",
                audioURL: audioURL,
                includeProfile: true,
                timeout: 25
            )
        } catch {
            print("[whisperino] speaker analysis failed open: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Enrollment

    private func beginRecording(preferredDeviceUID: String?) {
        status = .recording(secondsRemaining: 18)
        recorder.start(
            preferredDeviceUID: preferredDeviceUID,
            levelCallback: { [weak self] level in
                DispatchQueue.main.async { self?.enrollmentLevel = level }
            },
            recoveredChunkCallback: { url in try? FileManager.default.removeItem(at: url) },
            streamFailureCallback: { [weak self] error in
                DispatchQueue.main.async { self?.finishWithFailure(error.localizedDescription) }
            },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: self.startCountdown()
                case .failure(let error): self.finishWithFailure(error.localizedDescription)
                }
            }
        )
    }

    private func startCountdown() {
        var remaining = 18
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                self.countdownTimer = nil
                self.finishRecording()
            } else {
                self.status = .recording(secondsRemaining: remaining)
            }
        }
    }

    private func finishRecording() {
        guard let audioURL = recorder.stop() else {
            finishWithFailure("The enrollment recording was unavailable")
            return
        }
        enrollmentLevel = 0
        status = .processing
        enrollmentTask = Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: audioURL) }
            do {
                let profile = try await self.runWorker(
                    SpeakerVoiceProfile.self,
                    command: "enroll",
                    audioURL: audioURL,
                    includeProfile: false,
                    timeout: 25
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(profile)
                try FileManager.default.createDirectory(
                    at: self.profileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: self.profileURL, options: .atomic)
                await MainActor.run {
                    self.isEnrolled = true
                    SettingsStore.shared.settings.voiceIsolationEnabled = true
                    self.status = .idle
                }
            } catch {
                await MainActor.run { self.status = .failed(error.localizedDescription) }
            }
        }
    }

    private func finishWithFailure(_ message: String) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        if let url = recorder.stop() { try? FileManager.default.removeItem(at: url) }
        enrollmentLevel = 0
        status = .failed(message)
    }

    // MARK: Models

    private static var assets: [ModelAsset] { [embeddingAsset, segmentationAsset] }

    private var modelsDirectory: URL {
        home.appendingPathComponent(".whisperino/models/speaker-filter-v2", isDirectory: true)
    }

    private var profileURL: URL {
        home.appendingPathComponent(".whisperino/speaker-profile-v2.json")
    }

    private func modelURL(_ asset: ModelAsset) -> URL {
        modelsDirectory.appendingPathComponent(asset.fileName)
    }

    private var profileIsValid: Bool {
        guard let data = try? Data(contentsOf: profileURL) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let profile = try? decoder.decode(SpeakerVoiceProfile.self, from: data) else { return false }
        return profile.version == 2
            && profile.modelFileName == Self.embeddingAsset.fileName
            && profile.embeddings.count >= 3
            && !profile.centroid.isEmpty
    }

    private func assetIsValid(_ asset: ModelAsset) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(
            atPath: modelURL(asset).path
        )[.size]) as? Int64 else { return false }
        return size == asset.expectedBytes
    }

    private func ensureModels() async throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        for asset in Self.assets where !assetIsValid(asset) {
            try Task.checkCancellation()
            await MainActor.run { self.status = .downloading(asset.displayName) }
            let (temporary, response) = try await URLSession.shared.download(from: asset.url)
            guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false else {
                throw URLError(.badServerResponse)
            }
            let data = try Data(contentsOf: temporary)
            guard Int64(data.count) == asset.expectedBytes else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == asset.sha256 else { throw CocoaError(.fileReadCorruptFile) }
            let destination = modelURL(asset)
            let staging = destination.appendingPathExtension("partial")
            try? FileManager.default.removeItem(at: staging)
            try data.write(to: staging, options: .atomic)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: staging, to: destination)
        }
    }

    // MARK: Worker process

    private enum WorkerFailure: LocalizedError {
        case unavailable
        case timedOut
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "The isolated speaker worker is missing"
            case .timedOut: return "Speaker analysis timed out"
            case .failed(let message): return message
            }
        }
    }

    private func runWorker<T: Decodable>(
        _ type: T.Type,
        command: String,
        audioURL: URL,
        includeProfile: Bool,
        timeout: TimeInterval
    ) async throws -> T {
        let workerURL = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("WhisperinoSpeakerWorker")
        guard let workerURL, FileManager.default.isExecutableFile(atPath: workerURL.path) else {
            throw WorkerFailure.unavailable
        }
        let arguments = [
            command,
            "--audio", audioURL.path,
            "--segmentation-model", modelURL(Self.segmentationAsset).path,
            "--embedding-model", modelURL(Self.embeddingAsset).path,
        ] + (includeProfile ? ["--profile", profileURL.path] : [])

        return try await Task.detached(priority: .userInitiated) {
            try Self.runWorkerBlocking(
                type,
                workerURL: workerURL,
                arguments: arguments,
                timeout: timeout
            )
        }.value
    }

    private static func runWorkerBlocking<T: Decodable>(
        _ type: T.Type,
        workerURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> T {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = workerURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            throw WorkerFailure.timedOut
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorkerFailure.failed(message?.isEmpty == false ? message! : "Speaker analysis failed")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}
