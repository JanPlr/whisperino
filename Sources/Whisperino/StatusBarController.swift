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

    /// Draw the waveform icon. When `isTemplate` is true, macOS adapts the
    /// color automatically (black in light mode, white in dark mode).
    /// When false, `barColor` is used directly (e.g. red for recording).
    private static func makeIcon(barColor: NSColor, asTemplate: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let barWidth: CGFloat = 2.0
            let gap: CGFloat = 2.0
            let heights: [CGFloat] = [0.30, 0.55, 1.0, 0.55, 0.30]
            let totalW = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
            let originX = (rect.width - totalW) / 2
            let maxH = rect.height * 0.68

            // Template images use black; macOS inverts automatically for dark mode
            (asTemplate ? NSColor.black : barColor).setFill()
            for (i, ratio) in heights.enumerated() {
                let h = max(barWidth, maxH * ratio)
                let x = originX + CGFloat(i) * (barWidth + gap)
                let y = (rect.height - h) / 2
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: h),
                             xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
        image.isTemplate = asTemplate
        return image
    }

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.makeIcon(barColor: .black, asTemplate: true)
        statusItem.menu = menu
    }

    private func buildMenu() {
        let recordItem = NSMenuItem(title: "Toggle Recording", action: #selector(toggleRecording), keyEquivalent: "")
        recordItem.target = self
        menu.addItem(recordItem)

        menu.addItem(.separator())

        let shortcutItem = NSMenuItem(title: "Hold fn to dictate · release to submit", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)

        if !appState.isSetUp {
            menu.addItem(.separator())
            let setupItem = NSMenuItem(title: "Run setup.sh to install Whisper", action: nil, keyEquivalent: "")
            setupItem.isEnabled = false
            menu.addItem(setupItem)
        }

        menu.addItem(.separator())

        let copyLastItem = NSMenuItem(title: "Copy Last Transcription", action: #selector(copyLastTranscription), keyEquivalent: "")
        copyLastItem.target = self
        menu.addItem(copyLastItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Whisperino", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
    }

    func menuDidClose(_ menu: NSMenu) {
    }

    @objc private func toggleRecording() {
        appState.toggleRecording()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func copyLastTranscription() {
        guard let text = store.history.first?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
                case .dismissing:
                    self?.overlayPanel.dismiss()
                case .cancelled:
                    // Let cancel animation play, then dismiss, then go idle
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                        self?.overlayPanel.dismiss()
                        // Set idle after panel is fully gone
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            guard case .cancelled = self?.appState.state else { return }
                            self?.appState.suppressStateAnimation = true
                            self?.appState.state = .idle
                            DispatchQueue.main.async {
                                self?.appState.suppressStateAnimation = false
                            }
                        }
                    }
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
            // Red is explicitly colored — not a template
            button.image = Self.makeIcon(barColor: .systemRed, asTemplate: false)
        case .transcribing:
            button.image = Self.makeIcon(barColor: .systemGray, asTemplate: false)
        default:
            // Template: macOS auto-adapts to light/dark menu bar
            button.image = Self.makeIcon(barColor: .black, asTemplate: true)
        }
    }
}
