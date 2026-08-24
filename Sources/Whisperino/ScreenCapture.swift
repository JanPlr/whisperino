import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

/// Silent screen capture for AI mode. When AI mode starts we grab the whole
/// display the user is working on - no picker, no shutter UI - and hand it to
/// the model as image context so the user can "talk to what's on screen".
enum ScreenCapture {

    /// Whether Screen Recording is currently granted (no prompt).
    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Fire the macOS Screen Recording prompt (the single trigger). After the
    /// user grants it, macOS offers "Quit & Reopen" - the grant only takes
    /// effect on the next launch. Callers invoke this at most once per launch.
    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// Capture the full display that contains `windowFrame` (Cocoa coords), or
    /// the main display when we can't tell. Returns nil on any failure - the
    /// caller treats a missing screenshot as "no context this take". Only
    /// called once granted, so it never triggers the prompt itself.
    static func captureActiveDisplay(windowFrame: CGRect?) async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            let targetID = screen(containing: windowFrame).flatMap { displayID(of: $0) }
            guard let display = content.displays.first(where: { $0.displayID == targetID })
                    ?? content.displays.first else {
                NSLog("[whisperino] screen capture: no displays available")
                return nil
            }

            // Exclude our own overlay pill / highlight frame so they don't
            // appear in the shot the model reasons about.
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

            let config = SCStreamConfiguration()
            // A full 5K/6K frame can consume hundreds of MB while AppKit makes
            // TIFF, PNG, and base64 representations for the request. Capture at
            // a model-readable size up front instead of allocating the huge
            // source frame and downscaling it later.
            let longestSide = max(display.width, display.height)
            let captureScale = min(1, 2_048.0 / Double(max(longestSide, 1)))
            config.width = max(1, Int(Double(display.width) * captureScale))
            config.height = max(1, Int(Double(display.height) * captureScale))
            config.showsCursor = false
            config.ignoreShadowsDisplay = true

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            NSLog("[whisperino] screen capture failed: \(error.localizedDescription) - grant Screen Recording in System Settings")
            return nil
        }
    }

    /// The focused window's frame in Cocoa (bottom-left origin) screen
    /// coordinates via the Accessibility API. Used both to pick the display to
    /// capture and to draw the highlight frame around it. Returns nil without an
    /// AX grant or if the app exposes no focused window.
    static func focusedWindowFrame(pid: pid_t?) -> CGRect? {
        guard let frame = focusedWindowAXFrame(pid: pid) else { return nil }
        return cocoaRect(fromAXRect: frame)
    }

    /// Accessibility and Core Graphics both describe displays relative to the
    /// upper-left of the menu-bar display. Keep this raw frame for display hit
    /// testing; converting through NSScreen's lower-left coordinate system is
    /// unnecessary and was fragile with vertically arranged displays.
    private static func focusedWindowAXFrame(pid: pid_t?) -> CGRect? {
        guard let pid, AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let w = winRef, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        let win = w as! AXUIElement

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

        return CGRect(origin: pos, size: size)
    }

    /// Resolve the display that contains the focused insertion point. The
    /// caret is the strongest signal when a window spans displays; the focused
    /// element and focused window are progressively broader fallbacks. Mouse
    /// position is last because the pointer can move after selecting a field.
    static func targetDisplayID(
        focusedElement: AXUIElement?,
        pid: pid_t?
    ) -> CGDirectDisplayID? {
        if let focusedElement,
           let frame = focusedElementAXFrame(focusedElement),
           let displayID = displayID(containingAXFrame: frame) {
            return displayID
        }

        if let displayID = focusedWindowDisplayID(pid: pid) {
            return displayID
        }

        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) {
            return displayID(of: screen)
        }
        return (NSScreen.main ?? NSScreen.screens.first).flatMap(displayID(of:))
    }

    /// Strong display signal for callers that need to distinguish a genuine
    /// focused-window result from targetDisplayID's mouse/main fallbacks.
    static func focusedWindowDisplayID(pid: pid_t?) -> CGDirectDisplayID? {
        guard let frame = focusedWindowAXFrame(pid: pid) else { return nil }
        return displayID(containingAXFrame: frame)
    }

    /// Return focused-element geometry in Accessibility's native global screen
    /// coordinates. Those coordinates match `CGDisplayBounds` exactly.
    private static func focusedElementAXFrame(_ element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success, let rangeRef {
            var boundsRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeRef,
                &boundsRef
            ) == .success,
               let boundsRef,
               CFGetTypeID(boundsRef) == AXValueGetTypeID() {
                var bounds = CGRect.zero
                if AXValueGetValue(boundsRef as! AXValue, .cgRect, &bounds),
                   !bounds.isNull,
                   bounds.minX.isFinite,
                   bounds.minY.isFinite,
                   // Some web editors claim range-bounds support but return
                   // CGRect.zero for a caret. Do not mistake that placeholder
                   // for a real caret on the menu-bar display.
                   bounds.width > 0 || bounds.height > 0 {
                    return bounds
                }
            }
        }

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &posRef
        ) == .success,
              AXUIElementCopyAttributeValue(
                element, kAXSizeAttribute as CFString, &sizeRef
              ) == .success,
              let posRef,
              let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Resolve AX geometry against Core Graphics display bounds without any
    /// coordinate conversion. Apple defines both spaces relative to the
    /// upper-left corner of the display that owns the menu bar.
    private static func displayID(containingAXFrame frame: CGRect) -> CGDirectDisplayID? {
        guard !frame.isNull,
              frame.midX.isFinite,
              frame.midY.isFinite else { return nil }

        let point = CGPoint(x: frame.midX, y: frame.midY)
        for screen in NSScreen.screens {
            guard let displayID = displayID(of: screen) else { continue }
            if CGDisplayBounds(displayID).contains(point) {
                return displayID
            }
        }
        return nil
    }

    private static func cocoaRect(fromAXRect rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main else { return rect }
        return CGRect(
            x: rect.minX,
            y: primary.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - Helpers

    private static func screen(containing frame: CGRect?) -> NSScreen? {
        if let frame {
            let mid = CGPoint(x: frame.midX, y: frame.midY)
            if let hit = NSScreen.screens.first(where: { $0.frame.contains(mid) }) {
                return hit
            }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
