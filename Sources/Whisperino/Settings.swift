import AppKit
import Foundation

/// User-selectable trigger for push-to-talk / dictation.
///
/// Two flavours:
/// - **Modifier-only** (Fn) - hold a single modifier. Driven by
///   `NSEvent.flagsChanged`.
/// - **Modifier + key combo** (Option+D) - hold a modifier and tap a
///   regular key. Driven by a `CGEventTap` in `HotkeyManager` which
///   intercepts the keystroke so the underlying character (e.g. "∂" for
///   ⌥D) isn't typed into the focused app.
enum TriggerKey: String, Codable, CaseIterable, Identifiable {
    case fn
    case optionD

    var id: String { rawValue }

    /// True for combo triggers (modifier + key); false for modifier-only.
    /// Combo triggers route through the `CGEventTap`, modifier-only triggers
    /// route through the `flagsChanged` monitor.
    var isCombo: Bool {
        comboKeyCode != nil
    }

    /// Virtual key code the combo listens for. `nil` for modifier-only triggers.
    /// Values are `kVK_ANSI_*` constants (Carbon HIToolbox).
    var comboKeyCode: UInt16? {
        switch self {
        case .optionD: return 2   // kVK_ANSI_D
        case .fn:      return nil
        }
    }

    /// Whether the trigger's modifier portion is currently held.
    /// For modifier-only triggers, this IS the trigger.
    /// For combo triggers, the modifier alone isn't enough - the combo key
    /// must also be pressed (handled by the event tap).
    func isDown(in flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .fn: return flags.contains(.function)
        case .optionD:
            return flags.contains(.option)
        }
    }

    /// Modifiers that, if held alongside the trigger, should suppress
    /// activation - e.g. avoid hijacking Cmd+Fn system shortcuts.
    /// The trigger's own modifier family is excluded so pressing the
    /// trigger doesn't self-block.
    var blockedFlags: NSEvent.ModifierFlags {
        var blocked: NSEvent.ModifierFlags = [.command, .control, .option]
        switch self {
        case .fn: break
        case .optionD:
            blocked.subtract(.option)
        }
        return blocked
    }

    /// Compact label for inline shortcut hints ("hold fn", "fn + ⇧").
    var shortLabel: String {
        switch self {
        case .fn:      return "fn"
        case .optionD: return "⌥D"
        }
    }

    /// Verbose name for the picker UI.
    var displayName: String {
        switch self {
        case .fn:      return "Fn (function key)"
        case .optionD: return "Option + D (⌥D)"
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
    var triggerKey: TriggerKey = .fn
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
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        llmRefinementEnabled = try container.decodeIfPresent(Bool.self, forKey: .llmRefinementEnabled) ?? false
        // Default `aiModeEnabled` to whatever refinement was - pre-split
        // installs only had one toggle, and AI mode previously required it.
        aiModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .aiModeEnabled) ?? llmRefinementEnabled
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        // Migrate retired triggers (e.g. .optionQ) to the default rather
        // than failing the whole settings decode.
        if let stored = try? container.decode(TriggerKey.self, forKey: .triggerKey) {
            triggerKey = stored
        } else {
            triggerKey = .fn
        }
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
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(llmRefinementEnabled, forKey: .llmRefinementEnabled)
        try container.encode(aiModeEnabled, forKey: .aiModeEnabled)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encode(triggerKey, forKey: .triggerKey)
        try container.encode(soundEffectsEnabled, forKey: .soundEffectsEnabled)
        try container.encode(pauseMediaOnRecordingStart, forKey: .pauseMediaOnRecordingStart)
        try container.encode(transcriptionLanguageCodes, forKey: .transcriptionLanguageCodes)
        try container.encodeIfPresent(preferredInputDeviceUID, forKey: .preferredInputDeviceUID)
        try container.encode(rafterinoModeEnabled, forKey: .rafterinoModeEnabled)
        try container.encode(asrModel, forKey: .asrModel)
        try container.encode(streamingTranscriptionEnabled, forKey: .streamingTranscriptionEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case llmRefinementEnabled
        case aiModeEnabled
        case apiKey
        case triggerKey
        case soundEffectsEnabled
        case pauseMediaOnRecordingStart
        case transcriptionLanguageCode
        case transcriptionLanguageCodes
        case preferredInputDeviceUID
        case rafterinoModeEnabled
        case asrModel
        case streamingTranscriptionEnabled
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
