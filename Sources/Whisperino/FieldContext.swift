import AppKit
import ApplicationServices

/// Reads the text around the insertion point of the focused text field
/// via the Accessibility API. The refiner uses it as context so a
/// dictation that continues a half-written sentence comes back with
/// matching capitalization, punctuation, language, and tone.
enum FieldContext {
    /// Cap on how much surrounding text rides along on the refine call.
    /// The tail end is what matters — that's where the cursor is.
    private static let maxLength = 1500

    /// Returns the focused field's text up to the insertion point, or nil
    /// when there's no readable focused field. Secure fields (passwords)
    /// are never read.
    static func read() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String, role == "AXSecureTextField" { return nil }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // Cut at the insertion point when the field reports one — text
        // after the caret can't inform how the dictation should continue.
        var prefix = text
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeValue = rangeRef,
           CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(unsafeDowncast(rangeValue as AnyObject, to: AXValue.self), .cfRange, &range),
               range.location >= 0, range.location <= text.utf16.count {
                let index = String.Index(utf16Offset: range.location, in: text)
                prefix = String(text[..<index])
            }
        }

        let context = String(prefix.suffix(maxLength))
        return context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : context
    }
}
