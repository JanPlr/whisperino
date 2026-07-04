import AppKit
import Combine

class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let appState: AppState
    private let overlayPanel: OverlayPanel
    private var cancellables = Set<AnyCancellable>()
    private let menu: NSMenu
    private let store = SettingsStore.shared

    /// Small blue dot pinned to the icon's top-right corner, shown only when
    /// the updater has found a newer release. It's a sibling view (not baked
    /// into the icon) so the waveform stays a template image that auto-adapts
    /// to the light/dark menu bar, while the dot stays its own solid blue.
    private let updateBadge: NSView = {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isHidden = true
        return dot
    }()

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.overlayPanel = OverlayPanel(appState: appState)
        self.menu = NSMenu()
        super.init()

        menu.delegate = self
        // We toggle isEnabled by hand (updater states, setup warning) -
        // autoenablesItems would override that on every open.
        menu.autoenablesItems = false
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

        // 6pt blue dot in the top-right corner of the button.
        button.addSubview(updateBadge)
        NSLayoutConstraint.activate([
            updateBadge.widthAnchor.constraint(equalToConstant: 6),
            updateBadge.heightAnchor.constraint(equalToConstant: 6),
            updateBadge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
            updateBadge.topAnchor.constraint(equalTo: button.topAnchor, constant: 3),
        ])
    }

    /// Reflect the updater's current status on the menu-bar badge.
    private func refreshUpdateBadge() {
        if case .available = UpdateChecker.shared.status {
            updateBadge.isHidden = false
        } else {
            updateBadge.isHidden = true
        }
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
    private var updateItem: NSMenuItem?

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

        // AI mode action - same custom view pattern
        let aiView = HotkeyMenuItemView(
            title: "Talk to your screen",
            shortcut: "\(triggerLabel) + ⇧",
            image: NSImage(systemSymbolName: "pencil", accessibilityDescription: "Talk to your screen")
        )
        aiView.onClick = { [weak self] in self?.toggleAIMode() }
        let ai = NSMenuItem()
        ai.view = aiView
        menu.addItem(ai)
        aiModeItem = ai
        aiModeView = aiView

        // Setup-warning row - only shown if Whisper isn't installed
        let setup = NSMenuItem(title: "⚠︎  Whisper not installed - run setup.sh", action: nil, keyEquivalent: "")
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

        let update = NSMenuItem(title: "Check for Updates…", action: #selector(updateAction), keyEquivalent: "")
        update.target = self
        update.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Updates")
        menu.addItem(update)
        updateItem = update

        let quitItem = NSMenuItem(title: "Quit Whisperino", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit")
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        let triggerLabel = store.settings.triggerKey.shortLabel

        // Reflect current state in the two custom-view action items
        switch appState.state {
        case .recording:
            dictationView?.update(title: "Stop & Submit", shortcut: "release \(triggerLabel) or ↩", enabled: true)
            if appState.isInstructionMode {
                aiModeView?.update(title: "Talk to your screen is active", shortcut: "", enabled: false)
            } else {
                aiModeView?.update(title: "Switch to Talk to your screen", shortcut: "add ⇧", enabled: true)
            }
        case .transcribing, .refining:
            dictationView?.update(title: "Working…", shortcut: "", enabled: false)
            aiModeView?.update(title: "Working…", shortcut: "", enabled: false)
        default:
            dictationView?.update(title: "Start Dictation", shortcut: "hold \(triggerLabel)", enabled: true)
            aiModeView?.update(title: "Talk to your screen", shortcut: "\(triggerLabel) + ⇧", enabled: true)
        }

        // Show setup warning only when Whisper isn't installed
        setupItem?.isHidden = appState.isSetUp

        // Reflect updater state
        switch UpdateChecker.shared.status {
        case .idle:
            updateItem?.title = "Check for Updates…"
            updateItem?.isEnabled = true
        case .checking:
            updateItem?.title = "Checking for Updates…"
            updateItem?.isEnabled = false
        case .available(let release):
            updateItem?.title = "Update to v\(release.version)…"
            updateItem?.isEnabled = true
        case .downloading:
            updateItem?.title = "Downloading Update…"
            updateItem?.isEnabled = false
        }
    }

    /// Dictation button: start dictation when idle, submit when recording.
    @objc private func toggleDictation() {
        switch appState.state {
        case .recording:
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
        case .recording:
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

    @objc private func updateAction() {
        switch UpdateChecker.shared.status {
        case .available(let release):
            UpdateChecker.shared.offerInstall(release)
        case .idle:
            UpdateChecker.shared.checkManually()
        case .checking, .downloading:
            break
        }
    }

    private func observeState() {
        appState.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                self.updateStatusIcon(for: state)
                switch state {
                case .idle:
                    self.overlayPanel.dismiss()
                case .dismissing:
                    // Keep the panel up - SwiftUI is playing the
                    // shrink-to-center animation inside it. The switch
                    // to .idle right after takes the panel down.
                    break
                case .cancelled:
                    // Let cancel animation play, then dismiss, then go idle
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.overlayPanel.dismiss()
                        // Set idle after panel is fully gone
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            guard case .cancelled = self?.appState.state else { return }
                            self?.appState.suppressStateAnimation = true
                            self?.appState.state = .idle
                            DispatchQueue.main.async {
                                self?.appState.suppressStateAnimation = false
                            }
                        }
                    }
                default:
                    self.overlayPanel.present()
                }
            }
            .store(in: &cancellables)

        // Show / hide the menu-bar badge as the updater's status changes
        // (background check finds a release, user starts the download, etc.).
        NotificationCenter.default.publisher(for: UpdateChecker.statusDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshUpdateBadge() }
            .store(in: &cancellables)
        refreshUpdateBadge()
    }

    private func updateStatusIcon(for state: TranscriptionState) {
        guard let button = statusItem.button else { return }
        switch state {
        case .recording:
            // Red is explicitly colored - not a template
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
        // Assign dynamic system colors *directly* — never via
        // `.withAlphaComponent`, which snapshots the color against
        // whatever `NSAppearance.current` is at call time (during
        // `menuWillOpen` that's off the draw cycle and unreliable),
        // freezing it in the wrong light/dark variant. Left as-is the
        // fields resolve `.labelColor` etc. at draw time against the
        // menu's real appearance. Disabled dimming rides the view's
        // `alphaValue` instead of being baked into the color.
        if isMouseInside && isItemEnabled {
            // Selected/highlighted → standard system colors invert
            titleField.textColor = .selectedMenuItemTextColor
            shortcutField.textColor = .selectedMenuItemTextColor
            shortcutField.alphaValue = 0.7
            iconView.contentTintColor = .selectedMenuItemTextColor
        } else {
            titleField.textColor = .labelColor
            shortcutField.textColor = .secondaryLabelColor
            shortcutField.alphaValue = 1.0
            iconView.contentTintColor = .labelColor
        }
        alphaValue = isItemEnabled ? 1.0 : 0.4
        needsDisplay = true
    }

    /// Menu custom views don't always re-resolve dynamic colors when the
    /// host switches light/dark — re-apply so the labels track the menu.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
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
