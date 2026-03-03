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
            onRelease: { [weak self] in self?.appState.hotkeyReleased() }
        )
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
