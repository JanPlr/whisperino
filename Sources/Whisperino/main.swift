import AppKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.ensureAccessibility()
        // Pre-request microphone permission so the first recording attempt isn't
        // interrupted by the macOS permission dialog mid-press
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        statusBarController = StatusBarController(appState: appState)

        HotkeyManager.shared.register(
            onPress: { [weak self] in self?.appState.hotkeyPressed() },
            onRelease: { [weak self] in self?.appState.hotkeyReleased() },
            onInstructionPress: { [weak self] in self?.appState.instructionHotkeyPressed() },
            onInstructionRelease: { [weak self] in self?.appState.instructionHotkeyReleased() }
        )
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Accessory apps have no default menu bar, so Cmd+V/C/X/A don't work
// in text fields. Add a hidden Edit menu so the responder chain handles them.
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
editMenuItem.submenu = editMenu
let mainMenu = NSMenu()
mainMenu.addItem(editMenuItem)
app.mainMenu = mainMenu

let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(delegate) {
    app.run()
}
