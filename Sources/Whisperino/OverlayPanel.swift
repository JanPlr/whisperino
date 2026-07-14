import AppKit
import Combine
import SwiftUI

class OverlayPanel {
    private let panel: NSPanel
    private let appState: AppState
    private var isVisible = false
    private var dismissGeneration = 0
    private var cancellable: AnyCancellable?
    private var trackTimer: Timer?
    /// The origin we last asked the panel to move to. Compared against (rather
    /// than the live frame) so the 60fps tracker doesn't restart an in-flight
    /// slide every tick - during an animator move `panel.frame.origin` reports
    /// the intermediate value, not the destination.
    private var targetOrigin: NSPoint?

    /// Base panel height with no picker expanded
    private static let baseHeight: CGFloat = 180

    init(appState: AppState) {
        self.appState = appState
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: Self.baseHeight),
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

        // Resize panel whenever picker visibility or device count changes.
        // Uses the exact same formula as OverlayView.panelContentHeight.
        cancellable = Publishers.CombineLatest(
            appState.$showingInputPicker.removeDuplicates(),
            appState.$inputDevices.map(\.count).removeDuplicates()
        )
        .sink { [weak self] pickerShowing, deviceCount in
            self?.updatePanelHeight(pickerShowing: pickerShowing, deviceCount: deviceCount)
        }

    }

    deinit {
        trackTimer?.invalidate()
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
            self?.positionAtBottomCenter()
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
        positionAtBottomCenter(instant: true)
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

            let baseFrame = NSRect(
                x: self.panel.frame.origin.x,
                y: self.panel.frame.minY,
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

        // Keep the bottom edge pinned at the same Y position
        let bottomY = panel.frame.minY
        let newFrame = NSRect(
            x: panel.frame.origin.x,
            y: bottomY,
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

    private func positionAtBottomCenter(instant: Bool = false) {
        guard let target = computeTargetOrigin() else { return }
        targetOrigin = target
        if instant {
            // Initial appearance (or forced): snap, no glide-in.
            panel.setFrameOrigin(target)
        } else {
            easeOriginTowardTarget()
        }
    }

    /// The bottom-centre origin the pill should occupy right now: anchored to
    /// the bottom edge of the frontmost window (the "bottom-most element" the
    /// user is working in). A normal window's bottom sits just above the Dock;
    /// a window that fills the screen (fullscreen / Dock-hidden) reaches the
    /// physical screen edge, so the pill drops all the way down. One rule,
    /// both cases. Falls back to the visible-frame bottom centre with no AX
    /// grant or no focused window. Returns nil only when there's no screen.
    private func computeTargetOrigin() -> NSPoint? {
        let panelSize = panel.frame.size
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let window = ScreenCapture.focusedWindowFrame(pid: pid)

        let screen: NSScreen? = {
            if let mx = window?.midX,
               let hit = NSScreen.screens.first(where: { $0.frame.minX <= mx && mx <= $0.frame.maxX }) {
                return hit
            }
            return NSScreen.main ?? NSScreen.screens.first
        }()
        guard let screen else { return nil }
        let visible = screen.visibleFrame

        guard let window else {
            return NSPoint(x: visible.midX - panelSize.width / 2, y: visible.minY)
        }
        let x = window.midX - panelSize.width / 2
        let y = max(window.minY, screen.frame.minY)
        let clampedX = min(max(x, visible.minX + 8), visible.maxX - panelSize.width - 8)
        return NSPoint(x: clampedX, y: y)
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
