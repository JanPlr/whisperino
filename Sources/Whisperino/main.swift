import AppKit
import AVFoundation
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private let appState = AppState()

    // Launch at login is on by default, but only registered once - a user who
    // turns it off in Settings stays off across restarts.
    private static let didSeedLaunchAtLoginKey = "didSeedLaunchAtLogin"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.seedLaunchAtLogin()
        // After a self-update the Accessibility grant is gone (ad-hoc CDHash
        // changed) - jump straight to the settings pane alongside the prompt.
        UpdateChecker.handlePostUpdateLaunch()
        AppState.ensureAccessibility()
        UpdateChecker.shared.startAutomaticChecks()
        // Pre-request microphone permission so the first recording attempt isn't
        // interrupted by the macOS permission dialog mid-press
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // Screen Recording (AI mode's screenshot) is requested lazily: the first
        // AI-mode capture attempt drives the macOS prompt. Requesting it at
        // launch proved unreliable for an accessory app.
        // Boot the persistent whisper server now so the model is already
        // in memory by the first dictation.
        appState.warmUpTranscriber()
        // Pre-load the input device list so the first time the picker is
        // opened the panel height is already correct. Without this, the
        // first open populates devices in the same transaction as the
        // open animation, so the count jump (0 → N) rides the spring and
        // the picker visibly "flies in."
        appState.refreshInputDevices()
        statusBarController = StatusBarController(appState: appState)

        HotkeyManager.shared.register(
            onToggle: { [weak self] in self?.appState.hotkeyToggle() },
            onInstructionToggle: { [weak self] in self?.appState.instructionHotkeyToggle() },
            onUpgradeToInstruction: { [weak self] in self?.appState.upgradeToInstructionMode() },
            onCancel: { [weak self] in self?.appState.cancelRecording() },
            onSubmit: { [weak self] in self?.appState.submitOrFinish() },
            onLatchChange: { [weak self] latched in self?.appState.isLatchedRecording = latched },
            isRecording: { [weak self] in
                guard let state = self?.appState.state else { return false }
                switch state {
                case .recording: return true
                default: return false
                }
            },
            // Fallback card counts as "interactive overlay" so Esc/Enter
            // reach it even when no recording is in flight.
            isOverlayInteractive: { [weak self] in
                self?.appState.fallbackResult != nil || self?.appState.assistantCard != nil
            }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.shutdownTranscriber()
    }

    private static func seedLaunchAtLogin() {
        guard !UserDefaults.standard.bool(forKey: didSeedLaunchAtLoginKey) else { return }
        UserDefaults.standard.set(true, forKey: didSeedLaunchAtLoginKey)
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }
}

let app = NSApplication.shared

// Deterministic visual QA for the exact production overlay. This path is only
// entered by an explicit developer environment variable and does not register
// hotkeys, request permissions, or start audio/model services.
if let previewMode = ProcessInfo.processInfo.environment["WHISPERINO_NOTCH_QA"] {
    app.setActivationPolicy(.regular)
    MainActor.assumeIsolated {
        NotchVisualQAPreview.present(mode: previewMode)
    }
    app.activate(ignoringOtherApps: true)
    app.run()
    exit(0)
}

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
