import AppKit
import Foundation

/// User-selectable trigger for push-to-talk / dictation.
///
/// Supported input types:
/// - **Modifier-only** (Fn) - hold a single modifier. Driven by
///   `NSEvent.flagsChanged`.
/// - **Modifier + key combo** (Fn+Space, Option+D) - hold modifier(s) and
///   tap a regular key. Driven by a `CGEventTap` in `HotkeyManager` which
///   intercepts the keystroke so it isn't typed into the focused app.
/// - **Mouse button** - any auxiliary button (middle, back, forward, etc.).
///
/// Shift is never stored as part of the trigger: it is reserved for
/// upgrading a take to Talk to your screen.
struct TriggerShortcut: Codable, Hashable {
    /// Device-independent modifier bits that must be held.
    var modifierFlags: UInt
    /// Virtual key code the combo listens for. `nil` for modifier-only.
    /// Values are Carbon `kVK_*` constants.
    var keyCode: UInt16?
    /// Zero-based Quartz mouse button number. Primary and secondary clicks
    /// are deliberately unavailable; auxiliary buttons start at 2.
    var mouseButton: Int?

    init(modifierFlags: UInt, keyCode: UInt16?, mouseButton: Int? = nil) {
        self.modifierFlags = modifierFlags
        self.keyCode = keyCode
        self.mouseButton = mouseButton
    }

    static let recognizedModifiers: NSEvent.ModifierFlags = [
        .command, .control, .option, .function
    ]

    static let fn = TriggerShortcut(
        modifierFlags: NSEvent.ModifierFlags.function.rawValue,
        keyCode: nil
    )
    static let fnSpace = TriggerShortcut(
        modifierFlags: NSEvent.ModifierFlags.function.rawValue,
        keyCode: 49  // kVK_Space
    )
    static let optionD = TriggerShortcut(
        modifierFlags: NSEvent.ModifierFlags.option.rawValue,
        keyCode: 2  // kVK_ANSI_D
    )

    static func mouseButton(_ number: Int) -> TriggerShortcut {
        TriggerShortcut(modifierFlags: 0, keyCode: nil, mouseButton: number)
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags).intersection(Self.recognizedModifiers)
    }

    /// True for combo triggers (modifier + key); false for modifier-only.
    var isCombo: Bool { keyCode != nil }

    var isMouseButton: Bool { mouseButton != nil }

    /// Virtual key code the combo listens for. `nil` for modifier-only.
    var comboKeyCode: UInt16? { keyCode }

    var isValid: Bool {
        if let mouseButton { return mouseButton >= 2 }
        return !modifiers.isEmpty
    }

    /// Whether the trigger's modifier portion is currently held.
    func isDown(in flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(modifiers) && !modifiers.isEmpty
    }

    /// Modifiers that, if held alongside the trigger, should suppress
    /// activation - e.g. avoid hijacking Cmd+Fn system shortcuts.
    /// The trigger's own modifier family is excluded so pressing the
    /// trigger doesn't self-block.
    var blockedFlags: NSEvent.ModifierFlags {
        var blocked: NSEvent.ModifierFlags = [.command, .control, .option]
        blocked.subtract(modifiers)
        return blocked
    }

    /// Compact label for inline shortcut hints ("hold fn", "fn + space").
    var shortLabel: String {
        if let mouseButton {
            return "Mouse \(mouseButton + 1)"
        }
        let mods = Self.modifierSymbols(modifiers)
        guard let keyCode else {
            return mods.joined(separator: " + ")
        }
        let key = Self.label(forKeyCode: keyCode)
        if key.count == 1, mods.count == 1, mods[0] != "fn" {
            return mods[0] + key
        }
        return (mods + [key]).joined(separator: " + ")
    }

    var displayName: String { shortLabel }

    static func sanitizedModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(recognizedModifiers)
    }

    /// Build a combo from a key-down. Requires at least one recognized
    /// modifier; Escape / Return are rejected because they are cancel/submit.
    static func fromKeyDown(_ event: NSEvent) -> TriggerShortcut? {
        let key = event.keyCode
        if key == 53 || key == 36 || key == 76 { return nil }
        let mods = sanitizedModifiers(event.modifierFlags)
        guard !mods.isEmpty else { return nil }
        return TriggerShortcut(modifierFlags: mods.rawValue, keyCode: key)
    }

    /// Build a modifier-only trigger from flags after the keys are released.
    static func fromModifiersOnly(_ flags: NSEvent.ModifierFlags) -> TriggerShortcut? {
        let mods = sanitizedModifiers(flags)
        guard !mods.isEmpty else { return nil }
        return TriggerShortcut(modifierFlags: mods.rawValue, keyCode: nil)
    }

    /// Build an auxiliary-mouse trigger. Left and right click remain reserved
    /// for normal pointer interaction so an accidental setting cannot make
    /// the Mac difficult to use.
    static func fromMouseButton(_ buttonNumber: Int) -> TriggerShortcut? {
        guard buttonNumber >= 2 else { return nil }
        return .mouseButton(buttonNumber)
    }

    static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> [String] {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.command) { parts.append("⌘") }
        if flags.contains(.function) { parts.append("fn") }
        return parts
    }

    static func label(forKeyCode keyCode: UInt16) -> String {
        switch keyCode {
        case 36, 76: return "↩"
        case 48: return "tab"
        case 49: return "space"
        case 51: return "delete"
        case 53: return "esc"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 114: return "help"
        case 115: return "home"
        case 116: return "page up"
        case 117: return "fwd delete"
        case 118: return "F4"
        case 119: return "end"
        case 120: return "F2"
        case 121: return "page down"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            return ansiKeyLabel(keyCode) ?? "key \(keyCode)"
        }
    }

    /// US-layout ANSI keycaps. Matching uses the virtual key code, so this
    /// is display-only and stays stable even on other layouts.
    private static func ansiKeyLabel(_ keyCode: UInt16) -> String? {
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 50: "`",
        ]
        return map[keyCode]
    }
}

/// How the configured recording shortcut starts and stops dictation.
enum RecordingActivation: String, Codable, CaseIterable, Identifiable {
    case hold
    case tap

    var id: String { rawValue }

    var defaultShortcut: TriggerShortcut {
        .fn
    }

    func idleHint(for trigger: String) -> String {
        switch self {
        case .hold: return "hold \(trigger)"
        case .tap: return "tap \(trigger)"
        }
    }

    func recordingHint(for trigger: String) -> String {
        switch self {
        case .hold: return "release \(trigger) or ↩"
        case .tap: return "tap \(trigger) or ↩"
        }
    }
}

/// Languages understood by the bundled multilingual Whisper model. `auto`
/// lets Whisper detect the language independently for every recorded chunk,
/// which is the right choice when a user dictates in more than one language.
enum TranscriptionLanguageCatalog {
    static let automaticCode = "auto"

    // Whisper-family models use ISO-style language codes. Keep the
    // stored setting as a code so it is stable when the Mac's display language
    // changes; labels are localized at presentation time.
    static let supportedCodes = [
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo",
        "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
        "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw",
        "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja",
        "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo",
        "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
        "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt",
        "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq",
        "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl",
        "tr", "tt", "uk", "ur", "uz", "vi", "yi", "yo", "yue", "zh",
    ]

    static var localizedOptions: [(code: String, name: String)] {
        supportedCodes
            .map { code in
                let name = Locale.current.localizedString(forLanguageCode: code)
                    ?? code.uppercased()
                return (code: code, name: name.capitalized(with: Locale.current))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func recognitionConfiguration(for selectedCodes: [String]) -> (language: String, prompt: String?) {
        let validCodes = selectedCodes.filter { supportedCodes.contains($0) }
        guard validCodes.count != 1 else { return (validCodes[0], nil) }
        guard !validCodes.isEmpty else { return (automaticCode, nil) }

        // Whisper accepts one forced language or automatic detection, not
        // a native language whitelist. With several preferences we retain
        // per-chunk detection and prime decoding with the chosen set. That
        // preserves natural language switching while strongly steering short
        // or ambiguous utterances toward the user's languages.
        let english = Locale(identifier: "en")
        let names = validCodes.map {
            english.localizedString(forLanguageCode: $0) ?? $0.uppercased()
        }
        return (
            automaticCode,
            "The speaker uses only these languages: \(names.joined(separator: ", "))."
        )
    }
}

struct AppSettings: Codable, Equatable {
    /// Haiku post-processing on raw whisper output: dictionary terms,
    /// filler removal, punctuation, self-correction handling.
    var llmRefinementEnabled: Bool = false
    /// Hold trigger + Shift to send a spoken instruction to the LLM and
    /// paste its response. Distinct from refinement so users can keep
    /// raw transcription if the API misbehaves.
    var aiModeEnabled: Bool = false
    var apiKey: String = ""
    /// Every configured input can start or stop the same dictation action.
    /// The first item is the primary trigger shown in compact UI hints.
    var triggerKeys: [TriggerShortcut] = [.fn]

    /// Compatibility accessor for call sites and older tests that only need
    /// the primary trigger. Assigning it replaces the primary while retaining
    /// any additional buttons the user configured.
    var triggerKey: TriggerShortcut {
        get { triggerKeys.first ?? .fn }
        set {
            if triggerKeys.isEmpty {
                triggerKeys = [newValue]
            } else {
                triggerKeys[0] = newValue
            }
            triggerKeys = Self.normalizedTriggers(triggerKeys)
        }
    }

    var triggerSummaryLabel: String {
        let primary = triggerKey.shortLabel
        let additional = max(0, triggerKeys.count - 1)
        return additional == 0 ? primary : "\(primary) (+\(additional))"
    }

    /// How the recording shortcut starts and stops a take.
    /// Hold is push-to-talk (release submits). Tap starts a latched take on
    /// a single press; the same shortcut again submits. Double-tap-to-latch
    /// only applies in Hold, so Tap doesn't immediately stop itself.
    var recordingActivation: RecordingActivation = .hold
    var soundEffectsEnabled: Bool = false
    /// Pause the active system media session before opening the microphone.
    /// Enabled by default so music does not leak into dictation recordings.
    var pauseMediaOnRecordingStart: Bool = true
    /// Empty means unrestricted automatic detection. One value pins Whisper
    /// to that language; multiple values form the user's preferred language
    /// set while retaining automatic per-chunk detection.
    var transcriptionLanguageCodes: [String] = []
    /// CoreAudio UID of the user's preferred input device. Stored by UID
    /// (stable) rather than AudioDeviceID (a transient integer that changes
    /// across reconnects), so the choice survives unplugging a display or
    /// dock and coming back - the case where macOS silently reverts the
    /// system default to the built-in mic. `nil` means "follow the system
    /// default". Whenever the preferred device is connected, Whisperino pins
    /// to it and forces it as the input at record start.
    var preferredInputDeviceUID: String? = nil
    /// Team Rafterino easter egg: the pill goes to sea - ocean waveform,
    /// water border, and a raft sailing while transcription runs. Pure
    /// paint; no behavior changes.
    var rafterinoModeEnabled: Bool = false
    /// In-process transcribe.cpp GGUF. Defaults to Parakeet TDT 0.6B v3.
    var asrModel: ASRModelID = ASRModelCatalog.default
    /// Show partial hypotheses while recording when the selected model can
    /// produce them. Defaults on for existing installs.
    var streamingTranscriptionEnabled: Bool = true
    /// Opt-in post-transcription speaker selection. Speaker analysis runs in a
    /// separate process and never receives audio when this is disabled.
    var voiceIsolationEnabled: Bool = false
    init() {}

    /// Change how the current shortcut behaves without silently changing the
    /// shortcut itself.
    mutating func selectActivation(_ mode: RecordingActivation) {
        recordingActivation = mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        llmRefinementEnabled = try container.decodeIfPresent(Bool.self, forKey: .llmRefinementEnabled) ?? false
        // Default `aiModeEnabled` to whatever refinement was - pre-split
        // installs only had one toggle, and AI mode previously required it.
        aiModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .aiModeEnabled) ?? llmRefinementEnabled
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        // New builds store an ordered list. Fall back through the prior
        // single-object and legacy-string formats without dropping a user's
        // existing shortcut during the upgrade.
        if let stored = try? container.decode([TriggerShortcut].self, forKey: .triggerKeys),
           !Self.normalizedTriggers(stored).isEmpty {
            triggerKeys = Self.normalizedTriggers(stored)
        } else if let stored = try? container.decode(TriggerShortcut.self, forKey: .triggerKey),
                  stored.isValid {
            triggerKeys = [stored]
        } else if let legacy = try? container.decode(String.self, forKey: .triggerKey) {
            switch legacy {
            case "optionD": triggerKeys = [.optionD]
            default: triggerKeys = [.fn]
            }
        } else {
            triggerKeys = [.fn]
        }
        recordingActivation = (try? container.decode(RecordingActivation.self, forKey: .recordingActivation)) ?? .hold
        soundEffectsEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEffectsEnabled) ?? false
        pauseMediaOnRecordingStart = try container.decodeIfPresent(
            Bool.self,
            forKey: .pauseMediaOnRecordingStart
        ) ?? true
        if let storedLanguages = try container.decodeIfPresent(
            [String].self,
            forKey: .transcriptionLanguageCodes
        ) {
            transcriptionLanguageCodes = storedLanguages.reduce(into: []) { result, code in
                guard TranscriptionLanguageCatalog.supportedCodes.contains(code),
                      !result.contains(code) else { return }
                result.append(code)
            }
        } else {
            // Migrate the single-language selector shipped briefly in 2.0.
            let legacyLanguage = try container.decodeIfPresent(
                String.self,
                forKey: .transcriptionLanguageCode
            )
            transcriptionLanguageCodes = legacyLanguage.flatMap {
                TranscriptionLanguageCatalog.supportedCodes.contains($0) ? [$0] : nil
            } ?? []
        }
        preferredInputDeviceUID = try container.decodeIfPresent(String.self, forKey: .preferredInputDeviceUID)
        rafterinoModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .rafterinoModeEnabled) ?? false
        asrModel = (try? container.decode(ASRModelID.self, forKey: .asrModel))
            ?? ASRModelCatalog.default
        streamingTranscriptionEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .streamingTranscriptionEnabled
        ) ?? true
        voiceIsolationEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .voiceIsolationEnabled
        ) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(llmRefinementEnabled, forKey: .llmRefinementEnabled)
        try container.encode(aiModeEnabled, forKey: .aiModeEnabled)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encode(triggerKeys, forKey: .triggerKeys)
        // Keep the primary in the old field so downgrading to a previous
        // Whisperino build still leaves the user with a working trigger.
        try container.encode(triggerKey, forKey: .triggerKey)
        try container.encode(recordingActivation, forKey: .recordingActivation)
        try container.encode(soundEffectsEnabled, forKey: .soundEffectsEnabled)
        try container.encode(pauseMediaOnRecordingStart, forKey: .pauseMediaOnRecordingStart)
        try container.encode(transcriptionLanguageCodes, forKey: .transcriptionLanguageCodes)
        try container.encodeIfPresent(preferredInputDeviceUID, forKey: .preferredInputDeviceUID)
        try container.encode(rafterinoModeEnabled, forKey: .rafterinoModeEnabled)
        try container.encode(asrModel, forKey: .asrModel)
        try container.encode(streamingTranscriptionEnabled, forKey: .streamingTranscriptionEnabled)
        try container.encode(voiceIsolationEnabled, forKey: .voiceIsolationEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case llmRefinementEnabled
        case aiModeEnabled
        case apiKey
        case triggerKey
        case triggerKeys
        case recordingActivation
        case soundEffectsEnabled
        case pauseMediaOnRecordingStart
        case transcriptionLanguageCode
        case transcriptionLanguageCodes
        case preferredInputDeviceUID
        case rafterinoModeEnabled
        case asrModel
        case streamingTranscriptionEnabled
        case voiceIsolationEnabled
    }

    private static func normalizedTriggers(_ triggers: [TriggerShortcut]) -> [TriggerShortcut] {
        triggers.reduce(into: []) { result, trigger in
            guard trigger.isValid, !result.contains(trigger) else { return }
            result.append(trigger)
        }
    }
}

/// Lifetime dictation counters shown on the Home page. History is capped at
/// 50 entries, so totals are accumulated here instead of recomputed from it.
struct UsageStats: Codable, Equatable {
    var totalWords: Int = 0
    var totalTranscripts: Int = 0
}

struct DictionaryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var term: String

    init(id: UUID = UUID(), term: String) {
        self.id = id
        self.term = term
    }
}

struct AgentEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var agentId: String

    init(id: UUID = UUID(), name: String, agentId: String) {
        self.id = id
        self.name = name
        self.agentId = agentId
    }
}

/// An app for which Whisperino presses Return after pasting a dictation, so
/// the message is submitted (or queued, in coding agents) automatically.
/// Matched by bundle identifier; `name` is only for the settings list.
struct AutoSubmitApp: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var bundleId: String

    init(id: UUID = UUID(), name: String, bundleId: String) {
        self.id = id
        self.name = name
        self.bundleId = bundleId
    }
}

struct TranscriptEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    var createdAt: Date
    var isInstruction: Bool

    init(id: UUID = UUID(), text: String, isInstruction: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.isInstruction = isInstruction
        self.createdAt = createdAt
    }
}

struct Snippet: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var text: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, text: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.text = text
        self.createdAt = createdAt
    }
}
