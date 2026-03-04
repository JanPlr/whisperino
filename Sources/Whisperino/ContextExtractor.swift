import AppKit

/// Extracts text context from the frontmost app's focused UI element
/// using the macOS Accessibility API.
struct ContextExtractor {
    static let maxContextLength = 1000

    /// Extract text context from the app with the given PID.
    /// Returns nil if no text could be extracted.
    static func extractContext(from pid: pid_t) -> String? {
        let appRef = AXUIElementCreateApplication(pid)

        // Get the focused UI element
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let element = focusedRef else {
            return nil
        }

        let axElement = element as! AXUIElement

        // Try selected text first (most relevant context)
        if let selected = stringAttribute(axElement, kAXSelectedTextAttribute as CFString),
           !selected.isEmpty {
            return truncate(selected)
        }

        // Fall back to the full value of the focused text element
        if let value = stringAttribute(axElement, kAXValueAttribute as CFString),
           !value.isEmpty {
            return truncate(value)
        }

        return nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    /// Truncate to the last `maxContextLength` characters, breaking at a word boundary.
    private static func truncate(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxContextLength else { return trimmed }
        let suffix = String(trimmed.suffix(maxContextLength))
        if let spaceIndex = suffix.firstIndex(of: " ") {
            return String(suffix[suffix.index(after: spaceIndex)...])
        }
        return suffix
    }
}
