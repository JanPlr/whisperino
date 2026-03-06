import AppKit
import Carbon
import Foundation

struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt32 = UInt32(kVK_ANSI_D)
    var modifiers: UInt32 = UInt32(optionKey)

    static let `default` = HotkeyConfig()

    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    static func keyName(for keyCode: UInt32) -> String {
        let map: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_S): "S",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_G): "G",
            UInt32(kVK_ANSI_Z): "Z", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_V): "V",
            UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_Q): "Q",
            UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_E): "E",
            UInt32(kVK_ANSI_R): "R", UInt32(kVK_ANSI_Y): "Y",
            UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K",
            UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_M): "M",
            UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4",
            UInt32(kVK_ANSI_5): "5", UInt32(kVK_ANSI_6): "6",
            UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9", UInt32(kVK_ANSI_0): "0",
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return",
            UInt32(kVK_Tab): "Tab", UInt32(kVK_Delete): "Delete",
            UInt32(kVK_Escape): "Esc",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2",
            UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
            UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
            UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10",
            UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        ]
        return map[keyCode] ?? "Key\(keyCode)"
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }
}

struct AppSettings: Codable, Equatable {
    var llmRefinementEnabled: Bool = false
    var apiKey: String = ""
    var hotkey: HotkeyConfig = .default

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        llmRefinementEnabled = try container.decodeIfPresent(Bool.self, forKey: .llmRefinementEnabled) ?? false
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        hotkey = try container.decodeIfPresent(HotkeyConfig.self, forKey: .hotkey) ?? .default
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
