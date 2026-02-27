import AppKit
import Combine
import SwiftUI

class StatusBarController {
    private let statusItem: NSStatusItem
    private let appState: AppState
    private let overlayPanel: OverlayPanel
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.overlayPanel = OverlayPanel(appState: appState)

        setupButton()
        setupMenu()
        observeState()
    }

    private func setupButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "WhisperFlow")
        image?.isTemplate = true
        button.image = image
    }

    private func setupMenu() {
        let menu = NSMenu()

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

        statusItem.menu = menu
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
        let symbolName: String
        switch state {
        case .recording:
            symbolName = "mic.fill"
        case .transcribing:
            symbolName = "waveform"
        default:
            symbolName = "mic.fill"
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        button.image = image

        if case .recording = state {
            button.contentTintColor = .systemRed
        } else {
            button.contentTintColor = nil
        }
    }

    @objc private func toggleRecording() {
        appState.toggleRecording()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
