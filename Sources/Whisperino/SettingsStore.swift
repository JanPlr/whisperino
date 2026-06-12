import Foundation
import Combine

class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let baseDir: URL
    private let settingsFile: URL
    private let dictionaryFile: URL
    private let snippetsFile: URL
    private let agentsFile: URL
    private let historyFile: URL
    /// Where in-flight recordings live. A recording stays here until its
    /// transcript is safely in history (or it's pruned with its entry) —
    /// so failures, cancels, and crashes are always recoverable.
    let recordingsDir: URL

    static let maxHistoryEntries = 50

    @Published var settings: AppSettings {
        didSet {
            save(settings, to: settingsFile)
            // Trigger swap mid-session leaves the hotkey state machine
            // referencing the old key — clear it so the next press starts fresh.
            if settings.triggerKey != oldValue.triggerKey {
                HotkeyManager.shared.resetTriggerState()
            }
        }
    }
    @Published var dictionary: [DictionaryEntry] {
        didSet { save(dictionary, to: dictionaryFile) }
    }
    @Published var snippets: [Snippet] {
        didSet { save(snippets, to: snippetsFile) }
    }
    @Published var agents: [AgentEntry] {
        didSet { save(agents, to: agentsFile) }
    }
    @Published var history: [TranscriptEntry] {
        didSet { save(history, to: historyFile) }
    }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        baseDir = home.appendingPathComponent(".whisperino")
        settingsFile = baseDir.appendingPathComponent("settings.json")
        dictionaryFile = baseDir.appendingPathComponent("dictionary.json")
        snippetsFile = baseDir.appendingPathComponent("snippets.json")
        agentsFile = baseDir.appendingPathComponent("agents.json")
        historyFile = baseDir.appendingPathComponent("history.json")
        recordingsDir = baseDir.appendingPathComponent("recordings")

        // Ensure directories exist
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        // Load or use defaults
        settings = Self.load(from: settingsFile) ?? AppSettings()
        dictionary = Self.load(from: dictionaryFile) ?? []
        snippets = Self.load(from: snippetsFile) ?? []
        agents = Self.load(from: agentsFile) ?? []
        history = Self.load(from: historyFile) ?? []
    }

    // MARK: - Persistence

    private static func load<T: Decodable>(from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Dictionary

    func addDictionaryTerm(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !dictionary.contains(where: { $0.term.lowercased() == trimmed.lowercased() }) else { return }
        dictionary.append(DictionaryEntry(term: trimmed))
    }

    func removeDictionaryTerms(at offsets: IndexSet) {
        dictionary.remove(atOffsets: offsets)
    }

    func updateDictionaryTerm(id: UUID, term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = dictionary.firstIndex(where: { $0.id == id }) else { return }
        dictionary[index].term = trimmed
    }

    // MARK: - Snippets

    func addSnippet(name: String, text: String) {
        snippets.append(Snippet(name: name, text: text))
    }

    func removeSnippets(at offsets: IndexSet) {
        snippets.remove(atOffsets: offsets)
    }

    func updateSnippet(id: UUID, name: String, text: String) {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[index].name = name
        snippets[index].text = text
    }

    // MARK: - History

    func addTranscript(_ text: String, isInstruction: Bool = false, rawText: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.insert(TranscriptEntry(text: trimmed, isInstruction: isInstruction, rawText: rawText), at: 0)
        pruneHistory()
    }

    /// Add an entry for a recording that produced no transcript (failure,
    /// cancel, crash). The audio file is retained and referenced so the
    /// History tab can offer a Retry.
    func addRecoverableTranscript(audioURL: URL, reason: String, createdAt: Date = Date()) {
        history.insert(TranscriptEntry(text: "", createdAt: createdAt,
                                       audioFilename: audioURL.lastPathComponent,
                                       failureReason: reason), at: 0)
        pruneHistory()
    }

    /// A retry succeeded — fill in the text and release the audio file.
    func resolveTranscript(id: UUID, text: String, rawText: String?) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        deleteAudio(for: history[index])
        history[index].text = text
        history[index].rawText = rawText
        history[index].audioFilename = nil
        history[index].failureReason = nil
    }

    func setFailureReason(id: UUID, reason: String) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].failureReason = reason
    }

    func clearHistory() {
        for entry in history { deleteAudio(for: entry) }
        history.removeAll()
    }

    private func pruneHistory() {
        while history.count > Self.maxHistoryEntries {
            deleteAudio(for: history.removeLast())
        }
    }

    private func deleteAudio(for entry: TranscriptEntry) {
        guard let filename = entry.audioFilename else { return }
        try? FileManager.default.removeItem(at: recordingsDir.appendingPathComponent(filename))
    }

    /// Called once at launch: any recording on disk that no history entry
    /// references was orphaned by a crash or force-quit mid-dictation.
    /// Surface it as a recoverable entry instead of silently losing it.
    /// Must run before the first recording starts, or the in-flight file
    /// would be misread as an orphan.
    func recoverOrphanedRecordings() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: recordingsDir,
                                                      includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]) else { return }
        let referenced = Set(history.compactMap { $0.audioFilename })
        for url in files where url.pathExtension == "wav" && !referenced.contains(url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            // Sub-second stubs aren't worth recovering (matches the 0.5s
            // minimum-duration gate on live recordings).
            guard (values?.fileSize ?? 0) >= 100_000 else {
                try? fm.removeItem(at: url)
                continue
            }
            addRecoverableTranscript(audioURL: url,
                                     reason: "Recovered after quit — tap Retry",
                                     createdAt: values?.creationDate ?? Date())
        }
    }

    // MARK: - Agents

    func addAgent(name: String, agentId: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedId = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedId.isEmpty else { return }
        agents.append(AgentEntry(name: trimmedName, agentId: trimmedId))
    }

    func removeAgents(at offsets: IndexSet) {
        agents.remove(atOffsets: offsets)
    }

    func updateAgent(id: UUID, name: String, agentId: String) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        agents[index].agentId = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
