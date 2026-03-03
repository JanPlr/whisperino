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

    var body: some View {
        Form {
            Section {
                Toggle("Enable LLM refinement", isOn: $store.settings.llmRefinementEnabled)
                Text("Removes filler words, adds punctuation, corrects backtracking, and applies your dictionary terms using Claude Haiku via Langdock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Langdock API Key") {
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
                if store.settings.llmRefinementEnabled && store.settings.apiKey.isEmpty {
                    Label("Enter an API key to enable refinement", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

// MARK: - Dictionary Tab

private struct DictionaryTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var newTerm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add terms the LLM should always spell correctly. Use \"phonetic = Correct\" format (e.g. \"langdonk = Langdock\") to map what Whisper mishears to the right spelling. Requires LLM refinement to be enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            List {
                ForEach(store.dictionary) { entry in
                    Text(entry.term)
                }
                .onDelete { store.removeDictionaryTerms(at: $0) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Divider()

            HStack(spacing: 8) {
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
                List(store.snippets, selection: $selectedID) { snippet in
                    Text(snippet.name)
                        .tag(snippet.id)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))

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
