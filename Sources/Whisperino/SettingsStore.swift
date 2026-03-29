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

    static let maxHistoryEntries = 50

    @Published var settings: AppSettings {
        didSet {
            save(settings, to: settingsFile)
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

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

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

    func addTranscript(_ text: String, isInstruction: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.insert(TranscriptEntry(text: trimmed, isInstruction: isInstruction), at: 0)
        if history.count > Self.maxHistoryEntries {
            history = Array(history.prefix(Self.maxHistoryEntries))
        }
    }

    func clearHistory() {
        history.removeAll()
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
