import AppKit
import Combine

class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let appState: AppState
    private let overlayPanel: OverlayPanel
    private var cancellables = Set<AnyCancellable>()
    private let menu: NSMenu

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.overlayPanel = OverlayPanel(appState: appState)
        self.menu = NSMenu()
        super.init()

        setupButton()
        buildMenu()
        observeState()
    }

    // MARK: - Custom waveform icon

    private static func makeWaveformImage(height: CGFloat, barColor: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let barWidth: CGFloat = 1.6
            let gap: CGFloat = 2.4
            let barHeights: [CGFloat] = [0.30, 0.55, 1.0, 0.55, 0.30]
            let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * gap
            let startX = (rect.width - totalWidth) / 2
            let maxBarHeight = rect.height * 0.7

            barColor.setFill()
            for (i, ratio) in barHeights.enumerated() {
                let h = max(barWidth, maxBarHeight * ratio)
                let x = startX + CGFloat(i) * (barWidth + gap)
                let y = (rect.height - h) / 2
                let bar = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: h),
                                       xRadius: barWidth / 2, yRadius: barWidth / 2)
                bar.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Setup

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.makeWaveformImage(height: 18, barColor: .black)
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

    // MARK: - Actions

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            // Remove menu so left-click works again next time
            DispatchQueue.main.async { self.statusItem.menu = nil }
        } else {
            appState.toggleRecording()
        }
    }

    @objc private func toggleRecording() {
        appState.toggleRecording()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - State observation

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
            button.image = Self.makeWaveformImage(height: 18, barColor: .black)
            button.contentTintColor = .systemRed
        case .transcribing:
            let img = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
            img?.isTemplate = true
            button.image = img
            button.contentTintColor = nil
        default:
            button.image = Self.makeWaveformImage(height: 18, barColor: .black)
            button.contentTintColor = nil
        }
    }
}
