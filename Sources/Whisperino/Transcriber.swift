import Foundation
import TranscribeCpp

enum TranscriberError: LocalizedError {
    case notInstalled
    case engineUnavailable(String)
    case noOutput

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Speech model is still downloading. Open Settings if it does not start."
        case .engineUnavailable(let message):
            return "Speech engine failed: \(message)"
        case .noOutput:
            return "No transcription output"
        }
    }
}

extension TranscribeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let message),
             .notImplemented(let message),
             .modelFileNotFound(let message),
             .modelLoad(let message),
             .outOfMemory(let message),
             .backend(let message),
             .unsupported(let message),
             .badStructSize(let message),
             .inputTooLong(let message),
             .versionMismatch(let message),
             .busy(let message),
             .other(_, let message):
            return message
        case .aborted(let message, _),
             .outputTruncated(let message, _):
            return message
        }
    }
}

/// In-process transcribe.cpp backend. The selected GGUF stays resident on
/// Metal so the first take does not pay a disk-load, and Nemotron streams
/// PCM as it arrives instead of waiting for a finished WAV.
final class Transcriber {
    private let downloader: ModelDownloader
    private let engineQueue = DispatchQueue(label: "com.whisperino.asr", qos: .userInitiated)
    private let lock = NSLock()

    private var model: Model?
    private var session: Session?
    private var stream: TranscribeCpp.Stream?
    private var loadedModelID: ASRModelID?
    private var loadedPath: String?
    private var loadTask: Task<Void, Error>?
    private var pcmBuffer: [Float] = []
    /// Samples that arrived on the audio thread before the engine drained them.
    private var pendingPCM: [Float] = []
    /// Feed at least ~80 ms so Nemotron is not woken per 10 ms tap.
    private let minFeedSamples = 1_280
    private var onPartial: ((String) -> Void)?
    private var lastPreview = ""
    private var streamRunOptions = RunOptions()
    /// Nemotron 3.5's cache-aware stream is trained on 1120 ms chunks with
    /// up to 1040 ms of right context. R=13 is the setting that matches the
    /// offline transcript; lower R commits earlier and drops the tail.
    private var streamOptions = StreamOptions(
        family: .parakeetStream(ParakeetStreamOptions(attContextRight: 13))
    )
    /// Chunk (1120 ms) + right context (1040 ms) of silence so the last
    /// words have the future audio Nemotron needs before it will emit them.
    private let finalizePadSamples = 36_000
    /// Bumped at the start of each take so a late `startStream` cannot reopen
    /// a stream that `finishStream` already finalized.
    private var takeGeneration: UInt64 = 0
    private var streamClosed = false

    init(downloader: ModelDownloader = .shared) {
        self.downloader = downloader
        Transcribe.setLogHandler { level, message in
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if level == .error || level == .warn {
                print("[transcribe.cpp] \(trimmed)")
            }
        }
    }

    var selectedModel: ASRModelID {
        SettingsStore.shared.settings.asrModel
    }

    var selectedDescriptor: ASRModelDescriptor {
        ASRModelCatalog.descriptor(for: selectedModel)
    }

    var isAvailable: Bool {
        downloader.isInstalled(selectedModel)
    }

    var supportsStreaming: Bool {
        selectedDescriptor.supportsStreaming
    }

    // MARK: - Lifecycle

    /// Download the selected model if needed, then load it onto Metal.
    func warmUp() {
        downloader.ensureSelected { [weak self] in
            self?.requestLoad()
        }
    }

    /// Drop the resident model (and any open stream) before process exit.
    func shutdown() {
        lock.lock()
        stream = nil
        session = nil
        model = nil
        loadedModelID = nil
        loadedPath = nil
        loadTask = nil
        streamClosed = true
        pcmBuffer.removeAll()
        pendingPCM.removeAll()
        lock.unlock()
    }

    /// Reload after the user picks a different model.
    func select(_ id: ASRModelID) {
        if SettingsStore.shared.settings.asrModel != id {
            SettingsStore.shared.settings.asrModel = id
        }
        downloader.ensure(id) { [weak self] in
            self?.requestLoad(force: true)
        }
    }

    private func requestLoad(force: Bool = false) {
        lock.lock()
        if !force, loadTask != nil {
            lock.unlock()
            return
        }
        loadTask = Task { [weak self] in
            try await self?.loadEngine()
        }
        lock.unlock()
    }

    private func loadEngine() async throws {
        let id = selectedModel
        guard downloader.isInstalled(id) else {
            throw TranscriberError.notInstalled
        }
        let path = downloader.localURL(for: id).path
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            engineQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: TranscriberError.engineUnavailable("transcriber gone"))
                    return
                }
                if self.loadedPath == path, self.model != nil, self.session != nil {
                    continuation.resume()
                    return
                }
                self.stream = nil
                self.session = nil
                self.model = nil
                self.loadedModelID = nil
                self.loadedPath = nil
                do {
                    try Transcribe.initBackends()
                    let backend: Backend = Transcribe.backendAvailable(.metal) ? .metal : .auto
                    print("[whisperino] loading \(ASRModelCatalog.descriptor(for: id).fileName) on \(backend == .metal ? "Metal" : "auto")")
                    let loaded = try Model(path: path, options: ModelOptions(backend: backend))
                    let newSession = try loaded.session()
                    print("[whisperino] \(id.rawValue) ready (\(loaded.arch) \(loaded.variant), backend \(loaded.backend))")
                    self.model = loaded
                    self.session = newSession
                    self.loadedModelID = id
                    self.loadedPath = path
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func ensureEngine() async throws {
        if isAvailable == false { throw TranscriberError.notInstalled }
        let wanted = selectedModel
        let alreadyLoaded = withLock {
            model != nil && session != nil && loadedModelID == wanted
        }
        if alreadyLoaded { return }
        // A load started for a previous model must not satisfy this call.
        if let task = withLock({ loadTask }) {
            try? await task.value
        }
        let matches = withLock {
            model != nil && session != nil && loadedModelID == wanted
        }
        if matches { return }
        try await loadEngine()
        let ready = withLock {
            model != nil && session != nil && loadedModelID == selectedModel
        }
        if !ready { throw TranscriberError.engineUnavailable("model failed to load") }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Offline transcription

    func transcribe(audioURL: URL, languages: [String] = []) async throws -> String {
        try await ensureEngine()
        let pcm = try AudioPCM.loadMono16k(from: audioURL)
        guard !pcm.isEmpty else { return "" }
        let options = runOptions(languages: languages)
        let transcript: Transcript = try await withCheckedThrowingContinuation { continuation in
            engineQueue.async { [weak self] in
                guard let self, let session = self.session else {
                    continuation.resume(throwing: TranscriberError.engineUnavailable("session gone"))
                    return
                }
                do {
                    if self.stream != nil {
                        _ = self.stream?.reset()
                        self.stream = nil
                    }
                    continuation.resume(returning: try session.run(pcm, options: options))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return Self.cleanOutput(transcript.text)
    }

    // MARK: - Streaming (Nemotron)

    /// Call before the mic tap starts so leftover stream state from the
    /// previous take cannot collide with this one.
    func prepareTake() {
        withLock {
            takeGeneration &+= 1
            streamClosed = false
            pendingPCM.removeAll(keepingCapacity: true)
        }
        engineQueue.async { [weak self] in
            guard let self else { return }
            _ = self.stream?.reset()
            self.stream = nil
            self.onPartial = nil
            self.lastPreview = ""
            self.pcmBuffer.removeAll(keepingCapacity: true)
        }
    }

    func startStream(
        languages: [String] = [],
        onPartial: ((String) -> Void)? = nil
    ) async throws {
        try await ensureEngine()
        let options = runOptions(languages: languages)
        let generation = withLock { takeGeneration }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            engineQueue.async { [weak self] in
                guard let self, let session = self.session else {
                    continuation.resume(throwing: TranscriberError.engineUnavailable("session gone"))
                    return
                }
                do {
                    let stale = self.withLock {
                        self.streamClosed || self.takeGeneration != generation
                    }
                    if stale {
                        continuation.resume()
                        return
                    }
                    self.streamRunOptions = options
                    self.onPartial = onPartial
                    self.lastPreview = ""
                    if self.stream == nil {
                        self.stream = try session.stream(options, self.streamOptions)
                    }
                    self.drainPendingPCM()
                    self.flushPCMIfNeeded(force: false)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Append 16 kHz mono PCM. The samples are stored immediately so a
    /// fast key-release cannot lose the last tap while `finishStream` runs.
    func feedPCM(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        withLock {
            pendingPCM.append(contentsOf: samples)
        }
        engineQueue.async { [weak self] in
            guard let self, !self.withLock({ self.streamClosed }) else { return }
            self.drainPendingPCM()
            self.flushPCMIfNeeded(force: false)
        }
    }

    private func drainPendingPCM() {
        let incoming = withLock { () -> [Float] in
            let copy = pendingPCM
            pendingPCM.removeAll(keepingCapacity: true)
            return copy
        }
        if !incoming.isEmpty {
            pcmBuffer.append(contentsOf: incoming)
        }
    }

    private func flushPCMIfNeeded(force: Bool) {
        drainPendingPCM()
        guard let stream else { return }
        guard force || pcmBuffer.count >= minFeedSamples else { return }
        let chunk = pcmBuffer
        pcmBuffer.removeAll(keepingCapacity: true)
        guard !chunk.isEmpty else { return }
        do {
            let update = try stream.feed(chunk)
            if update.committedChanged || update.tentativeChanged || update.resultChanged {
                publishPreview(Self.authoritativeText(stream.text))
            }
        } catch {
            print("[whisperino] stream feed failed: \(error.localizedDescription)")
        }
    }

    private func publishPreview(_ raw: String) {
        let text = Self.cleanOutput(raw)
        guard text != lastPreview else { return }
        lastPreview = text
        onPartial?(text)
    }

    func finishStream() async throws -> String {
        try await ensureEngine()
        return try await withCheckedThrowingContinuation { continuation in
            engineQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: TranscriberError.engineUnavailable("transcriber gone"))
                    return
                }
                self.withLock { self.streamClosed = true }
                do {
                    self.drainPendingPCM()
                    if self.stream == nil, let session = self.session, !self.pcmBuffer.isEmpty {
                        self.stream = try session.stream(self.streamRunOptions, self.streamOptions)
                    }
                    guard let stream = self.stream else {
                        continuation.resume(returning: "")
                        return
                    }
                    self.flushPCMIfNeeded(force: true)
                    // The last 1–2 s sit in the encoder's right-context
                    // window until they have future audio. Key-up has none,
                    // so pad a full chunk of silence and then finalize.
                    let pad = [Float](repeating: 0, count: self.finalizePadSamples)
                    _ = try stream.feed(pad)
                    _ = try stream.finalize()
                    let text = Self.authoritativeText(stream.text)
                    self.stream = nil
                    self.onPartial = nil
                    continuation.resume(returning: text)
                } catch {
                    let partial = Self.authoritativeText(self.stream?.text)
                    _ = self.stream?.reset()
                    self.stream = nil
                    self.onPartial = nil
                    if !partial.isEmpty {
                        continuation.resume(returning: partial)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Drain the live stream through its lookahead window and use that text.
    /// The WAV is only a last resort if the stream never produced anything.
    func finishTake(audioURL: URL, languages: [String] = []) async throws -> String {
        do {
            let streamed = try await finishStream()
            if !streamed.isEmpty { return streamed }
            print("[whisperino] stream empty after finalize - offline fallback")
        } catch {
            print("[whisperino] stream finalize failed (\(error.localizedDescription)) - offline fallback")
        }
        return try await transcribe(audioURL: audioURL, languages: languages)
    }

    func cancelStream() {
        withLock {
            streamClosed = true
            pendingPCM.removeAll()
        }
        engineQueue.async { [weak self] in
            _ = self?.stream?.reset()
            self?.stream = nil
            self?.onPartial = nil
            self?.lastPreview = ""
            self?.pcmBuffer.removeAll()
        }
    }

    // MARK: - Options

    private func runOptions(languages: [String]) -> RunOptions {
        let id = selectedModel
        let mapped = ASRModelCatalog.recognitionLanguage(for: id, selectedCodes: languages)
        let family: RunExtension?
        if ASRModelCatalog.descriptor(for: id).family == .whisper {
            family = .whisper(WhisperRunOptions(
                initialPrompt: mapped.prompt,
                temperature: 0
            ))
        } else {
            family = nil
        }
        let language = mapped.language.flatMap { $0 == "auto" ? nil : $0 }
        return RunOptions(
            timestamps: .none,
            language: language,
            family: family
        )
    }

    /// `full` is the raw hypothesis. `display` (committed + tentative) can
    /// lag by a whole encoder chunk after the model revises the tail.
    static func authoritativeText(_ text: StreamText?) -> String {
        guard let text else { return "" }
        let full = cleanOutput(text.full)
        let display = cleanOutput(text.display)
        return full.count >= display.count ? full : display
    }

    static func cleanOutput(_ raw: String) -> String {
        var output = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in ["[EOT]", "[SOT]", "[BEG]", "[END]", "[BLANK_AUDIO]"] {
            output = output.replacingOccurrences(of: token, with: "")
        }
        output = output.replacingOccurrences(
            of: "\\[_[A-Z]+_\\d*\\]",
            with: "",
            options: .regularExpression
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
