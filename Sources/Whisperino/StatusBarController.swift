import AppKit
import Combine

class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let appState: AppState
    private let overlayPanel: OverlayPanel
    private var cancellables = Set<AnyCancellable>()
    private let menu: NSMenu
    private let store = SettingsStore.shared

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.overlayPanel = OverlayPanel(appState: appState)
        self.menu = NSMenu()
        super.init()

        menu.delegate = self
        setupButton()
        buildMenu()
        observeState()
    }

    private static func makeIcon(barColor: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let barWidth: CGFloat = 2.0
            let gap: CGFloat = 2.0
            let heights: [CGFloat] = [0.30, 0.55, 1.0, 0.55, 0.30]
            let totalW = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
            let originX = (rect.width - totalW) / 2
            let maxH = rect.height * 0.68

            barColor.setFill()
            for (i, ratio) in heights.enumerated() {
                let h = max(barWidth, maxH * ratio)
                let x = originX + CGFloat(i) * (barWidth + gap)
                let y = (rect.height - h) / 2
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: h),
                             xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
        // NOT template — we control the color explicitly
        image.isTemplate = false
        return image
    }

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.makeIcon(barColor: .white)
        button.target = self
        button.action = #selector(statusBarClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func buildMenu() {
        let recordItem = NSMenuItem(title: "Toggle Recording", action: #selector(toggleRecording), keyEquivalent: "")
        recordItem.target = self
        menu.addItem(recordItem)

        menu.addItem(.separator())

        let shortcutItem = NSMenuItem(title: "\u{2325}D — tap to toggle, hold to push-to-talk", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)

        if !appState.isSetUp {
            menu.addItem(.separator())
            let setupItem = NSMenuItem(title: "Run setup.sh to install Whisper", action: nil, keyEquivalent: "")
            setupItem.isEnabled = false
            menu.addItem(setupItem)
        }

        menu.addItem(.separator())

        let saveSnippetItem = NSMenuItem(title: "Save Last as Snippet…", action: #selector(saveLastAsSnippet), keyEquivalent: "")
        saveSnippetItem.target = self
        menu.addItem(saveSnippetItem)

        let insertSnippetItem = NSMenuItem(title: "Insert Snippet", action: nil, keyEquivalent: "")
        menu.addItem(insertSnippetItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Whisperino", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
        } else {
            appState.toggleRecording()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Update "Save Last as Snippet…" enabled state
        if let saveItem = menu.items.first(where: { $0.action == #selector(saveLastAsSnippet) }) {
            saveItem.isEnabled = appState.lastTranscriptionResult != nil
        }

        // Rebuild Insert Snippet submenu
        if let insertItem = menu.items.first(where: { $0.title == "Insert Snippet" }) {
            let snippets = store.snippets
            if snippets.isEmpty {
                insertItem.submenu = nil
                insertItem.isEnabled = false
            } else {
                let submenu = NSMenu()
                for snippet in snippets {
                    let item = NSMenuItem(title: snippet.name, action: #selector(insertSnippet(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = snippet
                    submenu.addItem(item)
                }
                insertItem.submenu = submenu
                insertItem.isEnabled = true
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    @objc private func toggleRecording() {
        appState.toggleRecording()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func saveLastAsSnippet() {
        guard let text = appState.lastTranscriptionResult else { return }
        let name = "Snippet \(store.snippets.count + 1)"
        store.addSnippet(name: name, text: text)
        SettingsWindowController.shared.show()
    }

    @objc private func insertSnippet(_ sender: NSMenuItem) {
        guard let snippet = sender.representedObject as? Snippet else { return }
        appState.insertSnippet(snippet)
    }

    private func observeState() {
        appState.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateStatusIcon(for: state)
                switch state {
                case .idle:
                    self?.overlayPanel.dismiss()
                default:
                    self?.overlayPanel.present()
                }
            }
            .store(in: &cancellables)
    }

    private func updateStatusIcon(for state: TranscriptionState) {
        guard let button = statusItem.button else { return }
        switch state {
        case .recording:
            button.image = Self.makeIcon(barColor: .systemRed)
        case .transcribing:
            button.image = Self.makeIcon(barColor: .systemGray)
        default:
            button.image = Self.makeIcon(barColor: .white)
        }
    }
}
