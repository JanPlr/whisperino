import AppKit
import Foundation

/// User-selectable trigger key for push-to-talk / dictation.
///
/// Fn is the historical default. Right-side modifiers are offered as
/// alternatives because most people use the left-side modifiers for
/// regular shortcuts (Cmd+C etc.) — the right side is usually free.
enum TriggerKey: String, Codable, CaseIterable, Identifiable {
    case fn
    case rightOption
    case rightCommand
    case rightControl

    var id: String { rawValue }

    /// Whether this key is currently held, given an event's modifier flags.
    /// For the right-side modifiers we look at device-dependent bits in the
    /// raw value (`NX_DEVICER*KEYMASK`) so we can distinguish left vs. right.
    func isDown(in flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .fn:           return flags.contains(.function)
        case .rightOption:  return flags.rawValue & 0x40 != 0    // NX_DEVICERALTKEYMASK
        case .rightCommand: return flags.rawValue & 0x10 != 0    // NX_DEVICERCMDKEYMASK
        case .rightControl: return flags.rawValue & 0x2000 != 0  // NX_DEVICERCTLKEYMASK
        }
    }

    /// Modifiers that, if held alongside the trigger, should suppress
    /// activation — e.g. avoid hijacking Cmd+Fn or Ctrl+Fn system shortcuts.
    /// The trigger's own family is excluded so pressing the trigger doesn't
    /// self-block (e.g. trigger=Right Cmd shouldn't be blocked by .command).
    var blockedFlags: NSEvent.ModifierFlags {
        var blocked: NSEvent.ModifierFlags = [.command, .control, .option]
        switch self {
        case .fn:           break
        case .rightOption:  blocked.subtract(.option)
        case .rightCommand: blocked.subtract(.command)
        case .rightControl: blocked.subtract(.control)
        }
        return blocked
    }

    /// Compact label for inline shortcut hints ("hold fn", "fn + ⇧").
    var shortLabel: String {
        switch self {
        case .fn:           return "fn"
        case .rightOption:  return "right ⌥"
        case .rightCommand: return "right ⌘"
        case .rightControl: return "right ⌃"
        }
    }

    /// Verbose name for the picker UI.
    var displayName: String {
        switch self {
        case .fn:           return "Fn (function key)"
        case .rightOption:  return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var llmRefinementEnabled: Bool = false
    var apiKey: String = ""
    var triggerKey: TriggerKey = .fn
    var soundEffectsEnabled: Bool = false
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        llmRefinementEnabled = try container.decodeIfPresent(Bool.self, forKey: .llmRefinementEnabled) ?? false
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        triggerKey = try container.decodeIfPresent(TriggerKey.self, forKey: .triggerKey) ?? .fn
        soundEffectsEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEffectsEnabled) ?? false
    }
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
