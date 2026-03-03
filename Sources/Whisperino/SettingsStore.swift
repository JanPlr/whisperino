import Foundation
import Combine

class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let baseDir: URL
    private let settingsFile: URL
    private let dictionaryFile: URL
    private let snippetsFile: URL

    @Published var settings: AppSettings {
        didSet { save(settings, to: settingsFile) }
    }
    @Published var dictionary: [DictionaryEntry] {
        didSet { save(dictionary, to: dictionaryFile) }
    }
    @Published var snippets: [Snippet] {
        didSet { save(snippets, to: snippetsFile) }
    }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        baseDir = home.appendingPathComponent(".whisperino")
        settingsFile = baseDir.appendingPathComponent("settings.json")
        dictionaryFile = baseDir.appendingPathComponent("dictionary.json")
        snippetsFile = baseDir.appendingPathComponent("snippets.json")

        // Ensure directory exists with owner-only permissions (rwx------)
        try? FileManager.default.createDirectory(
            at: baseDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Load or use defaults
        settings = Self.load(from: settingsFile) ?? AppSettings()
        dictionary = Self.load(from: dictionaryFile) ?? []
        snippets = Self.load(from: snippetsFile) ?? []

        // Migrate: move API key from plaintext JSON to Keychain
        migrateAPIKeyToKeychain()
    }

    /// One-time migration: if settings.json still contains a plaintext "apiKey",
    /// move it to the Keychain and strip it from the file.
    private func migrateAPIKeyToKeychain() {
        guard let data = try? Data(contentsOf: settingsFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plaintextKey = json["apiKey"] as? String,
              !plaintextKey.isEmpty else { return }

        // Save to Keychain
        settings.apiKey = plaintextKey

        // Re-save settings (now without apiKey since it's excluded from CodingKeys)
        save(settings, to: settingsFile)
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
        // Write atomically with owner-only read/write permissions (rw-------)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
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
}
