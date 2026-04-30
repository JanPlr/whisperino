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

    // Menu items we mutate dynamically based on app state.
    // For the two action items we use NSMenuItem.view = custom NSView so
    // we can render the gray shortcut text actually flush-right against
    // the menu edge (which keyEquivalent + attributedTitle can't do).
    private var dictationItem: NSMenuItem?
    private var aiModeItem: NSMenuItem?
    private var dictationView: HotkeyMenuItemView?
    private var aiModeView: HotkeyMenuItemView?
    private var setupItem: NSMenuItem?

    private func buildMenu() {
        let triggerLabel = store.settings.triggerKey.shortLabel

        // Dictation action with a custom view that draws icon · title · gray shortcut
        let dictView = HotkeyMenuItemView(
            title: "Start Dictation",
            shortcut: "hold \(triggerLabel)",
            image: NSImage(systemSymbolName: "waveform", accessibilityDescription: "Dictate")
        )
        dictView.onClick = { [weak self] in self?.toggleDictation() }
        let dict = NSMenuItem()
        dict.view = dictView
        menu.addItem(dict)
        dictationItem = dict
        dictationView = dictView

        // AI mode action — same custom view pattern
        let aiView = HotkeyMenuItemView(
            title: "Start AI Mode",
            shortcut: "\(triggerLabel) + ⇧",
            image: NSImage(systemSymbolName: "pencil", accessibilityDescription: "AI mode")
        )
        aiView.onClick = { [weak self] in self?.toggleAIMode() }
        let ai = NSMenuItem()
        ai.view = aiView
        menu.addItem(ai)
        aiModeItem = ai
        aiModeView = aiView

        // Setup-warning row — only shown if Whisper isn't installed
        let setup = NSMenuItem(title: "⚠︎  Whisper not installed — run setup.sh", action: nil, keyEquivalent: "")
        setup.isEnabled = false
        setup.isHidden = true
        menu.addItem(setup)
        setupItem = setup

        menu.addItem(.separator())

        let copyLastItem = NSMenuItem(title: "Copy Last Transcription", action: #selector(copyLastTranscription), keyEquivalent: "")
        copyLastItem.target = self
        copyLastItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Copy last")
        menu.addItem(copyLastItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit Whisperino", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit")
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        let triggerLabel = store.settings.triggerKey.shortLabel

        // Reflect current state in the two custom-view action items
        switch appState.state {
        case .recording, .paused:
            dictationView?.update(title: "Stop & Submit", shortcut: "release \(triggerLabel) or ↩", enabled: true)
            if appState.isInstructionMode {
                aiModeView?.update(title: "AI Mode is active", shortcut: "", enabled: false)
            } else {
                aiModeView?.update(title: "Switch to AI Mode", shortcut: "add ⇧", enabled: true)
            }
        case .transcribing, .refining:
            dictationView?.update(title: "Working…", shortcut: "", enabled: false)
            aiModeView?.update(title: "Working…", shortcut: "", enabled: false)
        default:
            dictationView?.update(title: "Start Dictation", shortcut: "hold \(triggerLabel)", enabled: true)
            aiModeView?.update(title: "Start AI Mode", shortcut: "\(triggerLabel) + ⇧", enabled: true)
        }

        // Show setup warning only when Whisper isn't installed
        setupItem?.isHidden = appState.isSetUp
    }

    func menuDidClose(_ menu: NSMenu) {
    }

    @objc private func toggleRecording() {
        appState.toggleRecording()
    }

    /// Dictation button: start dictation when idle, submit when recording.
    @objc private func toggleDictation() {
        switch appState.state {
        case .recording, .paused:
            appState.toggleRecording()  // submits in current mode
        default:
            appState.hotkeyToggle()  // starts in dictation mode
        }
    }

    /// AI mode button: start AI mode when idle, upgrade to AI mode when
    /// already recording in dictation, no-op when AI mode is already active
    /// (the dictation button stops it).
    @objc private func toggleAIMode() {
        switch appState.state {
        case .recording, .paused:
            if !appState.isInstructionMode {
                appState.upgradeToInstructionMode()
            }
        default:
            appState.instructionHotkeyToggle()
        }
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

// MARK: - Custom menu item view (for icon · title · trailing-aligned shortcut)

/// Renders a menu item that mirrors macOS's standard layout but with a
/// non-keyEquivalent shortcut hint right-aligned at the trailing edge.
/// We need this because Fn isn't a real `keyEquivalent`, and
/// `attributedTitle` with a tab stop can't actually flush-right against
/// the menu's dynamic edge.
final class HotkeyMenuItemView: NSView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let shortcutField = NSTextField(labelWithString: "")
    private var isMouseInside = false
    private var isItemEnabled = true

    var onClick: (() -> Void)?

    init(title: String, shortcut: String, image: NSImage?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        autoresizingMask = [.width]
        wantsLayer = true

        // Icon
        iconView.image = image
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        iconView.contentTintColor = .labelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // Title (left-aligned, single line)
        titleField.font = .menuFont(ofSize: 0)
        titleField.stringValue = title
        titleField.textColor = .labelColor
        titleField.usesSingleLineMode = true
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        // Shortcut (right-aligned, gray)
        shortcutField.font = .menuFont(ofSize: 0)
        shortcutField.stringValue = shortcut
        shortcutField.textColor = .secondaryLabelColor
        shortcutField.alignment = .right
        shortcutField.usesSingleLineMode = true
        shortcutField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shortcutField)

        // Match standard menu item paddings: 14pt icon-left, 8pt icon-title,
        // 14pt trailing inset for shortcut, ≥16pt minimum gap title↔shortcut
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            shortcutField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            shortcutField.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutField.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleField.trailingAnchor, constant: 16
            ),
        ])

        // Hover tracking → highlight on enter, restore on exit
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Update the rendered title / shortcut / enabled state. Called from
    /// `menuWillOpen` to reflect the current recording state.
    func update(title: String, shortcut: String, enabled: Bool) {
        titleField.stringValue = title
        shortcutField.stringValue = shortcut
        isItemEnabled = enabled
        applyColors()
    }

    private func applyColors() {
        let baseAlpha: CGFloat = isItemEnabled ? 1.0 : 0.4
        if isMouseInside && isItemEnabled {
            // Selected/highlighted → standard system colors invert
            titleField.textColor = .selectedMenuItemTextColor
            shortcutField.textColor = NSColor.selectedMenuItemTextColor.withAlphaComponent(0.7)
            iconView.contentTintColor = .selectedMenuItemTextColor
        } else {
            titleField.textColor = NSColor.labelColor.withAlphaComponent(baseAlpha)
            shortcutField.textColor = NSColor.secondaryLabelColor.withAlphaComponent(baseAlpha)
            iconView.contentTintColor = NSColor.labelColor.withAlphaComponent(baseAlpha)
        }
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        applyColors()
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        applyColors()
    }

    override func mouseUp(with event: NSEvent) {
        guard isItemEnabled else { return }
        onClick?()
        // Close the menu so it dismisses like a standard click would
        enclosingMenuItem?.menu?.cancelTracking()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isMouseInside, isItemEnabled else { return }
        // Match the system's selection background (rounded inset rect)
        NSColor.selectedContentBackgroundColor.setFill()
        let highlightRect = bounds.insetBy(dx: 5, dy: 0)
        NSBezierPath(roundedRect: highlightRect, xRadius: 4, yRadius: 4).fill()
    }
}
