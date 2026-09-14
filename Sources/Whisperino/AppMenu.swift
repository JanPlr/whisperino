import AppKit

/// The standard macOS menu bar. Whisperino is a regular Dock app, so it owns
/// the menu bar whenever it is frontmost and users expect every stock menu to
/// be where it always is: About and Settings under the app menu, the full Edit
/// menu for text fields, and Minimize/Zoom/Close under Window.
///
/// Built in code rather than from a NIB because the package ships as a plain
/// SwiftPM executable with no Interface Builder resources.
enum AppMenu {
    static func install(into app: NSApplication) {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(editMenuItem())
        let windowItem = windowMenuItem()
        mainMenu.addItem(windowItem)
        mainMenu.addItem(helpMenuItem())
        app.mainMenu = mainMenu
        // Hand the Window menu to AppKit so it maintains the window list and
        // the Minimize/Zoom item state for us.
        app.windowsMenu = windowItem.submenu
    }

    private static func appMenuItem() -> NSMenuItem {
        let name = "Whisperino"
        let menu = NSMenu(title: name)

        menu.addItem(withTitle: "About \(name)",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")

        let update = NSMenuItem(title: "Check for Updates…",
                                action: #selector(AppMenuActions.checkForUpdates),
                                keyEquivalent: "")
        update.target = AppMenuActions.shared
        menu.addItem(update)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(AppMenuActions.openSettings),
                                  keyEquivalent: ",")
        settings.target = AppMenuActions.shared
        menu.addItem(settings)

        menu.addItem(.separator())

        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services

        menu.addItem(.separator())

        menu.addItem(withTitle: "Hide \(name)",
                     action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")

        menu.addItem(.separator())

        menu.addItem(withTitle: "Quit \(name)",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func editMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")

        let main = NSMenuItem(title: "Whisperino",
                              action: #selector(AppMenuActions.openSettings),
                              keyEquivalent: "0")
        main.target = AppMenuActions.shared
        menu.addItem(main)

        menu.addItem(.separator())

        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom",
                     action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Close",
                     action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")

        menu.addItem(.separator())

        menu.addItem(withTitle: "Bring All to Front",
                     action: #selector(NSApplication.arrangeInFront(_:)),
                     keyEquivalent: "")

        let item = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func helpMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Help")
        let help = NSMenuItem(title: "Whisperino on GitHub",
                              action: #selector(AppMenuActions.openHelp),
                              keyEquivalent: "")
        help.target = AppMenuActions.shared
        menu.addItem(help)

        let item = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// Menu targets. `NSMenuItem.target` holds a weak reference, so these live on
/// a singleton rather than on a value created while building the menu.
final class AppMenuActions: NSObject {
    static let shared = AppMenuActions()

    private override init() {
        super.init()
    }

    @objc func openSettings() {
        MainWindowController.shared.show()
    }

    @objc func checkForUpdates() {
        UpdateChecker.shared.checkManually()
    }

    @objc func openHelp() {
        guard let url = URL(string: "https://github.com/JanPlr/whisperino") else { return }
        NSWorkspace.shared.open(url)
    }
}
