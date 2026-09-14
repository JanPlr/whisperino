import AppKit
import SwiftUI

/// Whisperino's single document-less window, reached from the menu bar item
/// or ⌘, while it is key.
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
            present(window)
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

        present(window)
    }

    /// Bring the window front as the key window of the active app.
    ///
    /// Reached from the menu bar item the app is not active, and a window
    /// ordered front into an inactive app comes up without key status -
    /// macOS 26 then draws it flat: no sidebar glass, dimmed selection, the
    /// toolbar title back. Activate first, then order front, then check on
    /// the next turn of the run loop because activation on macOS 14+ is
    /// cooperative and can land late.
    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            // SwiftUI's split view configures the toolbar after attaching
            // and can bring the title back.
            window.titleVisibility = .hidden
            if !window.isKeyWindow || !NSApp.isActive {
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
        dumpHierarchyIfRequested(window)
    }

    /// Developer aid: write the window's state and AppKit view hierarchy to
    /// a file once it has settled, so sidebar/toolbar chrome can be checked
    /// from any launch path without a screenshot. Triggered by the
    /// WHISPERINO_SETTINGS_QA_DUMP environment variable, or - for an app
    /// launched by Finder/Spotlight, where there is no environment - by the
    /// presence of ~/.whisperino/window-report.txt, which is overwritten.
    private func dumpHierarchyIfRequested(_ window: NSWindow) {
        let flagFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".whisperino/window-report.txt").path
        let path: String
        if let env = ProcessInfo.processInfo.environment["WHISPERINO_SETTINGS_QA_DUMP"] {
            path = env
        } else if FileManager.default.fileExists(atPath: flagFile) {
            path = flagFile
        } else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            var lines: [String] = [
                "key=\(window.isKeyWindow) main=\(window.isMainWindow) appActive=\(NSApp.isActive)",
                "titleVisibility=\(window.titleVisibility.rawValue) toolbarStyle=\(window.toolbarStyle.rawValue) styleMask=\(window.styleMask.rawValue)",
                "appearance=\(window.effectiveAppearance.name.rawValue) reduceTransparency=\(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)",
                "firstResponder=\(String(describing: window.firstResponder.map { type(of: $0) }))",
            ]
            func walk(_ v: NSView, _ depth: Int) {
                lines.append(String(repeating: "  ", count: depth) + "\(type(of: v)) \(NSStringFromRect(v.frame))")
                for sub in v.subviews { walk(sub, depth + 1) }
            }
            if let root = window.contentView?.superview { walk(root, 0) }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
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
