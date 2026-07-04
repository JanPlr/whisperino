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

    /// Fire the macOS Screen Recording prompt. A throwaway ScreenCaptureKit
    /// query is the reliable trigger for an accessory app (a bare
    /// CGRequestScreenCaptureAccess didn't prompt at launch). After the user
    /// grants it, macOS itself offers "Quit & Reopen" - the grant only takes
    /// effect on the next launch.
    static func requestPermission() {
        CGRequestScreenCaptureAccess()
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    /// Capture the full display that contains `windowFrame` (Cocoa coords), or
    /// the main display when we can't tell. Returns nil on any failure - the
    /// caller treats a missing screenshot as "no context this take". The first
    /// `SCShareableContent` access also drives the TCC prompt when ungranted.
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
            // Point resolution (1x) - plenty for the model to read the screen
            // and keeps the upload small versus a full retina capture.
            config.width = display.width
            config.height = display.height
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

        // AX is top-left origin measured from the primary (menu-bar) screen;
        // Cocoa is bottom-left. Flip the window's BOTTOM edge into Cocoa Y.
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main else { return nil }
        let cocoaY = primary.frame.maxY - (pos.y + size.height)
        return CGRect(x: pos.x, y: cocoaY, width: size.width, height: size.height)
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
