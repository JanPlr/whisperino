import AppKit
import Combine

class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let appState: AppState
    private let overlayPanel: OverlayPanel
    private var cancellables = Set<AnyCancellable>()
    private let menu: NSMenu

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.overlayPanel = OverlayPanel(appState: appState)
        self.menu = NSMenu()
        super.init()

        menu.delegate = self
        setupButton()
        buildMenu()
        observeState()
    }

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.title = " W "
        button.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        button.target = self
        button.action = #selector(statusBarClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func buildMenu() {
        let recordItem = NSMenuItem(title: "Toggle Recording", action: #selector(toggleRecording), keyEquivalent: "")
        recordItem.target = self
        menu.addItem(recordItem)

        menu.addItem(.separator())

        let shortcutItem = NSMenuItem(title: "Shortcut: \u{2325}D (Option+D)", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)

        if !appState.isSetUp {
            menu.addItem(.separator())
            let setupItem = NSMenuItem(title: "Run setup.sh to install Whisper", action: nil, keyEquivalent: "")
            setupItem.isEnabled = false
            menu.addItem(setupItem)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit WhisperFlow", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // Left-click toggles recording, right-click opens menu
    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
        } else {
            appState.toggleRecording()
        }
    }

    // Remove menu after it closes so left-click works again
    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    @objc private func toggleRecording() {
        appState.toggleRecording()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
            button.title = " ● REC "
            button.contentTintColor = .systemRed
        case .transcribing:
            button.title = " W ··· "
            button.contentTintColor = .secondaryLabelColor
        default:
            button.title = " W "
            button.contentTintColor = .labelColor
        }
    }
}
