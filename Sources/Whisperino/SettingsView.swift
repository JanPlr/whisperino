import AppKit
import Charts
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// The window is built from stock SwiftUI: a sidebar `List`, grouped `Form`s,
// `Toggle`, `Picker`, `Table`. No custom surfaces, palettes, or control
// look-alikes - macOS supplies the vibrancy, selection, focus ring, hover,
// contrast and accessibility behavior, and the app inherits every future
// system refinement for free.

// MARK: - Pages

enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case overview, general, dictation, ai, dictionary, snippets, agents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:   return "Overview"
        case .general:    return "General"
        case .dictation:  return "Dictation"
        case .ai:         return "Langdock"
        case .dictionary: return "Dictionary"
        case .snippets:   return "Snippets"
        case .agents:     return "Agents"
        }
    }

    var icon: String {
        switch self {
        case .overview:   return "square.grid.2x2"
        case .general:    return "gearshape"
        case .dictation:  return "waveform"
        case .ai:         return ""   // drawn as the Langdock mark
        case .dictionary: return "character.book.closed"
        case .snippets:   return "text.quote"
        case .agents:     return "cpu"
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    // A window opened from "Settings…" should land on an actual preference
    // category, never an overview that asks the user to find Settings again.
    @State private var page: SettingsPage

    init(startOnOverview: Bool = false) {
        _page = State(initialValue: startOnOverview ? .overview : .general)
    }

    init(page: SettingsPage) {
        _page = State(initialValue: page)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { item in
                sidebarRow(item)
                    .tag(item)
            }
            .listStyle(.sidebar)
            // Seven fixed rows: nothing to scroll, so never show a scroller
            // or rubber-band.
            .scrollDisabled(true)
            .safeAreaInset(edge: .top, spacing: 0) { SidebarHeader() }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            detail
                .frame(minWidth: 520, minHeight: 480)
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    @ViewBuilder
    private func sidebarRow(_ item: SettingsPage) -> some View {
        if item == .ai {
            // The Langdock mark itself, at the weight of an SF Symbol beside it.
            Label {
                Text(item.title)
            } icon: {
                LangdockMark()
                    .frame(width: 11, height: 15)
            }
        } else {
            Label(item.title, systemImage: item.icon)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch page {
        case .overview:   OverviewPage(page: $page)
        case .general:    GeneralPage()
        case .dictation:  DictationPage()
        case .ai:         LangdockPage()
        case .dictionary: DictionaryPage()
        case .snippets:   SnippetsPage()
        case .agents:     AgentsPage()
        }
    }
}

/// The mark and the name, once, where a document app would show its title.
/// With the Rafterino flag hoisted the whole identity goes to sea.
private struct SidebarHeader: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        HStack(spacing: 8) {
            if store.settings.rafterinoModeEnabled {
                RafterinoRaftMark()
                    .frame(width: 12, height: 12)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Rafterino.field))
            } else {
                BrandBadge(size: 20)
            }
            Text(store.settings.rafterinoModeEnabled ? "rafterino" : "whisperino")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer(minLength: 0)
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }
}

// MARK: - Overview

/// Usage at a glance. Stock grouped form, Swift Charts, system colours -
/// the one brand touch is the lime accent on today's bar.
private struct OverviewPage: View {
    @Binding var page: SettingsPage
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var downloader = ModelDownloader.shared

    private var usage: UsageDigest { UsageDigest(stats: store.stats) }

    var body: some View {
        let usage = self.usage

        Form {
            if !downloader.isInstalled(store.settings.asrModel) {
                Section {
                    LabeledContent("Speech model") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(modelSetupDetail)
                            if let fraction = downloader.status.fraction {
                                ProgressView(value: fraction)
                                    .frame(maxWidth: 240)
                            }
                        }
                    }
                    Button("Open Dictation Settings…") { page = .dictation }
                }
            }

            Section {
                HStack(spacing: 0) {
                    StatTile(value: usage.wordsToday.formatted(), label: "Words today")
                    Divider().padding(.vertical, 4)
                    StatTile(value: store.stats.totalWords.formatted(), label: "Words overall")
                    Divider().padding(.vertical, 4)
                    StatTile(value: usage.timeSaved, label: "Time saved")
                    Divider().padding(.vertical, 4)
                    StatTile(value: usage.dayStreak.formatted(), label: "Day streak")
                }
                .padding(.vertical, 6)
            }

            Section {
                WordsPerDayChart(days: usage.lastDays)
                    .frame(height: 180)
                    .padding(.vertical, 6)
            } header: {
                Text("Last 30 days")
            }

            Section {
                HourOfDayChart(hours: usage.byHour)
                    .frame(height: 140)
                    .padding(.vertical, 6)
            } header: {
                Text("When you dictate")
            }

            Section {
                LabeledContent("Average dictation",
                               value: "\(usage.averageWords) words")
                if let pace = usage.speakingPace {
                    LabeledContent("Speaking pace", value: "\(pace) words per minute")
                }
                LabeledContent("Talk to your screen",
                               value: usage.instructionShare)
                LabeledContent("Longest dictation",
                               value: "\(usage.longestWords.formatted()) words")
            }

            Section {
                if store.history.isEmpty {
                    Text("No dictations yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.history.prefix(10)) { entry in
                        HistoryRow(entry: entry)
                    }
                }
            } header: {
                Text("Recent")
            } footer: {
                if !store.history.isEmpty {
                    Button("Clear History", role: .destructive) { store.clearHistory() }
                        .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var modelSetupDetail: String {
        let model = ASRModelCatalog.descriptor(for: store.settings.asrModel)
        switch downloader.status {
        case .downloading(let id, _, _) where id == model.id:
            let percent = downloader.status.fraction.map { Int($0 * 100) } ?? 0
            return "Downloading \(model.displayName)… \(percent)%"
        case .failed(let id, let message) where id == model.id:
            return message
        default:
            return "\(model.displayName) is required before the first dictation."
        }
    }
}

/// Big number, small label.
private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }
}

// MARK: Overview · charts

private struct DayCount: Identifiable {
    let day: Date
    let words: Int
    let dictations: Int
    var id: Date { day }
}

private struct HourCount: Identifiable {
    let hour: Int
    let dictations: Int
    var id: Int { hour }
}

/// Words per day for the last 30 days. Today is drawn in the brand lime,
/// the rest in the system accent at reduced strength; the dashed rule is the
/// 30-day average.
private struct WordsPerDayChart: View {
    let days: [DayCount]
    @State private var selectedDay: Date?

    private var average: Double {
        let active = days.filter { $0.words > 0 }
        guard !active.isEmpty else { return 0 }
        return Double(active.reduce(0) { $0 + $1.words }) / Double(active.count)
    }

    private var selected: DayCount? {
        guard let selectedDay else { return nil }
        let calendar = Calendar.current
        return days.first { calendar.isDate($0.day, inSameDayAs: selectedDay) }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Group {
                if let selected, selected.dictations > 0 {
                    Text(selected.day, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    + Text("  ·  \(selected.words.formatted()) words")
                } else {
                    Text(" ")
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)

            chart
        }
    }

    private var chart: some View {
        Chart {
            ForEach(days) { day in
                BarMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Words", day.words),
                    width: .ratio(0.6)
                )
                .foregroundStyle(Calendar.current.isDateInToday(day.day)
                                 ? AnyShapeStyle(Brand.limeDeep)
                                 : AnyShapeStyle(Color.accentColor.opacity(0.55)))
                .cornerRadius(3)
            }
            if average > 0 {
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.tertiary)
            }
            if let selected, selected.dictations > 0 {
                RuleMark(x: .value("Selected", selected.day, unit: .day))
                    .foregroundStyle(.quaternary)
            }
        }
        .chartXSelection(value: $selectedDay)
        .chartYScale(domain: 0...Double(max(days.map(\.words).max() ?? 0, 10)) * 1.15)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel()
            }
        }
    }
}

/// Dictations by hour of day, all time.
private struct HourOfDayChart: View {
    let hours: [HourCount]

    private var peak: Int { hours.map(\.dictations).max() ?? 0 }

    var body: some View {
        Chart(hours) { hour in
            BarMark(
                xStart: .value("Hour", Double(hour.hour) + 0.15),
                xEnd: .value("Hour", Double(hour.hour) + 0.85),
                y: .value("Dictations", hour.dictations)
            )
            .foregroundStyle(hour.dictations == peak && peak > 0
                             ? AnyShapeStyle(Brand.limeDeep)
                             : AnyShapeStyle(Color.accentColor.opacity(0.55)))
            .cornerRadius(2)
        }
        .chartXScale(domain: 0.0...24.0)
        .chartXAxis {
            AxisMarks(values: [0.0, 6.0, 12.0, 18.0]) { value in
                AxisValueLabel {
                    if let h = value.as(Double.self) {
                        Text(Self.hourLabel(Int(h)))
                    }
                }
            }
        }
        .chartYAxis(.hidden)
    }

    static func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
    }
}

// MARK: Overview · numbers

/// Everything the Overview shows, derived once from the usage log.
private struct UsageDigest {
    let wordsToday: Int
    let dayStreak: Int
    let lastDays: [DayCount]
    let byHour: [HourCount]
    let averageWords: Int
    let longestWords: Int
    let speakingPace: Int?
    let instructionShare: String
    let timeSaved: String

    init(stats: UsageStats) {
        let calendar = Calendar.current
        let samples = stats.samples
        let today = calendar.startOfDay(for: Date())

        // Per-day totals.
        var perDay: [Date: (words: Int, count: Int)] = [:]
        for sample in samples {
            let day = calendar.startOfDay(for: sample.date)
            perDay[day, default: (0, 0)].words += sample.words
            perDay[day, default: (0, 0)].count += 1
        }
        wordsToday = perDay[today]?.words ?? 0
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        lastDays = (0..<30).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let entry = perDay[day]
            return DayCount(day: day, words: entry?.words ?? 0, dictations: entry?.count ?? 0)
        }

        // Streaks over the set of active days.
        let activeDays = Set(perDay.keys)
        var current = 0
        var day = today
        if !activeDays.contains(day) { day = yesterday }
        while activeDays.contains(day) {
            current += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        dayStreak = current

        // Hour of day.
        var hourCounts = Array(repeating: 0, count: 24)
        for sample in samples {
            hourCounts[calendar.component(.hour, from: sample.date)] += 1
        }
        byHour = hourCounts.enumerated().map { HourCount(hour: $0.offset, dictations: $0.element) }

        // Per-dictation figures.
        let count = max(stats.totalTranscripts, 1)
        averageWords = stats.totalWords / count
        longestWords = samples.map(\.words).max() ?? 0

        let timed = samples.filter { $0.seconds >= 2 && $0.words >= 3 }
        if timed.count >= 5 {
            let words = timed.reduce(0) { $0 + $1.words }
            let minutes = timed.reduce(0.0) { $0 + $1.seconds } / 60
            speakingPace = minutes > 0 ? Int((Double(words) / minutes).rounded()) : nil
        } else {
            speakingPace = nil
        }

        let instructions = samples.filter(\.isInstruction).count
        instructionShare = samples.isEmpty
            ? "—"
            : "\(Int((Double(instructions) / Double(samples.count) * 100).rounded()))% of dictations"

        // Typing the same words at 40 wpm versus the time actually spent
        // speaking (or, without timings, speaking at ~150 wpm).
        let typingMinutes = Double(stats.totalWords) / 40
        let spokenMinutes: Double = {
            let known = samples.reduce(0.0) { $0 + $1.seconds } / 60
            let untimedWords = samples.filter { $0.seconds < 2 }.reduce(0) { $0 + $1.words }
            return known + Double(untimedWords) / 150
        }()
        let saved = max(typingMinutes - spokenMinutes, 0)
        timeSaved = Self.durationLabel(minutes: saved)
    }

    private static func durationLabel(minutes: Double) -> String {
        if minutes < 1 { return "0 min" }
        if minutes < 60 { return "\(Int(minutes.rounded())) min" }
        let hours = minutes / 60
        if hours < 10 { return String(format: "%.1f h", hours) }
        return "\(Int(hours.rounded())) h"
    }
}

private struct HistoryRow: View {
    let entry: TranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.createdAt, format: .relative(presentation: .named))
                if entry.isInstruction {
                    LangdockMark(color: .secondary)
                        .frame(width: 7, height: 10)
                    Text("Langdock")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(entry.text)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
            }
        }
    }
}

// MARK: - General

private struct GeneralPage: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
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
                .toggleStyle(.switch)

                Toggle("Pause media while dictating", isOn: $store.settings.pauseMediaOnRecordingStart)
                    .toggleStyle(.switch)
                Toggle("Play sounds on start and stop", isOn: $store.settings.soundEffectsEnabled)
                    .toggleStyle(.switch)
            }

            Section {
                LabeledContent("Rafterino mode") {
                    RafterinoFlagHoist(isHoisted: $store.settings.rafterinoModeEnabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dictation

private struct DictationPage: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var downloader = ModelDownloader.shared
    @State private var showLanguagePicker = false

    private var selectedModel: ASRModelDescriptor {
        ASRModelCatalog.descriptor(for: store.settings.asrModel)
    }

    private var languageSummary: String {
        let codes = store.settings.transcriptionLanguageCodes
        switch codes.count {
        case 0: return "Automatic"
        case 1...3:
            let names = TranscriptionLanguageCatalog.localizedOptions
                .filter { codes.contains($0.code) }
                .map(\.name)
            return names.isEmpty ? "Automatic" : names.formatted(.list(type: .and))
        default: return "\(codes.count) languages"
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Speech model", selection: $store.settings.asrModel) {
                    ForEach(ASRModelCatalog.all) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                modelStatus
                if selectedModel.supportsStreaming {
                    Toggle("Show live text while speaking",
                           isOn: $store.settings.streamingTranscriptionEnabled)
                        .toggleStyle(.switch)
                        .disabled(!downloader.isInstalled(selectedModel.id))
                }
                LabeledContent("Languages") {
                    HStack(spacing: 10) {
                        Text(languageSummary)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { showLanguagePicker = true }
                    }
                }
            }

            Section {
                LabeledContent("Dictation buttons") {
                    TriggerEditor(shortcuts: $store.settings.triggerKeys, defaultShortcuts: [.fn])
                }
                Picker("Recording", selection: $store.settings.recordingActivation) {
                    Text("Hold to record, release to send").tag(RecordingActivation.hold)
                    Text("Tap to start, tap again to send").tag(RecordingActivation.tap)
                }
                .pickerStyle(.radioGroup)
            }

            Section {
                AutoSubmitRow()
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showLanguagePicker) {
            LanguagePickerSheet(selection: $store.settings.transcriptionLanguageCodes)
        }
    }

    @ViewBuilder
    private var modelStatus: some View {
        let model = selectedModel
        let progress: Double? = {
            guard case .downloading(let id, _, _) = downloader.status, id == model.id else { return nil }
            return downloader.status.fraction
        }()
        let failure: String? = {
            guard case .failed(let id, let message) = downloader.status, id == model.id else { return nil }
            return message
        }()

        if downloader.isInstalled(model.id), progress == nil, failure == nil {
            EmptyView()
        } else {
            LabeledContent("Status") {
                statusDetail(model: model, progress: progress, failure: failure)
            }
        }
    }

    @ViewBuilder
    private func statusDetail(model: ASRModelDescriptor,
                              progress: Double?,
                              failure: String?) -> some View {
        Group {
            if let progress {
                HStack(spacing: 10) {
                    ProgressView(value: progress)
                        .frame(width: 160)
                    Text("\(Int(progress * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Cancel") { downloader.cancel() }
                }
            } else {
                HStack(spacing: 10) {
                    if let failure {
                        Text(failure)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                    Button(failure == nil ? "Download" : "Retry") {
                        downloader.ensure(model.id)
                    }
                    .disabled(downloader.status.isDownloading)
                }
            }
        }
    }

    private func sizeLabel(_ model: ASRModelDescriptor) -> String {
        let mib = Double(model.expectedBytes) / 1_048_576
        return mib >= 1024 ? String(format: "%.1f GB", mib / 1024) : "\(Int(mib.rounded())) MB"
    }
}

// MARK: Dictation · languages

private struct LanguageOption: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

private struct LanguagePickerSheet: View {
    @Binding var selection: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var options: [LanguageOption] {
        TranscriptionLanguageCatalog.localizedOptions.map {
            LanguageOption(code: $0.code, name: $0.name)
        }
    }

    private var filtered: [LanguageOption] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return options }
        return options.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.code.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcription Languages")
                .font(.headline)
            Text("Leave everything unchecked to detect the spoken language automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)

            List {
                ForEach(filtered) { option in
                    Toggle(isOn: binding(for: option.code)) {
                        HStack {
                            Text(option.name)
                            Spacer()
                            Text(option.code.uppercased())
                                .font(.caption)
                                .monospaced()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(minHeight: 280)

            HStack {
                Button("Detect Automatically") { selection = [] }
                    .disabled(selection.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func binding(for code: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(code) },
            set: { isOn in
                if isOn {
                    guard !selection.contains(code) else { return }
                    selection.append(code)
                } else {
                    selection.removeAll { $0 == code }
                }
            }
        )
    }
}

// MARK: Dictation · auto-submit apps

/// A summary row plus an editing sheet, the same shape the language picker
/// uses - a full app list inline turned the settings page into a blob.
private struct AutoSubmitRow: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var showSheet = false

    private var summary: String {
        switch store.autoSubmitApps.count {
        case 0: return "None"
        case 1...2: return store.autoSubmitApps.map(\.name).formatted(.list(type: .and))
        default: return "\(store.autoSubmitApps.count) apps"
        }
    }

    var body: some View {
        LabeledContent("Auto-submit apps") {
            HStack(spacing: 10) {
                Text(summary)
                    .foregroundStyle(.secondary)
                Button("Choose…") { showSheet = true }
            }
        }
        .sheet(isPresented: $showSheet) {
            AutoSubmitSheet()
        }
    }
}

private struct AutoSubmitSheet: View {
    @ObservedObject private var store = SettingsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<UUID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Auto-submit Apps")
                .font(.headline)
            Text("Whisperino presses Return after pasting a dictation in these apps, so the message sends immediately.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $selection) {
                ForEach(store.autoSubmitApps) { app in
                    HStack(spacing: 8) {
                        if let icon = Self.icon(for: app) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "app.dashed")
                                .foregroundStyle(.secondary)
                        }
                        Text(app.name)
                    }
                    .tag(app.id)
                }
            }
            .frame(minHeight: 180)
            .onDeleteCommand(perform: removeSelected)
            .overlay {
                if store.autoSubmitApps.isEmpty {
                    Text("No apps yet.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Add App…", action: pickApp)
                Button("Remove", action: removeSelected)
                    .disabled(selection.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private static func icon(for app: AutoSubmitApp) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
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

    private func removeSelected() {
        let offsets = IndexSet(store.autoSubmitApps.indices.filter {
            selection.contains(store.autoSubmitApps[$0].id)
        })
        guard !offsets.isEmpty else { return }
        store.removeAutoSubmitApps(at: offsets)
        selection.removeAll()
    }
}

// MARK: Dictation · trigger

/// Click-to-record controls for any number of keyboard or mouse triggers.
/// One compact row of chips: click a chip to re-record it, `+` to add another.
private struct TriggerEditor: View {
    @Binding var shortcuts: [TriggerShortcut]
    var defaultShortcuts: [TriggerShortcut]
    @StateObject private var capture = ShortcutCaptureController()
    @State private var editingIndex: Int?
    @State private var isAdding = false
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(shortcuts.indices, id: \.self) { index in
                    Button {
                        startCapture(editing: index)
                    } label: {
                        Text(isCapturing(index) ? "Press a key…" : shortcuts[index].shortLabel)
                            .monospaced()
                    }
                    .help("Click to record a new trigger; right-click to remove")
                    .contextMenu {
                        if shortcuts.count > 1 {
                            Button("Remove", role: .destructive) {
                                cancelCapture()
                                shortcuts.remove(at: index)
                            }
                        }
                    }
                }

                Button {
                    startCapture(editing: nil)
                } label: {
                    Image(systemName: isAdding && capture.isRecording ? "record.circle" : "plus")
                }
                .help(isAdding && capture.isRecording ? "Press a shortcut or mouse button…" : "Add another trigger")

                if shortcuts != defaultShortcuts {
                    Button {
                        cancelCapture()
                        shortcuts = defaultShortcuts
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .help("Restore the default trigger")
                }
            }

            if let error = validationError ?? capture.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .onDisappear(perform: cancelCapture)
    }

    private func isCapturing(_ index: Int) -> Bool {
        capture.isRecording && editingIndex == index && !isAdding
    }

    private func cancelCapture() {
        capture.cancel()
        editingIndex = nil
        isAdding = false
    }

    private func startCapture(editing index: Int?) {
        if capture.isRecording {
            capture.cancel()
            if editingIndex == index && isAdding == (index == nil) {
                editingIndex = nil
                isAdding = false
                return
            }
        }

        editingIndex = index
        isAdding = index == nil
        validationError = nil
        capture.start { newShortcut in
            if let existing = shortcuts.firstIndex(of: newShortcut), existing != index {
                validationError = "That button is already configured."
            } else if let index, shortcuts.indices.contains(index) {
                shortcuts[index] = newShortcut
            } else {
                shortcuts.append(newShortcut)
            }
            editingIndex = nil
            isAdding = false
        }
    }
}

/// Local event monitors that turn the next keyboard or auxiliary-mouse input
/// into a `TriggerShortcut`.
/// Dictation hotkeys are suspended for the duration so the combo isn't also
/// interpreted as a push-to-talk press.
private final class ShortcutCaptureController: ObservableObject {
    @Published var isRecording = false
    @Published var error: String?

    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var mouseMonitor: Any?
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var onCapture: ((TriggerShortcut) -> Void)?

    func start(onCapture: @escaping (TriggerShortcut) -> Void) {
        guard !isRecording else { return }
        self.onCapture = onCapture
        error = nil
        heldModifiers = []
        isRecording = true
        HotkeyManager.shared.suspend()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return nil
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            self?.handleMouseDown(event)
            return nil
        }
    }

    func cancel() {
        finish(resumeHotkeys: true)
    }

    private func handleKeyDown(_ event: NSEvent) {
        if event.keyCode == 53 {
            cancel()
            return
        }
        guard let shortcut = TriggerShortcut.fromKeyDown(event) else {
            error = "Add a modifier (fn, ⌥, ⌃, or ⌘). Esc and Return are reserved."
            return
        }
        commit(shortcut)
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let mods = TriggerShortcut.sanitizedModifiers(event.modifierFlags)
        if !mods.isEmpty {
            heldModifiers = mods
            return
        }
        // All recognized modifiers released with no key → modifier-only
        // shortcut (Fn, Option, …).
        if !heldModifiers.isEmpty, let shortcut = TriggerShortcut.fromModifiersOnly(heldModifiers) {
            commit(shortcut)
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard let shortcut = TriggerShortcut.fromMouseButton(event.buttonNumber) else {
            error = "Use an auxiliary mouse button; left and right click are reserved."
            return
        }
        commit(shortcut)
    }

    private func commit(_ shortcut: TriggerShortcut) {
        onCapture?(shortcut)
        finish(resumeHotkeys: true)
    }

    private func finish(resumeHotkeys: Bool) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
        mouseMonitor = nil
        heldModifiers = []
        onCapture = nil
        isRecording = false
        if resumeHotkeys {
            HotkeyManager.shared.resume()
        }
    }

    deinit {
        finish(resumeHotkeys: true)
    }
}

// MARK: - Langdock

private struct LangdockPage: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var showAPIKey = false

    private var hasAPIKey: Bool {
        !store.settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let trigger = store.settings.triggerKey.shortLabel

        Form {
            Section {
                LabeledContent("API key") {
                    HStack(spacing: 6) {
                        Group {
                            if showAPIKey {
                                TextField("Paste Langdock API key", text: $store.settings.apiKey)
                            } else {
                                SecureField("Paste Langdock API key", text: $store.settings.apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()

                        Button {
                            showAPIKey.toggle()
                        } label: {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showAPIKey ? "Hide API key" : "Show API key")
                    }
                }
            }

            Section {
                Picker("Transcripts", selection: $store.settings.llmRefinementEnabled) {
                    Text("Raw").tag(false)
                    Text("Cleaned up").tag(true)
                }
                .pickerStyle(.radioGroup)
                .disabled(!hasAPIKey)

                Toggle("Talk to your screen", isOn: $store.settings.aiModeEnabled)
                    .toggleStyle(.switch)
                    .disabled(!hasAPIKey)
            } footer: {
                Text("Talk to your screen: hold \(trigger) + ⇧, speak, then tap \(trigger) or press ↩ to submit.")
            }
        }
        .formStyle(.grouped)
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

// MARK: - List page scaffold

/// A stock macOS editable list: description, `Table`, and the `+` / `−` bar
/// underneath it, the same shape System Settings uses for login items.
private struct ListPageChrome<Content: View>: View {
    let description: String
    let addLabel: String
    let canRemove: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(description)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            content

            HStack(spacing: 10) {
                Button(action: onAdd) {
                    Label(addLabel, systemImage: "plus")
                }
                Button(action: onRemove) {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(!canRemove)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Dictionary

private struct DictionaryPage: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var selection = Set<UUID>()
    @State private var showAddSheet = false
    @State private var editingEntry: DictionaryEntry?

    /// Split "phonetic = Correct" mappings into two columns.
    private static func parts(of term: String) -> (heard: String, written: String) {
        let pieces = term.split(separator: "=", maxSplits: 1)
        guard pieces.count == 2 else { return (term, term) }
        return (pieces[0].trimmingCharacters(in: .whitespaces),
                pieces[1].trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        ListPageChrome(
            description: "Terms Langdock should always spell correctly — your name, product names, company jargon.",
            addLabel: "Add Term",
            canRemove: !selection.isEmpty,
            onAdd: { showAddSheet = true },
            onRemove: removeSelected
        ) {
            if store.dictionary.isEmpty {
                ContentUnavailableView(
                    "No Terms",
                    systemImage: "character.book.closed",
                    description: Text("Add words the model keeps mishearing — plain terms, or “phonetic = Correct” mappings like “langdonk = Langdock”.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(store.dictionary, selection: $selection) {
                    TableColumn("Heard as") { entry in
                        Text(Self.parts(of: entry.term).heard)
                    }
                    TableColumn("Written as") { entry in
                        Text(Self.parts(of: entry.term).written)
                    }
                }
                .contextMenu(forSelectionType: UUID.self) { _ in
                    Button("Edit…") { editSelected() }
                    Button("Remove", role: .destructive) { removeSelected() }
                } primaryAction: { _ in
                    editSelected()
                }
                .onDeleteCommand(perform: removeSelected)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            DictionaryEditorSheet(entry: nil)
        }
        .sheet(item: $editingEntry) { entry in
            DictionaryEditorSheet(entry: entry)
        }
    }

    private func editSelected() {
        guard let id = selection.first,
              let entry = store.dictionary.first(where: { $0.id == id }) else { return }
        editingEntry = entry
    }

    private func removeSelected() {
        let offsets = IndexSet(store.dictionary.indices.filter {
            selection.contains(store.dictionary[$0].id)
        })
        guard !offsets.isEmpty else { return }
        store.removeDictionaryTerms(at: offsets)
        selection.removeAll()
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
            title: entry == nil ? "Add to Dictionary" : "Edit Term",
            actionLabel: entry == nil ? "Add" : "Save",
            actionEnabled: !trimmed.isEmpty,
            onSubmit: submit
        ) {
            Text("Use “phonetic = Correct” to map what the model mishears to the right spelling. Requires cleanup to be enabled.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Term", text: $term, prompt: Text("Langdock  or  langdonk = Langdock"))
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

// MARK: - Snippets

private struct SnippetsPage: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var selection = Set<UUID>()
    @State private var showAddSheet = false
    @State private var editingSnippet: Snippet?

    var body: some View {
        ListPageChrome(
            description: "Text you type often — say a snippet's name while dictating to drop it in place.",
            addLabel: "Add Snippet",
            canRemove: !selection.isEmpty,
            onAdd: { showAddSheet = true },
            onRemove: removeSelected
        ) {
            if store.snippets.isEmpty {
                ContentUnavailableView(
                    "No Snippets",
                    systemImage: "text.quote",
                    description: Text("“my email = jan@…” is a classic.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(store.snippets, selection: $selection) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Expansion") { snippet in
                        Text(snippet.text.replacingOccurrences(of: "\n", with: " "))
                    }
                }
                .contextMenu(forSelectionType: UUID.self) { _ in
                    Button("Edit…") { editSelected() }
                    Button("Remove", role: .destructive) { removeSelected() }
                } primaryAction: { _ in
                    editSelected()
                }
                .onDeleteCommand(perform: removeSelected)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            SnippetEditorSheet(snippet: nil)
        }
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditorSheet(snippet: snippet)
        }
    }

    private func editSelected() {
        guard let id = selection.first,
              let snippet = store.snippets.first(where: { $0.id == id }) else { return }
        editingSnippet = snippet
    }

    private func removeSelected() {
        let offsets = IndexSet(store.snippets.indices.filter {
            selection.contains(store.snippets[$0].id)
        })
        guard !offsets.isEmpty else { return }
        store.removeSnippets(at: offsets)
        selection.removeAll()
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
            title: snippet == nil ? "Add Snippet" : "Edit Snippet",
            actionLabel: snippet == nil ? "Add" : "Save",
            actionEnabled: valid,
            onSubmit: submit
        ) {
            TextField("Name", text: $name, prompt: Text("What you'll say"))
                .textFieldStyle(.roundedBorder)

            Text("Expansion")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.body)
                .frame(height: 150)
                .border(Color(nsColor: .separatorColor))
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

// MARK: - Agents

private struct AgentsPage: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var selection = Set<UUID>()
    @State private var showAddSheet = false
    @State private var editingAgent: AgentEntry?

    var body: some View {
        ListPageChrome(
            description: "Langdock agents you can call by voice — say an agent's name while talking to your screen to route the request there instead of the default model.",
            addLabel: "Add Agent",
            canRemove: !selection.isEmpty,
            onAdd: { showAddSheet = true },
            onRemove: removeSelected
        ) {
            if store.agents.isEmpty {
                ContentUnavailableView(
                    "No Agents",
                    systemImage: "cpu",
                    description: Text("Add a Langdock agent with its ID, then say its name while dictating an instruction.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(store.agents, selection: $selection) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Agent ID") { agent in
                        Text(agent.agentId).monospaced()
                    }
                }
                .contextMenu(forSelectionType: UUID.self) { _ in
                    Button("Edit…") { editSelected() }
                    Button("Remove", role: .destructive) { removeSelected() }
                } primaryAction: { _ in
                    editSelected()
                }
                .onDeleteCommand(perform: removeSelected)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AgentEditorSheet(agent: nil)
        }
        .sheet(item: $editingAgent) { agent in
            AgentEditorSheet(agent: agent)
        }
    }

    private func editSelected() {
        guard let id = selection.first,
              let agent = store.agents.first(where: { $0.id == id }) else { return }
        editingAgent = agent
    }

    private func removeSelected() {
        let offsets = IndexSet(store.agents.indices.filter {
            selection.contains(store.agents[$0].id)
        })
        guard !offsets.isEmpty else { return }
        store.removeAgents(at: offsets)
        selection.removeAll()
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
            title: agent == nil ? "Add Agent" : "Edit Agent",
            actionLabel: agent == nil ? "Add" : "Save",
            actionEnabled: valid,
            onSubmit: submit
        ) {
            TextField("Name", text: $name, prompt: Text("What you'll say"))
                .textFieldStyle(.roundedBorder)
            TextField("Agent ID", text: $agentId)
                .textFieldStyle(.roundedBorder)
                .monospaced()
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

// MARK: - Shared sheet chrome

/// Standard macOS dialog layout: title, fields, then Cancel / default button
/// in the bottom-trailing corner.
private struct EditorSheet<Content: View>: View {
    let title: String
    let actionLabel: String
    let actionEnabled: Bool
    let onSubmit: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            content

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionLabel) {
                    onSubmit()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!actionEnabled)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
    }
}
