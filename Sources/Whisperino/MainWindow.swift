import AppKit
import SwiftUI

/// Whisperino's single document-less window. The app is a regular Dock app,
/// so this is what clicking the Dock icon, ⌘0, or "Settings…" brings up.
///
/// The window uses stock chrome - titled, unified toolbar, standard traffic
/// lights - and hands its content to `NSHostingController` so SwiftUI's
/// `NavigationSplitView` drives the sidebar and the split layout the way it
/// does in a native SwiftUI app.
final class MainWindowController: NSObject {
    static let shared = MainWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    /// Bring the window up, creating it on first use.
    /// - Parameter startOnOverview: land on the dashboard instead of General,
    ///   used for the first-run welcome.
    func show(startOnOverview: Bool = false) {
        showWindow(rootView: SettingsView(startOnOverview: startOnOverview))
    }

    private func showWindow(rootView: SettingsView) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
        window.title = "Whisperino"
        // The sidebar selection already says where you are; hide the text
        // and let the sidebar run up under the traffic lights.
        window.titleVisibility = .hidden
        window.styleMask.insert([.miniaturizable, .resizable, .fullSizeContentView])
        // Compact: the toolbar exists only so the sidebar runs up under the
        // traffic lights; with no items and no title, the full-height style
        // draws an empty 52pt band.
        window.toolbarStyle = .unifiedCompact
        let toolbar = NSToolbar(identifier: "WhisperinoMainToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.setContentSize(NSSize(width: 900, height: 620))
        window.setFrameAutosaveName("WhisperinoMainWindow")
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open the window directly on `page`. Used by the settings visual-QA
    /// path so every pane can be rendered without clicking through the app.
    func show(page: SettingsPage) {
        guard window == nil else {
            show()
            return
        }
        showWindow(rootView: SettingsView(page: page))
    }
}
