import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.ensureAccessibility()
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
