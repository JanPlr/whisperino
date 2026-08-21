import AppKit
import Combine
import SwiftUI

class OverlayPanel {
    private let panel: NSPanel
    /// A separate, notch-sized window remains available while the main overlay
    /// is hidden. Keeping this hit target tiny prevents a transparent 420pt
    /// panel from swallowing clicks in the app underneath it.
    private let notchHotspotPanel: NSPanel
    private var notchHoverView: NotchHoverTargetView?
    private let appState: AppState
    private var isVisible = false
    private var dismissGeneration = 0
    private var cancellables = Set<AnyCancellable>()
    private var trackTimer: Timer?
    /// The origin we last asked the panel to move to. Compared against (rather
    /// than the live frame) so the 60fps tracker doesn't restart an in-flight
    /// slide every tick - during an animator move `panel.frame.origin` reports
    /// the intermediate value, not the destination.
    private var targetOrigin: NSPoint?
    private var screenChangeObservers: [NSObjectProtocol] = []

    /// Base panel height with no picker expanded. The transparent window is
    /// taller than the listening pill so native assistant cards can grow down
    /// from the notch without resizing the NSPanel mid-transition.
    private static let baseHeight: CGFloat = 380
    private static let panelWidth: CGFloat = 420
    /// A centered virtual island competes with macOS's microphone privacy
    /// indicator on crowded external-display menu bars. Keep every external
    /// state on one slightly left-biased anchor so the system indicator has a
    /// reliable clear lane without any movement between idle and recording.
    private static let externalIslandHorizontalOffset: CGFloat = -28

    init(appState: AppState) {
        self.appState = appState
        notchHotspotPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.baseHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Sit above ordinary and floating windows so the pill is never
        // buried behind another app's panels. `.fullScreenAuxiliary` +
        // `.canJoinAllSpaces` (below) carry it over fullscreen apps and
        // across Spaces; the high level keeps it on top everywhere else.
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // `.none` - we run our own alpha fade in present()/dismiss(). The
        // default `.utilityWindow` adds a separate OS-level fade that
        // overlaps ours and shows a faint gray rectangle for a frame or
        // two until both animations settle.
        panel.animationBehavior = .none

        let hostingView = NSHostingView(
            rootView: OverlayView(appState: appState)
        )
        hostingView.wantsLayer = true
        // `nil`, not `.clear` - `.clear` is still a CGColor (transparent
        // black) and on some macOS versions composites as a one-pixel
        // gray fringe under the SwiftUI shadow. `nil` means "no layer
        // background at all" which is what we actually want.
        hostingView.layer?.backgroundColor = nil
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView

        configureNotchHotspot()

        // Resize panel whenever picker visibility or device count changes.
        // Uses the exact same formula as OverlayView.panelContentHeight.
        Publishers.CombineLatest(
            appState.$showingInputPicker.removeDuplicates(),
            appState.$inputDevices.map(\.count).removeDuplicates()
        )
        .sink { [weak self] pickerShowing, deviceCount in
            self?.updatePanelHeight(pickerShowing: pickerShowing, deviceCount: deviceCount)
        }
        .store(in: &cancellables)

    }

    deinit {
        trackTimer?.invalidate()
        for observer in screenChangeObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// VoiceOS-style direct manipulation: moving behind the physical notch
    /// gives tactile feedback, and clicking starts a normal dictation take.
    /// Hover widens the hardware silhouette and reveals a small activity lip,
    /// matching the legible-but-attached VoiceOS treatment.
    private func configureNotchHotspot() {
        notchHotspotPanel.level = .screenSaver
        notchHotspotPanel.isOpaque = false
        notchHotspotPanel.backgroundColor = .clear
        notchHotspotPanel.hasShadow = false
        notchHotspotPanel.hidesOnDeactivate = false
        notchHotspotPanel.isMovableByWindowBackground = false
        notchHotspotPanel.animationBehavior = .none
        notchHotspotPanel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
        ]
        notchHotspotPanel.acceptsMouseMovedEvents = true

        let hoverView = NotchHoverTargetView { [weak self] in
            self?.appState.toggleRecording()
        }
        notchHoverView = hoverView
        notchHotspotPanel.contentView = hoverView

        // The discovery lip belongs only to the idle hardware notch. During a
        // take or transcription, the live surface already communicates state;
        // revealing another hover layer on top made the notch look duplicated.
        appState.$state
            .map { state in
                if case .idle = state { return true }
                return false
            }
            .removeDuplicates()
            .sink { [weak hoverView] enabled in
                hoverView?.setInteractionEnabled(enabled)
            }
            .store(in: &cancellables)

        positionNotchHotspot()
        if notchHotspotPanel.contentView != nil {
            notchHotspotPanel.orderFront(nil)
        }

        let center = NotificationCenter.default
        screenChangeObservers.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.positionNotchHotspot() }
        )
        screenChangeObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.positionNotchHotspot() }
        )
    }

    private func positionNotchHotspot() {
        guard let screen = preferredOverlayScreen() else {
            notchHotspotPanel.orderOut(nil)
            return
        }

        let hasNotch = Self.hasPhysicalNotch(screen)
        let isExternal = Self.isExternalDisplay(screen)
        guard hasNotch || isExternal else {
            notchHotspotPanel.orderOut(nil)
            return
        }

        let width: CGFloat
        let height: CGFloat
        if isExternal {
            // A virtual, always-visible top-edge island. The panel is larger
            // than the resting silhouette so the shell can grow on hover
            // without moving or resizing the NSWindow hit target.
            notchHoverView?.setStyle(.externalTopEdge)
            width = 244
            height = 36
        } else {
            notchHoverView?.setStyle(.physicalNotch)
            let inset = max(screen.safeAreaInsets.top, 28)
            let hardwareWidth = Self.physicalNotchWidth(on: screen)
            // Hover is only a slight physical expansion of the real notch.
            width = hardwareWidth + 36
            height = inset + 16
        }
        notchHotspotPanel.setFrame(
            NSRect(
                x: screen.frame.midX - width / 2
                    + (isExternal ? Self.externalIslandHorizontalOffset : 0),
                y: screen.frame.maxY - height,
                width: width,
                height: height
            ),
            display: true
        )
        notchHotspotPanel.orderFront(nil)
    }

    /// The pill rides a `.canJoinAllSpaces` panel, so it follows the user
    /// across Spaces - but its frame is set for whatever window was front when
    /// it appeared. Waiting for an activeSpaceDidChange notification to move it
    /// left a visible beat where the pill sat at the old coordinates (covering
    /// the new Space's Dock) before jumping. Instead, while the pill is up we
    /// re-anchor every frame: the instant a new Space lands and the frontmost
    /// window resolves, the very next tick snaps the pill into place - no
    /// perceptible lag - and it also tracks the target window being moved or
    /// resized mid-recording.
    private func startTracking() {
        trackTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.positionAtNotch()
        }
        // .common so it keeps firing during menu/scroll tracking too.
        RunLoop.main.add(timer, forMode: .common)
        trackTimer = timer
    }

    private func stopTracking() {
        trackTimer?.invalidate()
        trackTimer = nil
        targetOrigin = nil
    }

    func present() {
        guard !isVisible else { return }
        // Re-enumerate input devices now, while still hidden (the sink's
        // updatePanelHeight no-ops until isVisible). Recording is starting,
        // so the CoreAudio HAL is warm and returns the SAME device count the
        // first mic-tap will see. The launch-time pre-load can run against a
        // cold HAL with a different count; reserving height off that stale
        // count, then having the first tap re-count, is what resized the
        // panel mid-open - the "jump". Refreshing here makes the reserved
        // height match what the picker will actually show.
        appState.refreshInputDevices()
        isVisible = true
        dismissGeneration += 1
        // Size to the full reserved height (including the picker's space)
        // BEFORE showing. dismiss() trims the frame back to baseHeight, so
        // without this the panel would appear too short and the first
        // state change (e.g. the first mic tap opening the picker) would
        // grow it mid-animation - the visible "jump" on first open.
        let fullHeight = panelHeight(
            pickerShowing: appState.showingInputPicker,
            deviceCount: appState.inputDevices.count
        )
        if abs(panel.frame.height - fullHeight) > 1 {
            var frame = panel.frame
            frame.size.height = fullHeight
            panel.setFrame(frame, display: false)
        }
        positionAtNotch(instant: true)
        startTracking()
        // Instant - the pill should be there the moment recording
        // starts. Any fade-in here reads as input lag.
        panel.alphaValue = 1
        panel.orderFront(nil)
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        stopTracking()
        dismissGeneration += 1
        let gen = dismissGeneration

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.dismissGeneration == gen else { return }
            self.panel.orderOut(nil)

            let topY = self.panel.frame.maxY
            let baseFrame = NSRect(
                x: self.panel.frame.origin.x,
                y: topY - Self.baseHeight,
                width: self.panel.frame.width,
                height: Self.baseHeight
            )
            self.panel.setFrame(baseFrame, display: false)
        })
    }

    /// Must match OverlayView.pickerExtraHeight exactly
    private static func pickerExtraHeight(deviceCount: Int) -> CGFloat {
        let count = max(deviceCount, 1)
        // 28 header + one row per device + 26 for the "Follow system default"
        // row + 12 padding + 1 hairline. Must match OverlayView.
        return 28 + CGFloat(count) * 26 + 26 + 12 + 1
    }

    private func panelHeight(
        pickerShowing: Bool,
        deviceCount: Int
    ) -> CGFloat {
        // Always include picker height so the panel never resizes for picker
        // open/close. SwiftUI handles the visual animation within the fixed panel.
        // This eliminates NSPanel ↔ SwiftUI animation desync entirely.
        Self.baseHeight + Self.pickerExtraHeight(deviceCount: deviceCount)
    }

    private func updatePanelHeight(
        pickerShowing: Bool,
        deviceCount: Int
    ) {
        guard isVisible else { return }
        let newHeight = panelHeight(
            pickerShowing: pickerShowing,
            deviceCount: deviceCount
        )
        guard abs(panel.frame.height - newHeight) > 1 else { return }

        let isCollapsing = newHeight < panel.frame.height

        // Keep the notch/top edge pinned while transparent capacity changes.
        let topY = panel.frame.maxY
        let newFrame = NSRect(
            x: panel.frame.origin.x,
            y: topY - newHeight,
            width: panel.frame.width,
            height: newHeight
        )

        if isCollapsing {
            // Shrinking: SwiftUI's spring is animating the dark
            // container down inside the panel. If we shrink the panel
            // immediately we'd clip the in-flight spring. Wait for the
            // spring to settle, then trim the (transparent) excess.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self,
                      // Re-check size on fire - another resize may have
                      // overtaken us in the meantime.
                      abs(self.panel.frame.height - newHeight) > 1 else { return }
                self.panel.setFrame(newFrame, display: true)
            }
        } else {
            // Growing: snap the panel to the new size right away. The
            // transparent area above the dark container is invisible,
            // so the user sees only SwiftUI's spring expanding the
            // pill - same feel as the input device picker, which
            // doesn't resize the panel either.
            panel.setFrame(newFrame, display: true)
        }
    }

    private func positionAtNotch(instant: Bool = false) {
        guard let target = computeTargetOrigin() else { return }
        targetOrigin = target
        if instant {
            // Initial appearance (or forced): snap, no glide-in.
            panel.setFrameOrigin(target)
        } else {
            easeOriginTowardTarget()
        }
    }

    /// A connected external display owns Whisperino's single overlay. This
    /// keeps the live surface beside the work being dictated and avoids a
    /// duplicate island on the MacBook display. Without an external display,
    /// the physical MacBook notch remains the preferred anchor.
    private func computeTargetOrigin() -> NSPoint? {
        let panelSize = panel.frame.size
        guard let screen = preferredOverlayScreen() else { return nil }
        let hasNotch = Self.hasPhysicalNotch(screen)
        let isExternal = Self.isExternalDisplay(screen)
        let usesTopEdgeSurface = hasNotch || isExternal
        let notchInset = usesTopEdgeSurface
            ? (hasNotch ? max(screen.safeAreaInsets.top, 28) : 28)
            : 0
        if appState.overlayHasPhysicalNotch != hasNotch {
            appState.overlayHasPhysicalNotch = hasNotch
        }
        if appState.overlayUsesTopEdgeSurface != usesTopEdgeSurface {
            appState.overlayUsesTopEdgeSurface = usesTopEdgeSurface
        }
        if abs(appState.overlayNotchInset - notchInset) > 0.5 {
            appState.overlayNotchInset = notchInset
        }
        let centerWidth: CGFloat = hasNotch
            ? Self.physicalNotchWidth(on: screen)
            // The idle discovery tab remains 188pt wide, but once recording
            // starts the virtual "hardware" center contracts to 160pt. With
            // two fixed 32pt control wings the full live surface is 224pt,
            // buying 18pt of clearance per side versus the former 260pt
            // surface without introducing any horizontal panel movement.
            : (isExternal ? 160 : 170)
        if abs(appState.overlayPhysicalNotchWidth - centerWidth) > 0.5 {
            appState.overlayPhysicalNotchWidth = centerWidth
        }
        let topEdge = usesTopEdgeSurface ? screen.frame.maxY : screen.visibleFrame.maxY - 8
        let x = screen.frame.midX - panelSize.width / 2
            + (isExternal ? Self.externalIslandHorizontalOffset : 0)
        let clampedX = min(
            max(x, screen.frame.minX + 8),
            screen.frame.maxX - panelSize.width - 8
        )
        return NSPoint(x: clampedX, y: topEdge - panelSize.height)
    }

    private func preferredOverlayScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let activeScreen: NSScreen? = {
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let window = ScreenCapture.focusedWindowFrame(pid: pid)
            if let window,
               let hit = screens.first(where: {
                   $0.frame.contains(CGPoint(x: window.midX, y: window.midY))
               }) {
                return hit
            }
            return NSScreen.main ?? screens.first
        }()

        let externalScreens = screens.filter(Self.isExternalDisplay)
        if !externalScreens.isEmpty {
            if let activeScreen,
               externalScreens.contains(where: { $0 === activeScreen }) {
                return activeScreen
            }
            if let main = NSScreen.main, Self.isExternalDisplay(main) {
                return main
            }
            return externalScreens.first
        }

        return screens.first(where: Self.hasPhysicalNotch) ?? activeScreen
    }

    private static func isExternalDisplay(_ screen: NSScreen) -> Bool {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value else {
            return false
        }
        return CGDisplayIsBuiltin(displayID) == 0
    }

    private static func hasPhysicalNotch(_ screen: NSScreen) -> Bool {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value,
              CGDisplayIsBuiltin(displayID) != 0 else { return false }
        return screen.safeAreaInsets.top > 0
            || screen.auxiliaryTopLeftArea != nil
            || screen.auxiliaryTopRightArea != nil
    }

    private static func physicalNotchWidth(on screen: NSScreen) -> CGFloat {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return 210 }
        return max(170, right.minX - left.maxX)
    }

    /// Move the panel one frame's worth toward `targetOrigin`. Driven by the
    /// 60fps tracker, this produces a quick, smooth glide when the target jumps
    /// (Space/app switch) and a tight follow for small deltas - all via plain
    /// setFrameOrigin, so there's no NSWindow-animator state to fight and no
    /// feedback loop with the tracker. Snaps the last sub-pixel to settle.
    private func easeOriginTowardTarget() {
        guard let target = targetOrigin else { return }
        let cur = panel.frame.origin
        let dx = target.x - cur.x
        let dy = target.y - cur.y
        if abs(dx) < 0.75, abs(dy) < 0.75 {
            if dx != 0 || dy != 0 { panel.setFrameOrigin(target) }
            return
        }
        // ~0.32/frame ≈ settles in ~7 frames (~120ms) at 60fps: fast but eased.
        let f: CGFloat = 0.32
        panel.setFrameOrigin(NSPoint(x: cur.x + dx * f, y: cur.y + dy * f))
    }

}

/// AppKit owns the idle notch hit target so it remains clickable even while
/// SwiftUI's recording surface is not on screen.
private final class NotchHoverTargetView: NSView {
    enum Style: Equatable {
        case physicalNotch
        case externalTopEdge
    }

    private let onClick: () -> Void
    private let shellLayer = CAShapeLayer()
    private let innerBloomLayer = CAGradientLayer()
    private let innerBloomMaskLayer = CAShapeLayer()
    private let hoverContourLayer = CAShapeLayer()
    private var trackingArea: NSTrackingArea?
    private var hovering = false
    private var interactionEnabled = true
    private var lastHapticTime: TimeInterval = 0
    private var style: Style = .physicalNotch

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        shellLayer.fillColor = NSColor.black.cgColor
        layer?.addSublayer(shellLayer)

        // VoiceOS-style broad bloom inside the lower part of the black
        // surface. The thin outer stroke alone is almost invisible against a
        // bright menu bar; this soft vertical falloff makes hover legible.
        innerBloomLayer.colors = [
            NSColor.white.withAlphaComponent(0.27).cgColor,
            NSColor.white.withAlphaComponent(0.11).cgColor,
            NSColor.clear.cgColor,
        ]
        innerBloomLayer.locations = [0, 0.34, 1]
        innerBloomLayer.startPoint = CGPoint(x: 0.5, y: 0)
        innerBloomLayer.endPoint = CGPoint(x: 0.5, y: 1)
        innerBloomLayer.mask = innerBloomMaskLayer
        innerBloomLayer.opacity = 0
        layer?.addSublayer(innerBloomLayer)

        hoverContourLayer.fillColor = NSColor.clear.cgColor
        hoverContourLayer.strokeColor = NSColor.white.withAlphaComponent(0.24).cgColor
        hoverContourLayer.lineWidth = 1
        hoverContourLayer.lineJoin = .round
        hoverContourLayer.shadowColor = NSColor.white.cgColor
        hoverContourLayer.shadowOpacity = 0.22
        hoverContourLayer.shadowRadius = 8
        hoverContourLayer.shadowOffset = .zero
        hoverContourLayer.opacity = 0
        layer?.addSublayer(hoverContourLayer)
        alphaValue = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Start dictation from notch")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setStyle(_ style: Style) {
        guard self.style != style else { return }
        self.style = style
        hovering = false
        stopHoverGlow()
        layer?.removeAllAnimations()
        innerBloomLayer.opacity = 0
        hoverContourLayer.opacity = 0
        alphaValue = interactionEnabled && style == .externalTopEdge ? 1 : 0
        setAccessibilityLabel(
            style == .externalTopEdge
                ? "Start dictation from top edge"
                : "Start dictation from notch"
        )
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        shellLayer.frame = bounds
        innerBloomLayer.frame = bounds
        innerBloomMaskLayer.frame = bounds
        hoverContourLayer.frame = bounds
        updateShellGeometry(animated: false)
    }

    private func shellRect(hovered: Bool) -> CGRect {
        switch style {
        case .physicalNotch:
            return CGRect(
                x: bounds.minX,
                y: bounds.minY + 10,
                width: bounds.width,
                height: max(0, bounds.height - 10)
            )
        case .externalTopEdge:
            let width = min(bounds.width, hovered ? 226 : 188)
            let depth: CGFloat = hovered ? 20 : 8
            return CGRect(
                x: bounds.midX - width / 2,
                y: bounds.maxY - depth,
                width: width,
                height: depth
            )
        }
    }

    private func updateShellGeometry(animated: Bool) {
        let rect = shellRect(hovered: hovering)
        setPath(hoverShellPath(in: rect), on: shellLayer, animated: animated, key: "shellMorph")
        setPath(hoverShellPath(in: rect), on: innerBloomMaskLayer, animated: animated, key: "bloomMorph")
        // Leave the display-edge segment open. Closing this path draws a pale
        // one-pixel line across the absolute top of the screen.
        setPath(hoverOpenContourPath(in: rect), on: hoverContourLayer, animated: animated, key: "contourMorph")
    }

    private func setPath(
        _ path: CGPath,
        on shapeLayer: CAShapeLayer,
        animated: Bool,
        key: String
    ) {
        let oldPath = shapeLayer.presentation()?.path ?? shapeLayer.path
        shapeLayer.path = path
        guard animated, let oldPath else { return }
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = oldPath
        animation.toValue = path
        animation.duration = 0.18
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shapeLayer.add(animation, forKey: key)
    }

    private func hoverShellPath(in rect: CGRect) -> CGPath {
        // Match `NativeNotchShape` in OverlayView: the panel begins slightly
        // wider at the menu-bar edge, then reverse-curves inward into the
        // body. Hover and live transcription must read as the same object.
        let topRadius: CGFloat = min(10, rect.width * 0.15, rect.height * 0.42)
        let bottomRadius: CGFloat = min(14, max(1, rect.height - topRadius))
        let bodyLeft = rect.minX + topRadius
        let bodyRight = rect.maxX - topRadius
        let path = CGMutablePath()

        // AppKit's y-axis points upward: maxY is the display's top edge.
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bodyLeft, y: rect.maxY - topRadius),
            control: CGPoint(x: bodyLeft, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: bodyLeft, y: rect.minY + bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: bodyLeft + bottomRadius, y: rect.minY),
            control: CGPoint(x: bodyLeft, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: bodyRight - bottomRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: bodyRight, y: rect.minY + bottomRadius),
            control: CGPoint(x: bodyRight, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: bodyRight, y: rect.maxY - topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: bodyRight, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }

    private func hoverOpenContourPath(in rect: CGRect) -> CGPath {
        let topRadius: CGFloat = min(10, rect.width * 0.15, rect.height * 0.42)
        let bottomRadius: CGFloat = min(14, max(1, rect.height - topRadius))
        let bodyLeft = rect.minX + topRadius
        let bodyRight = rect.maxX - topRadius
        let path = CGMutablePath()

        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bodyLeft, y: rect.maxY - topRadius),
            control: CGPoint(x: bodyLeft, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: bodyLeft, y: rect.minY + bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: bodyLeft + bottomRadius, y: rect.minY),
            control: CGPoint(x: bodyLeft, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: bodyRight - bottomRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: bodyRight, y: rect.minY + bottomRadius),
            control: CGPoint(x: bodyRight, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: bodyRight, y: rect.maxY - topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: bodyRight, y: rect.maxY)
        )
        return path
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeAlways,
                .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        beginHoverIfNeeded()
    }

    /// Transparent, non-activating panels can occasionally begin receiving
    /// movement without AppKit first delivering `mouseEntered`. Treat the
    /// first movement as the same user gesture so the haptic is reliable.
    override func mouseMoved(with event: NSEvent) {
        beginHoverIfNeeded()
    }

    private func beginHoverIfNeeded() {
        guard interactionEnabled, !hovering else { return }
        hovering = true
        performHoverHaptic()
        updateShellGeometry(animated: true)
        startHoverGlow()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        innerBloomLayer.opacity = 1
        hoverContourLayer.opacity = 1
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateShellGeometry(animated: true)
        stopHoverGlow()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        innerBloomLayer.opacity = 0
        hoverContourLayer.opacity = 0
        CATransaction.commit()
        guard style == .physicalNotch else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard interactionEnabled else { return }
        guard event.buttonNumber == 0 else { return }
        // A second, firmer confirmation distinguishes the click that starts a
        // take from merely discovering the notch hit target on hover.
        performClickHaptic()
        onClick()
    }

    /// One deliberate, firm native tick. AppKit exposes patterns rather than
    /// an intensity scalar; `.generic` is more pronounced than `.levelChange`
    /// while preserving the single-pulse feel (no accidental double haptic).
    private func performHoverHaptic() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHapticTime >= 0.28 else { return }
        lastHapticTime = now

        NSHapticFeedbackManager.defaultPerformer.perform(
            .generic,
            performanceTime: .now
        )
    }

    private func performClickHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .generic,
            performanceTime: .now
        )
        lastHapticTime = ProcessInfo.processInfo.systemUptime
    }

    func setInteractionEnabled(_ enabled: Bool) {
        interactionEnabled = enabled
        hovering = false
        stopHoverGlow()
        layer?.removeAllAnimations()
        innerBloomLayer.opacity = 0
        hoverContourLayer.opacity = 0
        alphaValue = enabled && style == .externalTopEdge ? 1 : 0
        updateShellGeometry(animated: false)
    }

    private func startHoverGlow() {
        guard innerBloomLayer.animation(forKey: "bloomBreathe") == nil else { return }

        let bloomBreathe = CABasicAnimation(keyPath: "opacity")
        bloomBreathe.fromValue = 0.78
        bloomBreathe.toValue = 1.0
        bloomBreathe.duration = 2.0
        bloomBreathe.autoreverses = true
        bloomBreathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bloomBreathe.repeatCount = .infinity
        innerBloomLayer.add(bloomBreathe, forKey: "bloomBreathe")

        let edgeBreathe = CABasicAnimation(keyPath: "opacity")
        edgeBreathe.fromValue = 0.82
        edgeBreathe.toValue = 1.0
        edgeBreathe.duration = 2.0
        edgeBreathe.autoreverses = true
        edgeBreathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        edgeBreathe.repeatCount = .infinity
        hoverContourLayer.add(edgeBreathe, forKey: "edgeBreathe")
    }

    private func stopHoverGlow() {
        innerBloomLayer.removeAnimation(forKey: "bloomBreathe")
        hoverContourLayer.removeAnimation(forKey: "edgeBreathe")
    }

    /// Used only by the environment-gated visual QA window so it renders the
    /// production AppKit hover layers rather than a hand-built approximation.
    func revealForVisualQA() {
        beginHoverIfNeeded()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Production-layer factory for `NotchVisualQAPreview`. Returning `NSView`
/// keeps the private hover implementation out of the rest of the app surface.
func makeNotchHoverVisualQAView() -> NSView {
    let view = NotchHoverTargetView(onClick: {})
    view.frame = NSRect(x: 0, y: 0, width: 246, height: 48)
    view.layoutSubtreeIfNeeded()
    view.revealForVisualQA()
    return view
}

func makeExternalTopEdgeVisualQAView(hovered: Bool) -> NSView {
    let view = NotchHoverTargetView(onClick: {})
    view.frame = NSRect(x: 0, y: 0, width: 244, height: 36)
    view.setStyle(.externalTopEdge)
    view.layoutSubtreeIfNeeded()
    if hovered { view.revealForVisualQA() }
    return view
}
