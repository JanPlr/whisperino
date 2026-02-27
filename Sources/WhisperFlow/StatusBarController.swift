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

    /// Custom 5-bar waveform icon matching the app icon, drawn as a template image
    private static func makeIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let barWidth: CGFloat = 2.0
            let gap: CGFloat = 2.0
            let heights: [CGFloat] = [0.28, 0.52, 1.0, 0.52, 0.28]
            let totalW = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
            let originX = (rect.width - totalW) / 2
            let maxH = rect.height * 0.65

            NSColor.black.setFill()
            for (i, ratio) in heights.enumerated() {
                let h = max(barWidth, maxH * ratio)
                let x = originX + CGFloat(i) * (barWidth + gap)
                let y = (rect.height - h) / 2
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: h),
                             xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Red-tinted recording icon — filled circle with white bars inside
    private static func makeRecordingIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset: CGFloat = 1
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
            NSColor.black.setFill()
            circle.fill()

            let barWidth: CGFloat = 1.6
            let gap: CGFloat = 1.6
            let heights: [CGFloat] = [0.25, 0.45, 0.8, 0.45, 0.25]
            let totalW = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
            let originX = (rect.width - totalW) / 2
            let maxH = rect.height * 0.5

            NSColor.white.setFill()
            for (i, ratio) in heights.enumerated() {
                let h = max(barWidth, maxH * ratio)
                let x = originX + CGFloat(i) * (barWidth + gap)
                let y = (rect.height - h) / 2
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: h),
                             xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.makeIcon()
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

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
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
            button.image = Self.makeRecordingIcon()
            button.contentTintColor = .systemRed
        case .transcribing:
            let img = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
            img?.isTemplate = true
            button.image = img
            button.contentTintColor = nil
        default:
            button.image = Self.makeIcon()
            button.contentTintColor = nil
        }
    }
}
