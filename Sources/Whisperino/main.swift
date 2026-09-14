import AppKit
import AVFoundation
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private let appState = AppState()

    // Launch at login is on by default, but only registered once - a user who
    // turns it off in Settings stays off across restarts.
    private static let didSeedLaunchAtLoginKey = "didSeedLaunchAtLogin"
    private static let didShowWelcomeKey = "didShowWelcome"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A browser-downloaded app may be launched from a randomized read-only
        // App Translocation path. Never create TCC grants or onboarding state
        // there; install/relaunch the stable Applications copy first.
        guard !ApplicationInstaller.handleUnstableLaunchIfNeeded() else { return }

        Self.seedLaunchAtLogin()
        // After a self-update the Accessibility grant is gone (ad-hoc CDHash
        // changed) - jump straight to the settings pane alongside the prompt.
        UpdateChecker.handlePostUpdateLaunch()
        UpdateChecker.shared.startAutomaticChecks()
        // Screen Recording (AI mode's screenshot) is requested lazily: the first
        // AI-mode capture attempt drives the macOS prompt. Requesting it at
        // launch proved unreliable for an accessory app.
        // Download the selected GGUF if needed and load it onto Metal
        // so the first dictation does not pay the model-load cost.
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
        showWelcomeIfNeeded()
        requestInitialPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AccessibilityPermissionController.shared.stop()
        appState.shutdownTranscriber()
    }

    /// Never stack the microphone and Accessibility prompts on first launch.
    /// Once the microphone decision is complete, move to Accessibility; on
    /// subsequent launches only the still-missing permission is requested.
    private func requestInitialPermissions() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            AppState.ensureAccessibility()
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                AppState.ensureAccessibility()
            }
        }
    }

    /// Show the overview once on the very first launch so setup progress and
    /// the trigger gesture have a visible home behind the sequenced permission
    /// prompts. Later launches stay quiet - the app usually starts at login,
    /// and its window is one Dock click away.
    private func showWelcomeIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.didShowWelcomeKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.didShowWelcomeKey)
        MainWindowController.shared.show(startOnOverview: true)
    }

    /// Clicking the Dock icon with no window open brings the window back,
    /// the behavior every Dock app has.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        MainWindowController.shared.show()
        return true
    }

    /// Closing the window does not quit: dictation keeps working from the
    /// global trigger and the menu bar item.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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

// Deterministic visual QA for the settings window, the counterpart to the
// notch preview above. Opens the real window with the real store but registers
// no hotkeys, requests no permissions, and starts no audio/model services.
if let qaPage = ProcessInfo.processInfo.environment["WHISPERINO_SETTINGS_QA"] {
    app.setActivationPolicy(.regular)
    AppMenu.install(into: app)
    MainActor.assumeIsolated {
        MainWindowController.shared.show(page: SettingsPage(rawValue: qaPage) ?? .overview)
    }
    app.activate(ignoringOtherApps: true)
    app.run()
    exit(0)
}

// A regular app: Dock icon, app switcher entry, and a real menu bar - on top
// of the menu bar item, which stays the fastest way to reach dictation.
app.setActivationPolicy(.regular)
AppMenu.install(into: app)

let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(delegate) {
    app.run()
}
