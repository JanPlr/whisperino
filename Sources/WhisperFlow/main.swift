import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[WhisperFlow] App launched, whisper available: \(appState.isSetUp)")
        AppState.ensureAccessibility()
        statusBarController = StatusBarController(appState: appState)

        HotkeyManager.shared.register {
            NSLog("[WhisperFlow] Hotkey triggered!")
            DispatchQueue.main.async { [weak self] in
                self?.appState.toggleRecording()
            }
        }
        NSLog("[WhisperFlow] Hotkey registered (Option+D)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
