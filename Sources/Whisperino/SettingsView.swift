import ServiceManagement
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
            HistoryTab()
                .tabItem { Label("History", systemImage: "clock") }
            AgentsTab()
                .tabItem { Label("Agents", systemImage: "cpu") }
        }
        .frame(width: 480, height: 380)
        .padding(0)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var showAPIKey = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var hasAPIKey: Bool {
        !store.settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let trigger = store.settings.triggerKey
        let triggerLabel = trigger.shortLabel

        Form {
            // MARK: App preferences
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {}
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                ))
                Toggle("Sound effects on start / stop", isOn: $store.settings.soundEffectsEnabled)
            }

            // MARK: Trigger key — let users pick an alternative if Fn is
            // mapped to something else (emoji picker, system function, etc.)
            Section {
                SectionHeader("Trigger key")
                Picker("Press to dictate", selection: $store.settings.triggerKey) {
                    ForEach(TriggerKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                Text("The key you hold to start recording. Right-side modifiers are usually free since most shortcuts use the left side.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: Shortcuts — core usage, plain language, TL;DR
            Section {
                SectionHeader("Shortcuts")
                ShortcutRow(keys: "hold \(triggerLabel)", label: "Dictate (release to send)")
                ShortcutRow(keys: "\(triggerLabel) \(triggerLabel)", label: "Hands-free dictation (tap to stop)")
                ShortcutRow(keys: "\(triggerLabel) + ⇧", label: "AI mode — hold both, LLM responds")
                ShortcutRow(keys: "tap \(triggerLabel)", label: "Submit (in AI / hands-free mode)")
                ShortcutRow(keys: "↩", label: "Submit any recording")
                ShortcutRow(keys: "esc", label: "Cancel")
            }

            // MARK: Langdock API — gates AI features, so positioned before
            // the AI explainer
            Section {
                SectionHeader("Langdock API")
                HStack {
                    if showAPIKey {
                        TextField("Paste API key", text: $store.settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Paste API key", text: $store.settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button(showAPIKey ? "Hide" : "Show") { showAPIKey.toggle() }
                        .buttonStyle(.borderless)
                }

                Toggle("Clean up dictations with Claude Haiku", isOn: $store.settings.llmRefinementEnabled)
                    .disabled(!hasAPIKey)
                Text("Removes filler words, adds punctuation, applies your dictionary, handles self-corrections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: AI mode explainer — informational, last
            Section {
                SectionHeader("How AI mode works")
                Text("Hold **\(triggerLabel) + Shift** (or add Shift while already dictating) → speak → **Cmd+C** any text or image to attach as context → tap **\(triggerLabel)** or press **Return** to submit. Claude generates a response and pastes it inline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                .frame(width: 64, alignment: .leading)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Dictionary Tab

private struct DictionaryTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var termField = ""
    @State private var selectedID: UUID?

    private var isEditing: Bool { selectedID != nil }

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
            .onChange(of: selectedID) { loadSelected() }

            Divider()

            HStack(spacing: 8) {
                Button(action: deleteSelected) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedID == nil)

                Spacer()

                TextField("e.g. Langdock  or  langdonk = Langdock", text: $termField)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { isEditing ? saveSelected() : addTerm() }

                if isEditing {
                    Button("Save") { saveSelected() }
                        .disabled(termField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") {
                        selectedID = nil
                        termField = ""
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button("Add") { addTerm() }
                        .disabled(termField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
        }
    }

    private func loadSelected() {
        guard let id = selectedID,
              let entry = store.dictionary.first(where: { $0.id == id }) else {
            termField = ""
            return
        }
        termField = entry.term
    }

    private func addTerm() {
        store.addDictionaryTerm(termField)
        termField = ""
    }

    private func saveSelected() {
        guard let id = selectedID else { return }
        store.updateDictionaryTerm(id: id, term: termField)
        selectedID = nil
        termField = ""
    }

    private func deleteSelected() {
        guard let id = selectedID,
              let index = store.dictionary.firstIndex(where: { $0.id == id }) else { return }
        store.removeDictionaryTerms(at: [index])
        selectedID = nil
        termField = ""
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
                            selectedID = nil
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
                .padding(16)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: selectedID) { loadSelected() }
                .onAppear { loadSelected() }
            } else {
                Text("Select a snippet to edit")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - History Tab

private struct HistoryTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var selectedID: UUID?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            if store.history.isEmpty {
                Spacer()
                Text("No transcriptions yet")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(selection: $selectedID) {
                    ForEach(store.history) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                if entry.isInstruction {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.purple)
                                }
                                Text(Self.timeFormatter.string(from: entry.createdAt))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.text)
                                .font(.system(size: 12))
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                        .padding(.vertical, 2)
                        .tag(entry.id)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Divider()

            HStack(spacing: 8) {
                Button("Copy") {
                    if let id = selectedID,
                       let entry = store.history.first(where: { $0.id == id }) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                    }
                }
                .disabled(selectedID == nil)

                Spacer()

                Button("Clear All") {
                    store.clearHistory()
                    selectedID = nil
                }
                .disabled(store.history.isEmpty)
            }
            .padding(12)
        }
    }
}

// MARK: - Agents Tab

private struct AgentsTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var nameField = ""
    @State private var agentIdField = ""
    @State private var selectedID: UUID?

    private var isEditing: Bool { selectedID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Langdock agents you want to use via voice. Say the agent\u{2019}s name during instruction mode to route your request to that agent instead of Claude.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            List(selection: $selectedID) {
                ForEach(store.agents) { agent in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name)
                            .font(.system(size: 13, weight: .medium))
                        Text(agent.agentId)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .tag(agent.id)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .onDeleteCommand { deleteSelected() }
            .onChange(of: selectedID) { loadSelected() }

            Divider()

            HStack(spacing: 8) {
                Button(action: deleteSelected) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedID == nil)

                Spacer()

                TextField("Agent name", text: $nameField)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)

                TextField("Agent ID", text: $agentIdField)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)

                if isEditing {
                    Button("Save") { saveSelected() }
                        .disabled(nameField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || agentIdField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") {
                        selectedID = nil
                        nameField = ""
                        agentIdField = ""
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button("Add") { addAgent() }
                        .disabled(nameField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || agentIdField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
        }
    }

    private func loadSelected() {
        guard let id = selectedID,
              let agent = store.agents.first(where: { $0.id == id }) else {
            nameField = ""
            agentIdField = ""
            return
        }
        nameField = agent.name
        agentIdField = agent.agentId
    }

    private func addAgent() {
        store.addAgent(name: nameField, agentId: agentIdField)
        nameField = ""
        agentIdField = ""
    }

    private func saveSelected() {
        guard let id = selectedID else { return }
        store.updateAgent(id: id, name: nameField, agentId: agentIdField)
        selectedID = nil
        nameField = ""
        agentIdField = ""
    }

    private func deleteSelected() {
        guard let id = selectedID,
              let index = store.agents.firstIndex(where: { $0.id == id }) else { return }
        store.removeAgents(at: [index])
        selectedID = nil
        nameField = ""
        agentIdField = ""
    }
}
