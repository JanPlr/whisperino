import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Foundation
import os

private let liveTextLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Whisperino",
    category: "LiveTextInserter"
)

/// Owns one provisional range in the text element that was focused when a
/// dictation take began. Streaming recognizers revise their full hypothesis,
/// so each update replaces this range instead of appending duplicate tokens.
///
/// The range is addressed in UTF-16 code units because that is what the macOS
/// Accessibility API uses. Chromium/Electron updates its cached AX tree over
/// IPC, so a successful write must not be followed by a synchronous read-back:
/// that read commonly returns the previous DOM value even though the edit has
/// already landed on screen.
final class LiveTextInserter {
    private enum KeyboardDelivery: Equatable {
        /// Packaged cross-platform editors accept events sent to their app PID.
        case targetProcess
        /// Browser renderers require events to pass through the focused
        /// WindowServer session before they become DOM keyboard/input events.
        case focusedSession
    }

    /// The exact system-wide focus object present when dictation began. The
    /// writable range can live on one of its ancestors or descendants, so it
    /// is deliberately kept separately from `element`.
    private let focusedElement: AXUIElement
    private let element: AXUIElement
    private let targetPID: pid_t
    private let usesKeyboardInsertion: Bool
    private let keyboardDelivery: KeyboardDelivery?
    private let originalRange: CFRange
    private let originalText: String
    private var ownedRange: CFRange
    private(set) var renderedText = ""
    private(set) var hasInsertedText = false
    /// Focus can leave the target during a take. No events are sent while it
    /// is away; when the exact field returns, restore the caret to our owned
    /// suffix before resuming incremental keyboard edits.
    private var needsCaretRestore = false

    init?(element: AXUIElement) {
        // Chromium/WebKit chat composers sometimes focus a container while
        // the actual text range lives on an ancestor or descendant. Resolve
        // the nearest element that can round-trip its selection instead of
        // assuming the system-wide focused object is itself the editor.
        guard let target = Self.resolveTarget(startingAt: element) else { return nil }

        let selectedText = target.selectedText
        // Never take ownership of a non-empty selection unless its contents
        // can be restored exactly if the take is cancelled.
        guard target.range.length == 0 || selectedText.utf16.count == target.range.length else {
            return nil
        }

        focusedElement = element
        self.element = target.element
        var pid: pid_t = 0
        AXUIElementGetPid(target.element, &pid)
        targetPID = pid
        let delivery = Self.keyboardDelivery(
            element: target.element,
            pid: pid
        )
        keyboardDelivery = delivery
        usesKeyboardInsertion = delivery != nil
        originalRange = target.range
        originalText = selectedText
        ownedRange = target.range

        if delivery == .focusedSession {
            liveTextLogger.notice("Live browser field is using focused-session keyboard insertion")
        } else if delivery == .targetProcess {
            liveTextLogger.notice("Live app field is using process-targeted keyboard insertion")
        } else {
            liveTextLogger.notice("Live field is using native Accessibility replacement")
        }
    }

    /// Replace the current provisional hypothesis. A successful AX mutation is
    /// authoritative. In Chromium/Electron, immediately reading AXValue or
    /// AXStringForRange can return the old cached value and must not detach an
    /// otherwise healthy streaming session.
    @discardableResult
    func replace(with text: String) -> Bool {
        if hasInsertedText, text == renderedText { return true }

        // A browser uses one process for many tabs, windows, and controls.
        // Checking only its PID lets global keyboard events land on whatever
        // the user focused next (including buttons and browser chrome).
        guard isTargetStillFocused() else {
            liveTextLogger.info("Live field detached because the original control lost focus")
            return false
        }

        let inserted: Bool
        if usesKeyboardInsertion {
            inserted = replaceUsingKeyboard(with: text)
        } else {
            let selectionStatus = Self.setRangeStatus(ownedRange, on: element)
            guard selectionStatus == .success else {
                liveTextLogger.warning(
                    "Could not select provisional range (AX error \(selectionStatus.rawValue))"
                )
                return false
            }
            let selectedTextStatus = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFString
            )
            inserted = selectedTextStatus == .success
            if !inserted {
                liveTextLogger.warning(
                    "Could not replace provisional text (AX error \(selectedTextStatus.rawValue))"
                )
            }
        }

        guard inserted else {
            let caret = CFRange(
                location: ownedRange.location + ownedRange.length,
                length: 0
            )
            _ = Self.setRange(caret, on: element)
            return false
        }

        let nextRange = CFRange(location: ownedRange.location, length: text.utf16.count)
        ownedRange = nextRange
        renderedText = text
        hasInsertedText = true
        needsCaretRestore = false

        if !usesKeyboardInsertion {
            // Native AX mutation does not advance the selection consistently.
            let caret = CFRange(location: ownedRange.location + ownedRange.length, length: 0)
            _ = Self.setRange(caret, on: element)
        }
        return true
    }

    /// Restore the selection that existed before dictation. This is used for
    /// cancellation and failures so provisional speech never becomes residue.
    func rollback() {
        guard hasInsertedText else { return }
        // Rollback can synthesize Delete and typing in web editors. If focus
        // moved, leaving provisional text behind is safer than mutating the
        // newly focused app, tab, window, or control.
        guard isTargetStillFocused() else {
            liveTextLogger.info("Live rollback withheld because the original control lost focus")
            return
        }
        if usesKeyboardInsertion {
            guard replaceUsingKeyboard(with: originalText) else { return }
            if originalRange.length > 0 {
                // Keyboard events are delivered asynchronously. Restore the
                // user's original selection after the replacement has landed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    guard let self, self.isTargetStillFocused() else { return }
                    _ = Self.setRange(self.originalRange, on: self.element)
                }
            }
        } else {
            guard Self.setRange(ownedRange, on: element) else { return }
            let selectedTextStatus = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                originalText as CFString
            )
            guard selectedTextStatus == .success else { return }
            _ = Self.setRange(originalRange, on: element)
        }
        hasInsertedText = false
        renderedText = ""
        ownedRange = originalRange
    }

    func pauseForFocusLoss() {
        needsCaretRestore = true
    }

    /// Whether the same app *and exact focused Accessibility object* still
    /// own keyboard input. This distinguishes fields across browser tabs and
    /// windows even though they all share one process identifier.
    func isTargetStillFocused() -> Bool {
        guard targetPID == 0
                || NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
              let current = Self.currentFocusedElement() else { return false }
        return CFEqual(current, focusedElement)
    }

    /// Browser and Electron editors need real DOM keyboard input, but a full
    /// selection + Cmd+V for every hypothesis visibly flashes selection,
    /// mutates the clipboard, and can trigger shortcut UI. Keep the caret at
    /// the end of our owned text and rewrite only the changed suffix using
    /// real, keyboard-layout-aware key presses instead.
    private func replaceUsingKeyboard(with text: String) -> Bool {
        if hasInsertedText, needsCaretRestore {
            let caret = CFRange(
                location: ownedRange.location + ownedRange.length,
                length: 0
            )
            let status = Self.setRangeStatus(caret, on: element)
            guard status == .success else {
                liveTextLogger.warning(
                    "Could not restore the resumed live caret (AX error \(status.rawValue))"
                )
                return false
            }
            needsCaretRestore = false
        }

        if !hasInsertedText {
            let selectionStatus = Self.setRangeStatus(originalRange, on: element)
            guard selectionStatus == .success else {
                liveTextLogger.warning(
                    "Could not place initial live caret (AX error \(selectionStatus.rawValue))"
                )
                return false
            }
            return Self.postKeyboardEdit(
                deleteCount: text.isEmpty && originalRange.length > 0 ? 1 : 0,
                insertion: text,
                to: targetPID,
                delivery: keyboardDelivery ?? .targetProcess
            )
        }

        let oldCharacters = Array(renderedText)
        let newCharacters = Array(text)
        var commonPrefixCount = 0
        let maximumPrefix = min(oldCharacters.count, newCharacters.count)
        while commonPrefixCount < maximumPrefix,
              oldCharacters[commonPrefixCount] == newCharacters[commonPrefixCount] {
            commonPrefixCount += 1
        }

        let deleteCount = oldCharacters.count - commonPrefixCount
        let insertion = String(newCharacters.dropFirst(commonPrefixCount))
        return Self.postKeyboardEdit(
            deleteCount: deleteCount,
            insertion: insertion,
            to: targetPID,
            delivery: keyboardDelivery ?? .targetProcess
        )
    }

    private struct ResolvedTarget {
        let element: AXUIElement
        let range: CFRange
        let selectedText: String
    }

    private static func resolveTarget(startingAt focused: AXUIElement) -> ResolvedTarget? {
        var candidates = [focused]

        // A browser may report a leaf inside its contenteditable ancestor.
        var ancestor = focused
        for _ in 0..<5 {
            guard let parent = elementAttribute(kAXParentAttribute, on: ancestor),
                  !CFEqual(parent, ancestor) else { break }
            candidates.append(parent)
            ancestor = parent
        }

        // Other accessibility trees focus a wrapper above the real editor.
        // Keep the search deliberately bounded so a whole web page cannot
        // turn into an expensive tree walk on every dictation start.
        var queue = childElements(of: focused).map { ($0, 1) }
        var visited = 0
        while !queue.isEmpty, visited < 80 {
            let (candidate, depth) = queue.removeFirst()
            visited += 1
            candidates.append(candidate)
            if depth < 6 {
                queue.append(contentsOf: childElements(of: candidate).map { ($0, depth + 1) })
            }
        }

        for candidate in candidates {
            if stringAttribute(kAXSubroleAttribute, on: candidate) == "AXSecureTextField" {
                continue
            }
            guard let range = rangeAttribute(kAXSelectedTextRangeAttribute, on: candidate),
                  // A harmless no-op selection write is more dependable than
                  // AXUIElementIsAttributeSettable in cross-platform editors.
                  setRange(range, on: candidate) else { continue }

            let fullValue = stringAttribute(kAXValueAttribute, on: candidate)
            let selectedText = stringAttribute(kAXSelectedTextAttribute, on: candidate)
                ?? substring(of: fullValue, in: range)
                ?? ""
            guard range.length == 0 || selectedText.utf16.count == range.length else {
                continue
            }
            return ResolvedTarget(
                element: candidate,
                range: range,
                selectedText: selectedText
            )
        }
        return nil
    }

    private static func substring(of value: String?, in range: CFRange) -> String? {
        guard let value else { return nil }
        let string = value as NSString
        let nsRange = NSRange(location: range.location, length: range.length)
        guard nsRange.location >= 0,
              nsRange.length >= 0,
              NSMaxRange(nsRange) <= string.length else { return nil }
        return string.substring(with: nsRange)
    }

    private static func elementAttribute(_ attribute: String, on element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func currentFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        for attribute in [kAXChildrenAttribute, kAXContentsAttribute, "AXVisibleChildren"] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                  let values = value as? [AnyObject] else { continue }
            result.append(contentsOf: values.compactMap { item in
                guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
                return (item as! AXUIElement)
            })
        }
        return result
    }

    private static func stringAttribute(_ attribute: String, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    /// Web editors can acknowledge AXSelectedText without dispatching the DOM
    /// input event their application state requires. Detect a web-area
    /// ancestor as well as packaged Electron apps and use keyboard insertion.
    private static func keyboardDelivery(
        element: AXUIElement,
        pid: pid_t
    ) -> KeyboardDelivery? {
        if pid != 0,
           let bundleURL = NSRunningApplication(processIdentifier: pid)?.bundleURL,
           FileManager.default.fileExists(
               atPath: bundleURL
                   .appendingPathComponent("Contents/Resources/app.asar")
                   .path
           ) {
            return .targetProcess
        }

        // Chromium may nest an input beneath many layout/ARIA containers.
        // Eight parents was enough for simple chat composers but not controls
        // such as YouTube's search combobox. Walk a bounded but realistic
        // portion of the ancestry so page inputs are not mistaken for native
        // browser chrome.
        var candidate = element
        for _ in 0..<64 {
            if stringAttribute(kAXRoleAttribute, on: candidate) == "AXWebArea" {
                return .focusedSession
            }
            guard let parent = elementAttribute(kAXParentAttribute, on: candidate),
                  !CFEqual(parent, candidate) else { break }
            candidate = parent
        }

        // Some Chromium controls flatten their web-area parent out of the AX
        // ancestry but retain DOM metadata. Native address bars have neither,
        // so this preserves their dependable direct Accessibility path.
        if pid != 0,
           isBrowserProcess(pid),
           (hasAttribute("AXDOMIdentifier", on: element)
                || hasAttribute("AXDOMClassList", on: element)) {
            return .focusedSession
        }
        return nil
    }

    private static func isBrowserProcess(_ pid: pid_t) -> Bool {
        guard let identifier = NSRunningApplication(
            processIdentifier: pid
        )?.bundleIdentifier?.lowercased() else { return false }

        return identifier == "com.brave.browser"
            || identifier == "com.google.chrome"
            || identifier.hasPrefix("com.google.chrome.")
            || identifier == "com.microsoft.edgemac"
            || identifier.hasPrefix("com.microsoft.edgemac.")
            || identifier == "company.thebrowser.browser"
            || identifier == "com.apple.safari"
            || identifier.hasPrefix("org.mozilla.firefox")
    }

    private static func hasAttribute(_ attribute: String, on element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success && value != nil
    }

    private static func postKeyboardEdit(
        deleteCount: Int,
        insertion: String,
        to pid: pid_t,
        delivery: KeyboardDelivery
    ) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              deleteCount >= 0 else {
            liveTextLogger.warning("Could not create incremental keyboard event source")
            return false
        }

        func post(_ event: CGEvent, flags: CGEventFlags = []) {
            // Do not inherit Fn/Command/Option from the hotkey that started
            // the take. Every synthetic press describes its complete state.
            event.flags = flags
            if delivery == .targetProcess, pid != 0 {
                event.postToPid(pid)
            } else {
                event.post(tap: .cghidEventTap)
            }
        }

        // kVK_Delete. One press deletes one user-perceived Character from the
        // unstable suffix, including composed emoji/diacritics in Cocoa and
        // Chromium editors.
        for _ in 0..<deleteCount {
            guard let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: 51,
                keyDown: true
            ), let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: 51,
                keyDown: false
            ) else { return false }
            post(down)
            post(up)
        }

        let keyMap = keyboardMapForCurrentLayout()
        let strokes = insertion.map { keyMap[$0] }

        // CGEvent.keyboardSetUnicodeString is only advisory: Chromium reads
        // the physical virtual key and can therefore turn every such event
        // into the same letter. Use the active macOS keyboard layout to emit
        // genuine hardware-equivalent keys. This dispatches normal DOM
        // beforeinput/input events without selecting text or pressing Cmd+V.
        if strokes.allSatisfy({ $0 != nil }) {
            for stroke in strokes.compactMap({ $0 }) {
                guard let down = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: stroke.keyCode,
                    keyDown: true
                ), let up = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: stroke.keyCode,
                    keyDown: false
                ) else { return false }
                post(down, flags: stroke.flags)
                post(up, flags: stroke.flags)
            }
            return true
        }

        // Emoji and characters that require a dead-key composition cannot be
        // represented by one physical key press. One suffix-only paste is a
        // reliable compatibility path and is far less disruptive than the
        // old full-transcript select-and-paste loop.
        return pasteUnmappableSuffix(
            insertion,
            source: source,
            pid: pid,
            delivery: delivery
        )
    }

    private struct KeyStroke {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    /// Build a reverse lookup from the current input source. Hard-coding an
    /// ANSI-US table breaks immediately on German, French and other layouts.
    private static func keyboardMapForCurrentLayout() -> [Character: KeyStroke] {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayout = TISGetInputSourceProperty(
                inputSource,
                kTISPropertyUnicodeKeyLayoutData
              ) else {
            return [:]
        }

        let layoutData = unsafeBitCast(rawLayout, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return [:] }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let modifiers: [(UInt32, CGEventFlags)] = [
            (0, []),
            (UInt32(shiftKey >> 8), .maskShift),
            (UInt32(optionKey >> 8), .maskAlternate),
            (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate]),
        ]

        var result: [Character: KeyStroke] = [:]
        for keyCode in UInt16(0)..<UInt16(128) {
            for (modifierState, flags) in modifiers {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(
                    layout,
                    keyCode,
                    UInt16(kUCKeyActionDown),
                    modifierState,
                    UInt32(LMGetKbdType()),
                    UInt32(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                guard status == noErr, length > 0 else { continue }
                let string = String(utf16CodeUnits: characters, count: length)
                guard string.count == 1, let character = string.first else { continue }
                // Prefer the least-modified way of producing a character.
                if result[character] == nil {
                    result[character] = KeyStroke(
                        keyCode: CGKeyCode(keyCode),
                        flags: flags
                    )
                }
            }
        }

        // These control characters are actions, not printable layout output.
        result["\n"] = KeyStroke(keyCode: 36, flags: []) // Return
        result["\t"] = KeyStroke(keyCode: 48, flags: []) // Tab
        return result
    }

    private static func pasteUnmappableSuffix(
        _ insertion: String,
        source: CGEventSource,
        pid: pid_t,
        delivery: KeyboardDelivery
    ) -> Bool {
        guard !insertion.isEmpty else { return true }

        let pasteboard = NSPasteboard.general
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> [String: Data]? in
            var values: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { values[type.rawValue] = data }
            }
            return values.isEmpty ? nil : values
        }
        pasteboard.clearContents()
        guard pasteboard.setString(insertion, forType: .string) else { return false }
        let injectedChangeCount = pasteboard.changeCount

        guard let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: true
        ), let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: false
        ) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        if delivery == .targetProcess, pid != 0 {
            down.postToPid(pid)
            up.postToPid(pid)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            // Respect any real copy the user performed in the meantime.
            guard pasteboard.changeCount == injectedChangeCount else { return }
            pasteboard.clearContents()
            for values in savedItems ?? [] {
                let item = NSPasteboardItem()
                for (type, data) in values {
                    item.setData(data, forType: NSPasteboard.PasteboardType(type))
                }
                pasteboard.writeObjects([item])
            }
        }
        return true
    }

    private static func rangeAttribute(_ attribute: String, on element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }

        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func setRange(_ range: CFRange, on element: AXUIElement) -> Bool {
        setRangeStatus(range, on: element) == .success
    }

    private static func setRangeStatus(_ range: CFRange, on element: AXUIElement) -> AXError {
        guard let value = axValue(for: range) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        )
    }

    private static func axValue(for range: CFRange) -> AXValue? {
        var mutableRange = range
        return AXValueCreate(.cfRange, &mutableRange)
    }
}
