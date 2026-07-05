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
    /// Live streaming for plain dictation: as each ~40s chunk finishes
    /// transcribing (while you're still talking), its text is pasted
    /// straight into the focused input. Long recordings make visible
    /// progress and a crash can only ever lose the last chunk. Sessions
    /// that streamed live skip Haiku refinement - the raw text has
    /// already been committed to the target field.
    var liveStreamingEnabled: Bool = false
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
        liveStreamingEnabled = try container.decodeIfPresent(Bool.self, forKey: .liveStreamingEnabled) ?? false
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
