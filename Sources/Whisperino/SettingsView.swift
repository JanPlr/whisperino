import SwiftUI

struct SettingsView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }
            DictionaryTab()
                .tabItem { Label("Dictionary", systemImage: "text.book.closed") }
            SnippetsTab()
                .tabItem { Label("Snippets", systemImage: "text.quote") }
        }
        .frame(width: 480, height: 380)
        .padding(0)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var showAPIKey = false

    private var hasAPIKey: Bool {
        !store.settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                SectionHeader("Dictation")
                ShortcutRow(keys: "⌥D", label: "Tap to start/stop, hold to push-to-talk")
                ShortcutRow(keys: "⌥⌥", label: "Double-tap Option to start/stop")
            }

            Section {
                SectionHeader("Langdock API Key")
                HStack {
                    if showAPIKey {
                        TextField("Paste your API key", text: $store.settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Paste your API key", text: $store.settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button(showAPIKey ? "Hide" : "Show") {
                        showAPIKey.toggle()
                    }
                    .buttonStyle(.borderless)
                }
                Text("Required for LLM refinement and instruction mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Enable LLM refinement", isOn: $store.settings.llmRefinementEnabled)
                    .disabled(!hasAPIKey)
                Text("Removes filler words, adds punctuation, corrects backtracking, and applies your dictionary terms using Claude Haiku via Langdock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(hasAPIKey ? 1 : 0.5)

            Section {
                SectionHeader("Instruction Mode")
                ShortcutRow(keys: "⇧⌥D", label: "Tap to start/stop, hold to push-to-talk")
                ShortcutRow(keys: "⇧⌥⌥", label: "Hold Shift + double-tap Option to start/stop")
                Text("Speak instructions and the LLM generates a response. Tap the paperclip to attach clipboard content (text or image).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(hasAPIKey && store.settings.llmRefinementEnabled ? 1 : 0.5)
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .onChange(of: store.settings.apiKey) {
            // Auto-disable refinement if API key is cleared
            if !hasAPIKey && store.settings.llmRefinementEnabled {
                store.settings.llmRefinementEnabled = false
            }
        }
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }
}

// MARK: - Shortcut Row

private struct ShortcutRow: View {
    let keys: String
    let label: String

    var body: some View {
        HStack {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 48, alignment: .leading)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Dictionary Tab

private struct DictionaryTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var newTerm = ""
    @State private var selectedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add terms the LLM should always spell correctly. Use \"phonetic = Correct\" format (e.g. \"langdonk = Langdock\") to map what Whisper mishears to the right spelling. Requires LLM refinement to be enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            List(selection: $selectedID) {
                ForEach(store.dictionary) { entry in
                    Text(entry.term)
                        .tag(entry.id)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .onDeleteCommand { deleteSelected() }

            Divider()

            HStack(spacing: 8) {
                Button(action: deleteSelected) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedID == nil)

                Spacer()

                TextField("e.g. Langdock  or  langdonk = Langdock", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addTerm() }

                Button("Add") { addTerm() }
                    .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
    }

    private func addTerm() {
        store.addDictionaryTerm(newTerm)
        newTerm = ""
    }

    private func deleteSelected() {
        guard let id = selectedID,
              let index = store.dictionary.firstIndex(where: { $0.id == id }) else { return }
        store.removeDictionaryTerms(at: [index])
        selectedID = nil
    }
}

// MARK: - Snippets Tab

private struct SnippetsTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var selectedID: UUID?
    @State private var editName = ""
    @State private var editText = ""

    private var selected: Snippet? {
        store.snippets.first { $0.id == selectedID }
    }

    var body: some View {
        HSplitView {
            // Left: list
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(store.snippets) { snippet in
                        Text(snippet.name)
                            .tag(snippet.id)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onDeleteCommand { deleteSelected() }

                Divider()

                HStack {
                    Button(action: addSnippet) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)

                    Button(action: deleteSelected) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedID == nil)

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(minWidth: 160, idealWidth: 180)

            // Right: edit panel
            if let snippet = selected {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Name", text: $editName)
                        .textFieldStyle(.roundedBorder)

                    TextEditor(text: $editText)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )

                    HStack {
                        Spacer()
                        Button("Save") {
                            store.updateSnippet(id: snippet.id, name: editName, text: editText)
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: selectedID) { loadSelected() }
                .onAppear { loadSelected() }
            } else {
                Text("Select a snippet to edit")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func loadSelected() {
        guard let s = selected else { return }
        editName = s.name
        editText = s.text
    }

    private func addSnippet() {
        let name = "New Snippet"
        store.addSnippet(name: name, text: "")
        selectedID = store.snippets.last?.id
        loadSelected()
    }

    private func deleteSelected() {
        guard let id = selectedID,
              let index = store.snippets.firstIndex(where: { $0.id == id }) else { return }
        store.removeSnippets(at: [index])
        selectedID = nil
    }
}
