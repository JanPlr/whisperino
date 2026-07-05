import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Brand
//
// Flat, modern, engineering-tool aesthetic (Langfuse/PostHog lineage):
// near-white surfaces, hairline borders, small radii, full-bleed layout,
// monospace micro-labels, one dark CTA per screen. The single black hero
// card keeps the recording pill's surface so app and pill read as one
// product.
enum Brand {
    // Content background.
    static let canvas = dyn(light: NSColor(red: 0.984, green: 0.984, blue: 0.976, alpha: 1),
                            dark: NSColor(red: 0.071, green: 0.071, blue: 0.067, alpha: 1))
    // Sidebar background, slightly tinted.
    static let sidebar = dyn(light: NSColor(red: 0.953, green: 0.953, blue: 0.941, alpha: 1),
                             dark: NSColor(red: 0.102, green: 0.102, blue: 0.094, alpha: 1))
    // Card surface.
    static let card = dyn(light: NSColor.white,
                          dark: NSColor(red: 0.118, green: 0.118, blue: 0.110, alpha: 1))
    // Ink - primary buttons, selected states.
    static let ink = dyn(light: NSColor(red: 0.067, green: 0.067, blue: 0.063, alpha: 1),
                         dark: NSColor(red: 0.925, green: 0.925, blue: 0.910, alpha: 1))
    // Hairline borders.
    static let border = dyn(light: NSColor(white: 0, alpha: 0.10),
                            dark: NSColor(white: 1, alpha: 0.12))
    static let hover = dyn(light: NSColor(white: 0, alpha: 0.035),
                           dark: NSColor(white: 1, alpha: 0.05))
    static let selected = dyn(light: NSColor(white: 0, alpha: 0.07),
                              dark: NSColor(white: 1, alpha: 0.09))

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    private static func dyn(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// Compact solid-ink button - the one strong element per screen.
private struct PrimaryButtonStyle: ButtonStyle {
    var onDark = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(onDark ? Color.black : Brand.card)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(onDark ? Color.white : Brand.ink)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Hairline-bordered quiet button (Cancel, secondary actions).
private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? Brand.hover : Brand.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Brand.border, lineWidth: 1)
            )
    }
}

/// Flat keycap chip - mono label, hairline border (Langfuse keyboard hints).
private struct KeyCap: View {
    let label: String
    var size: CGFloat = 11

    var body: some View {
        Text(label)
            .font(Brand.mono(size, .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, size * 0.55)
            .padding(.vertical, size * 0.28)
            .background(RoundedRectangle(cornerRadius: 4).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Brand.border, lineWidth: 1))
    }
}

/// The black hero surface - the recording pill's color, so the app and
/// the pill read as one product.
private struct ConsoleCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black)
            )
    }
}

/// Monospace micro-label ("TODAY", "USAGE", ...) - the Langfuse eyebrow.
private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Brand.mono(10, .semibold))
            .kerning(1.1)
            .foregroundStyle(.secondary)
    }
}

private struct BrandCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Brand.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Brand.border, lineWidth: 1)
            )
    }
}

// MARK: - Pages

enum FlowPage: String, CaseIterable, Identifiable {
    case home, ai, dictionary, snippets, agents, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:       return "Home"
        case .ai:         return "Langdock"
        case .dictionary: return "Dictionary"
        case .snippets:   return "Snippets"
        case .agents:     return "Agents"
        case .settings:   return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home:       return "square.grid.2x2"
        case .ai:         return "sparkles"
        case .dictionary: return "text.book.closed"
        case .snippets:   return "text.quote"
        case .agents:     return "cpu"
        case .settings:   return "gearshape"
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @State private var page: FlowPage = .home

    var body: some View {
        HStack(spacing: 0) {
            FlowSidebar(page: $page)
                .frame(width: 196)
                .background(Brand.sidebar)

            Rectangle()
                .fill(Brand.border)
                .frame(width: 1)

            Group {
                switch page {
                case .home:       HomePage(page: $page)
                case .ai:         AIPage()
                case .dictionary: DictionaryPage()
                case .snippets:   SnippetsPage()
                case .agents:     AgentsPage()
                case .settings:   SettingsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.canvas)
        }
        .frame(minWidth: 980, minHeight: 640)
        .ignoresSafeArea()
    }
}

// MARK: - Sidebar

private struct FlowSidebar: View {
    @Binding var page: FlowPage

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Wordmark - small black chip, a nod to the pill.
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 21, height: 21)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black))
                Text("whisperino")
                    .font(.system(size: 14, weight: .bold))
            }
            .padding(.leading, 10)
            .padding(.top, 44)   // clear the traffic lights (transparent titlebar)
            .padding(.bottom, 20)

            ForEach([FlowPage.home, .ai, .dictionary, .snippets, .agents]) { item in
                SidebarItem(item: item, selection: $page)
            }

            Spacer()

            SidebarItem(item: .settings, selection: $page)

            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("v\(version)")
                    .font(Brand.mono(10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 10)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }
}

private struct SidebarItem: View {
    let item: FlowPage
    @Binding var selection: FlowPage
    @State private var hovering = false

    private var isSelected: Bool { selection == item }

    var body: some View {
        Button {
            selection = item
        } label: {
            HStack(spacing: 8) {
                if item == .ai {
                    // The Langdock mark stands in for the generic icon here.
                    LangdockMark(color: isSelected ? .primary : .secondary)
                        .frame(width: 16, height: 15)
                } else {
                    Image(systemName: item.icon)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                }
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Brand.selected : (hovering ? Brand.hover : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Page scaffold

private struct PageHeader: View {
    let title: String
    var subtitle: String? = nil
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.top, 40)   // clear the transparent titlebar
    }
}

private struct PageScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: title, subtitle: subtitle,
                           actionLabel: actionLabel, action: action)
                content
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared list row + editor sheet chrome

/// "lead → trail" list row with hover edit/delete.
private struct MappingRow: View {
    let lead: String
    var trail: String? = nil
    var leadMono = false
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(lead)
                .font(leadMono ? Brand.mono(13, .semibold) : .system(size: 13, weight: .medium))
                .lineLimit(1)

            if let trail {
                Text("→")
                    .font(Brand.mono(12))
                    .foregroundStyle(.tertiary)
                Text(trail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .background(hovering ? Brand.hover : .clear)
        .onHover { hovering = $0 }
        .onTapGesture { onEdit() }
    }
}

/// Modal sheet chrome - title, content, Cancel / primary action row.
private struct EditorSheet<Content: View>: View {
    let title: String
    let actionLabel: String
    let actionEnabled: Bool
    let onSubmit: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))

            content

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(actionLabel) {
                    onSubmit()
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!actionEnabled)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 440)
        .background(Brand.card)
    }
}

private struct EmptyListCard: View {
    let icon: String
    let title: String
    let hint: String

    var body: some View {
        BrandCard {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
        }
    }
}

// MARK: - Home

private struct HomePage: View {
    @Binding var page: FlowPage
    @ObservedObject private var store = SettingsStore.shared

    private var firstName: String {
        let name = NSFullUserName().components(separatedBy: " ").first ?? ""
        return name.isEmpty ? "there" : name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hey \(firstName).")
                        .font(.system(size: 20, weight: .semibold))
                    HStack(spacing: 6) {
                        Text("Hold")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        KeyCap(label: store.settings.triggerKey.shortLabel)
                        Text("and just talk - words land where your cursor is.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 40)

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 20) {
                        HeroCard(page: $page)
                        HistorySection()
                    }
                    .frame(maxWidth: .infinity)

                    StatsColumn()
                        .frame(width: 224)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One black card - the pill's surface, holding the AI pitch.
private struct HeroCard: View {
    @Binding var page: FlowPage
    @ObservedObject private var store = SettingsStore.shared

    private var aiReady: Bool {
        store.settings.aiModeEnabled
            && !store.settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let trigger = store.settings.triggerKey.shortLabel

        ConsoleCard {
            VStack(alignment: .leading, spacing: 7) {
                Text("Talk to your screen, anywhere you type.")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)

                Text(aiReady
                     ? "Hold \(trigger) + ⇧, speak, and the answer lands at your cursor."
                     : "Add your Langdock API key and every text field becomes a Langdock prompt.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))

                HStack(spacing: 10) {
                    Button(aiReady ? "Open Langdock settings" : "Get started") {
                        page = .ai
                    }
                    .buttonStyle(PrimaryButtonStyle(onDark: true))

                    Text("\(trigger) + ⇧")
                        .font(Brand.mono(11))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.top, 7)
            }
        }
    }
}

// MARK: Home · history

private struct HistorySection: View {
    @ObservedObject private var store = SettingsStore.shared

    private static let dayLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM d"
        return f
    }()

    private var groups: [(label: String, entries: [TranscriptEntry])] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: store.history) { cal.startOfDay(for: $0.createdAt) }
        return byDay.keys.sorted(by: >).map { day in
            let label: String
            if cal.isDateInToday(day) {
                label = "Today"
            } else if cal.isDateInYesterday(day) {
                label = "Yesterday"
            } else {
                label = Self.dayLabelFormatter.string(from: day)
            }
            let entries = byDay[day]!.sorted { $0.createdAt > $1.createdAt }
            return (label, entries)
        }
    }

    var body: some View {
        if store.history.isEmpty {
            EmptyListCard(
                icon: "waveform.badge.mic",
                title: "No dictations yet",
                hint: "Hold \(SettingsStore.shared.settings.triggerKey.shortLabel) and start talking - your transcripts show up here."
            )
        } else {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groups, id: \.label) { group in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            SectionLabel(group.label)
                            Spacer()
                            if group.label == groups.first?.label {
                                Button("Clear all") { store.clearHistory() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        BrandCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(group.entries) { entry in
                                    HistoryRow(entry: entry)
                                    if entry.id != group.entries.last?.id {
                                        Divider().padding(.leading, 68)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: TranscriptEntry
    @State private var hovering = false
    @State private var copied = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Self.timeFormatter.string(from: entry.createdAt))
                .font(Brand.mono(11))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)

            if entry.isInstruction {
                // Langdock mark flags AI-mode transcripts.
                LangdockMark(color: .secondary)
                    .frame(width: 11, height: 11)
            }

            Text(entry.text)
                .font(.system(size: 13))
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering || copied ? 1 : 0)
            .help("Copy")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(hovering ? Brand.hover : .clear)
        .onHover { hovering = $0 }
    }
}

// MARK: Home · stats

private struct StatsColumn: View {
    @ObservedObject private var store = SettingsStore.shared

    private var wordsToday: Int {
        let cal = Calendar.current
        return store.history
            .filter { cal.isDateInToday($0.createdAt) }
            .reduce(0) { $0 + SettingsStore.wordCount($1.text) }
    }

    /// Consecutive days with at least one dictation, ending today or yesterday.
    private var dayStreak: Int {
        let cal = Calendar.current
        let days = Set(store.history.map { cal.startOfDay(for: $0.createdAt) })
        guard !days.isEmpty else { return 0 }
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: day),
                  days.contains(yesterday) else { return 0 }
            day = yesterday
        }
        var streak = 0
        while days.contains(day) {
            streak += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    var body: some View {
        // Langfuse "Community Stats" panel: eyebrow + label/value rows.
        BrandCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Usage")
                    .padding(.bottom, 2)

                StatRow(label: "Total words", value: store.stats.totalWords.formatted())
                Divider()
                StatRow(label: "Words today", value: wordsToday.formatted())
                Divider()
                StatRow(label: "Day streak", value: dayStreak.formatted())
                Divider()
                StatRow(label: "Dictations", value: store.stats.totalTranscripts.formatted())
            }
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(Brand.mono(12.5, .semibold))
        }
    }
}

// MARK: - AI page

private struct AIPage: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var showAPIKey = false

    private var hasAPIKey: Bool {
        !store.settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let triggerLabel = store.settings.triggerKey.shortLabel

        PageScaffold(
            title: "Langdock",
            subtitle: "Everything Langdock does for you: cleaning up dictations and Talk to your screen."
        ) {
            SettingsCard(title: "API key") {
                HStack {
                    if showAPIKey {
                        TextField("Paste Langdock API key", text: $store.settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Paste Langdock API key", text: $store.settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button(showAPIKey ? "Hide" : "Show") { showAPIKey.toggle() }
                        .buttonStyle(.borderless)
                }
                CaptionText("Without a key, transcription falls back to raw whisper output - no cleanup, no Talk to your screen.")
            }

            SettingsCard(title: "Dictation cleanup") {
                HStack(alignment: .top, spacing: 10) {
                    ChoiceCard(
                        title: "Raw",
                        detail: "Exactly what you said, including mistakes.",
                        selected: !store.settings.llmRefinementEnabled,
                        enabled: true
                    ) {
                        store.settings.llmRefinementEnabled = false
                    }
                    ChoiceCard(
                        title: "Cleaned up",
                        detail: "Langdock removes filler, fixes punctuation, applies your dictionary.",
                        selected: store.settings.llmRefinementEnabled,
                        enabled: hasAPIKey
                    ) {
                        store.settings.llmRefinementEnabled = true
                    }
                }
            }

            SettingsCard(title: "Talk to your screen") {
                ToggleRow(label: "Talk to your screen (\(triggerLabel) + ⇧)",
                          isOn: $store.settings.aiModeEnabled,
                          disabled: !hasAPIKey)
                CaptionText("Hold **\(triggerLabel) + ⇧** (or add ⇧ while already dictating) → Whisperino silently screenshots your current screen and frames the window → speak about what's on screen → tap **\(triggerLabel)** or press **Return** to submit. Langdock answers using the screenshot and pastes the reply inline. It's one-shot: to iterate, start again and the fresh screenshot picks up the latest state.")

                Divider().padding(.vertical, 4)

                ShortcutRow(keys: "\(triggerLabel) + ⇧", label: "Start Talk to your screen (screenshots the screen)")
                ShortcutRow(keys: "tap \(triggerLabel)", label: "Submit")
                ShortcutRow(keys: "↩", label: "Submit")
                ShortcutRow(keys: "esc", label: "Cancel")
            }
        }
        .onChange(of: store.settings.apiKey) { oldValue, newValue in
            let hadKey = !oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasKey = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hadKey && hasKey {
                // First key paste - opt the user into the full AI experience.
                // They can flip either off if the API misbehaves.
                store.settings.llmRefinementEnabled = true
                store.settings.aiModeEnabled = true
            } else if hadKey && !hasKey {
                // Key cleared - nothing to call, switch off both.
                store.settings.llmRefinementEnabled = false
                store.settings.aiModeEnabled = false
            }
        }
    }
}

// MARK: - Settings page

private struct SettingsPage: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        let triggerLabel = store.settings.triggerKey.shortLabel

        PageScaffold(title: "Settings") {
            SettingsCard(title: "App") {
                ToggleRow(label: "Launch at login", isOn: Binding(
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
                Divider()
                ToggleRow(label: "Sound effects on start / stop", isOn: $store.settings.soundEffectsEnabled)
            }

            // Trigger key - let users pick an alternative if Fn is mapped to
            // something else (emoji picker, system function, etc.)
            SettingsCard(title: "Trigger key") {
                HStack {
                    Text("Press to dictate")
                        .font(.system(size: 13))
                    Spacer()
                    Picker("", selection: $store.settings.triggerKey) {
                        ForEach(TriggerKey.allCases) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                CaptionText("The key combo you hold to start recording. Combos like ⌥D need Accessibility permission so the keystroke can be intercepted (no stray “∂” typed).")

                Divider().padding(.vertical, 4)

                ShortcutRow(keys: "hold \(triggerLabel)", label: "Dictate (release to send)")
                ShortcutRow(keys: "\(triggerLabel) \(triggerLabel)", label: "Hands-free dictation (tap to stop)")
                ShortcutRow(keys: "\(triggerLabel) + ⇧", label: "Talk to your screen - hold both, get an answer")
                ShortcutRow(keys: "↩", label: "Submit any recording")
                ShortcutRow(keys: "esc", label: "Cancel")
            }

            // Auto-submit - press Return after pasting so chat apps send the
            // message on their own.
            SettingsCard(title: "Auto-submit") {
                if store.autoSubmitApps.isEmpty {
                    Text("No apps yet - add one below.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 2)
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.autoSubmitApps) { app in
                            AutoSubmitRow(app: app) { deleteAutoSubmit(app) }
                            if app.id != store.autoSubmitApps.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                Button("Add app…", action: pickApp)
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, 4)
            }
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Choose an app that should auto-submit pasted dictations"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundleId = Bundle(url: url)?.bundleIdentifier ?? ""
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        store.addAutoSubmitApp(name: name, bundleId: bundleId)
    }

    private func deleteAutoSubmit(_ app: AutoSubmitApp) {
        guard let index = store.autoSubmitApps.firstIndex(where: { $0.id == app.id }) else { return }
        store.removeAutoSubmitApps(at: [index])
    }
}

/// App row for the auto-submit list: icon + name, hover-to-delete.
private struct AutoSubmitRow: View {
    let app: AutoSubmitApp
    let onDelete: () -> Void
    @State private var hovering = false

    private var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
            }
            Text(app.name)
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Remove")
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        BrandCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title)
                    .padding(.bottom, 2)
                content
            }
        }
    }
}

/// Label left, switch right - grouped settings row.
private struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(disabled ? .secondary : .primary)
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(disabled)
        }
    }
}

/// Selectable option card - title with a radio indicator, detail below.
private struct ChoiceCard: View {
    let title: String
    let detail: String
    let selected: Bool
    var enabled = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    radio
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Brand.selected : (hovering ? Brand.hover : Brand.card))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(selected ? Brand.ink : Brand.border, lineWidth: 1)
            )
            .opacity(enabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 && enabled }
        .animation(.easeOut(duration: 0.12), value: selected)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var radio: some View {
        ZStack {
            Circle()
                .fill(selected ? Brand.ink : Color.clear)
            Circle()
                .strokeBorder(selected ? Color.clear : Brand.border, lineWidth: 1.5)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Brand.card)
            }
        }
        .frame(width: 16, height: 16)
    }
}

private struct CaptionText: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ShortcutRow: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            KeyCap(label: keys)
                .frame(width: 88, alignment: .leading)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Dictionary page

private struct DictionaryPage: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var showAddSheet = false
    @State private var editingEntry: DictionaryEntry?

    /// Split "phonetic = Correct" mappings for arrow display.
    private static func parts(of term: String) -> (lead: String, trail: String?) {
        let pieces = term.split(separator: "=", maxSplits: 1)
        guard pieces.count == 2 else { return (term, nil) }
        return (pieces[0].trimmingCharacters(in: .whitespaces),
                pieces[1].trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        PageScaffold(
            title: "Dictionary",
            subtitle: "Terms the LLM should always spell correctly - your name, product names, company jargon.",
            actionLabel: "Add new",
            action: { showAddSheet = true }
        ) {
            if store.dictionary.isEmpty {
                EmptyListCard(
                    icon: "text.book.closed",
                    title: "No terms yet",
                    hint: "Add words Whisper keeps mishearing - plain terms, or “phonetic = Correct” mappings like “langdonk = Langdock”."
                )
            } else {
                BrandCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(store.dictionary) { entry in
                            let p = Self.parts(of: entry.term)
                            MappingRow(
                                lead: p.lead,
                                trail: p.trail,
                                onEdit: { editingEntry = entry },
                                onDelete: { delete(entry) }
                            )
                            if entry.id != store.dictionary.last?.id {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            DictionaryEditorSheet(entry: nil)
        }
        .sheet(item: $editingEntry) { entry in
            DictionaryEditorSheet(entry: entry)
        }
    }

    private func delete(_ entry: DictionaryEntry) {
        guard let index = store.dictionary.firstIndex(where: { $0.id == entry.id }) else { return }
        store.removeDictionaryTerms(at: [index])
    }
}

private struct DictionaryEditorSheet: View {
    let entry: DictionaryEntry?
    @State private var term: String
    @ObservedObject private var store = SettingsStore.shared

    init(entry: DictionaryEntry?) {
        self.entry = entry
        _term = State(initialValue: entry?.term ?? "")
    }

    private var trimmed: String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        EditorSheet(
            title: entry == nil ? "Add to dictionary" : "Edit term",
            actionLabel: entry == nil ? "Add term" : "Save",
            actionEnabled: !trimmed.isEmpty,
            onSubmit: submit
        ) {
            Text("Use “phonetic = Correct” to map what Whisper mishears to the right spelling. Requires cleanup to be enabled.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("e.g. Langdock  or  langdonk = Langdock", text: $term)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func submit() {
        if let entry {
            store.updateDictionaryTerm(id: entry.id, term: term)
        } else {
            store.addDictionaryTerm(term)
        }
    }
}

// MARK: - Snippets page

private struct SnippetsPage: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var showAddSheet = false
    @State private var editingSnippet: Snippet?

    var body: some View {
        PageScaffold(
            title: "Snippets",
            subtitle: "Text you type often - say a snippet's name while dictating to drop it in place.",
            actionLabel: "Add new",
            action: { showAddSheet = true }
        ) {
            if store.snippets.isEmpty {
                EmptyListCard(
                    icon: "text.quote",
                    title: "No snippets yet",
                    hint: "Add one with the button above - “my email = jan@…” is a classic."
                )
            } else {
                BrandCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(store.snippets) { snippet in
                            MappingRow(
                                lead: snippet.name,
                                trail: snippet.text.replacingOccurrences(of: "\n", with: " "),
                                onEdit: { editingSnippet = snippet },
                                onDelete: { delete(snippet) }
                            )
                            if snippet.id != store.snippets.last?.id {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            SnippetEditorSheet(snippet: nil)
        }
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditorSheet(snippet: snippet)
        }
    }

    private func delete(_ snippet: Snippet) {
        guard let index = store.snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        store.removeSnippets(at: [index])
    }
}

private struct SnippetEditorSheet: View {
    let snippet: Snippet?
    @State private var name: String
    @State private var text: String
    @ObservedObject private var store = SettingsStore.shared

    init(snippet: Snippet?) {
        self.snippet = snippet
        _name = State(initialValue: snippet?.name ?? "")
        _text = State(initialValue: snippet?.text ?? "")
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        EditorSheet(
            title: snippet == nil ? "Add snippet" : "Edit snippet",
            actionLabel: snippet == nil ? "Add snippet" : "Save",
            actionEnabled: valid,
            onSubmit: submit
        ) {
            TextField("Snippet name - what you'll say", text: $name)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 6).fill(Brand.hover))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Brand.border, lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Expansion - what gets typed")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 10)
                            .padding(.leading, 11)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private func submit() {
        if let snippet {
            store.updateSnippet(id: snippet.id, name: name, text: text)
        } else {
            store.addSnippet(name: name, text: text)
        }
    }
}

// MARK: - Agents page

private struct AgentsPage: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var showAddSheet = false
    @State private var editingAgent: AgentEntry?

    var body: some View {
        PageScaffold(
            title: "Agents",
            subtitle: "Langdock agents you can call by voice - say the agent's name while talking to your screen to route your request there instead of the default Langdock model.",
            actionLabel: "Add new",
            action: { showAddSheet = true }
        ) {
            if store.agents.isEmpty {
                EmptyListCard(
                    icon: "cpu",
                    title: "No agents yet",
                    hint: "Add a Langdock agent with its ID, then just say its name while dictating an instruction."
                )
            } else {
                BrandCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(store.agents) { agent in
                            MappingRow(
                                lead: agent.name,
                                trail: agent.agentId,
                                onEdit: { editingAgent = agent },
                                onDelete: { delete(agent) }
                            )
                            if agent.id != store.agents.last?.id {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AgentEditorSheet(agent: nil)
        }
        .sheet(item: $editingAgent) { agent in
            AgentEditorSheet(agent: agent)
        }
    }

    private func delete(_ agent: AgentEntry) {
        guard let index = store.agents.firstIndex(where: { $0.id == agent.id }) else { return }
        store.removeAgents(at: [index])
    }
}

private struct AgentEditorSheet: View {
    let agent: AgentEntry?
    @State private var name: String
    @State private var agentId: String
    @ObservedObject private var store = SettingsStore.shared

    init(agent: AgentEntry?) {
        self.agent = agent
        _name = State(initialValue: agent?.name ?? "")
        _agentId = State(initialValue: agent?.agentId ?? "")
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !agentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        EditorSheet(
            title: agent == nil ? "Add agent" : "Edit agent",
            actionLabel: agent == nil ? "Add agent" : "Save",
            actionEnabled: valid,
            onSubmit: submit
        ) {
            TextField("Agent name - what you'll say", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Agent ID", text: $agentId)
                .textFieldStyle(.roundedBorder)
                .font(Brand.mono(12))
        }
    }

    private func submit() {
        if let agent {
            store.updateAgent(id: agent.id, name: name, agentId: agentId)
        } else {
            store.addAgent(name: name, agentId: agentId)
        }
    }
}
