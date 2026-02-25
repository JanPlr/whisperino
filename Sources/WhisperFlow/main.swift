import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController(appState: appState)

        HotkeyManager.shared.register { [weak self] in
            self?.appState.toggleRecording()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
