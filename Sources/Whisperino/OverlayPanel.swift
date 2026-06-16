import AppKit
import ApplicationServices
import Combine
import SwiftUI

class OverlayPanel {
    private let panel: NSPanel
    private let appState: AppState
    private var isVisible = false
    private var dismissGeneration = 0
    private var cancellable: AnyCancellable?

    /// Base panel height with no attachments or picker
    private static let baseHeight: CGFloat = 180
    /// Extra height per attachment row
    private static let rowHeight: CGFloat = 32

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

        // Resize panel whenever attachments, picker visibility, device count,
        // or chat state changes. Uses the exact same formula as
        // OverlayView.panelContentHeight.
        cancellable = Publishers.CombineLatest4(
            appState.$attachedContexts.map(\.count).removeDuplicates(),
            appState.$showingInputPicker.removeDuplicates(),
            appState.$inputDevices.map(\.count).removeDuplicates(),
            appState.$chatHistory.map { !$0.isEmpty }.removeDuplicates()
        )
        .sink { [weak self] attachmentCount, pickerShowing, deviceCount, chatActive in
            self?.updatePanelHeight(
                attachmentCount: attachmentCount,
                pickerShowing: pickerShowing,
                deviceCount: deviceCount,
                chatActive: chatActive
            )
        }
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
            attachmentCount: appState.attachedContexts.count,
            pickerShowing: appState.showingInputPicker,
            deviceCount: appState.inputDevices.count,
            chatActive: !appState.chatHistory.isEmpty
        )
        if abs(panel.frame.height - fullHeight) > 1 {
            var frame = panel.frame
            frame.size.height = fullHeight
            panel.setFrame(frame, display: false)
        }
        positionAtBottomCenter()
        // Instant - the pill should be there the moment recording
        // starts. Any fade-in here reads as input lag.
        panel.alphaValue = 1
        panel.orderFront(nil)
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
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
        return 28 + CGFloat(count) * 26 + 12 + 1
    }

    /// Vertical space the chat scroll claims above the pill. Must match
    /// `OverlayView.chatScrollHeight`.
    private static let chatScrollHeight: CGFloat = 360

    private func panelHeight(
        attachmentCount: Int,
        pickerShowing: Bool,
        deviceCount: Int,
        chatActive: Bool
    ) -> CGFloat {
        var height = Self.baseHeight
        if attachmentCount > 0 {
            let rows = CGFloat(min(attachmentCount, AppState.maxAttachments)) * Self.rowHeight
            let addButton: CGFloat = attachmentCount < AppState.maxAttachments ? 36 : 0
            height += rows + addButton
        }
        // Always include picker height so the panel never resizes for picker
        // open/close. SwiftUI handles the visual animation within the fixed panel.
        // This eliminates NSPanel ↔ SwiftUI animation desync entirely.
        height += Self.pickerExtraHeight(deviceCount: deviceCount)
        // Chat is additive - when active, the scroll grows the panel
        // upward, the pill stays at the bottom.
        if chatActive {
            height += Self.chatScrollHeight
        }
        return height
    }

    private func updatePanelHeight(
        attachmentCount: Int,
        pickerShowing: Bool,
        deviceCount: Int,
        chatActive: Bool
    ) {
        guard isVisible else { return }
        let newHeight = panelHeight(
            attachmentCount: attachmentCount,
            pickerShowing: pickerShowing,
            deviceCount: deviceCount,
            chatActive: chatActive
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

    private func positionAtBottomCenter() {
        let panelSize = panel.frame.size

        // The app frontmost as the pill appears is the dictation target.
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let window = pid.flatMap { Self.focusedWindowFrameCocoa(pid: $0) }

        // Pick the screen the target window sits on (matched by horizontal
        // span, coordinate-system-agnostic), else the main screen.
        let screen: NSScreen? = {
            if let mx = window?.midX,
               let hit = NSScreen.screens.first(where: { $0.frame.minX <= mx && mx <= $0.frame.maxX }) {
                return hit
            }
            return NSScreen.main ?? NSScreen.screens.first
        }()
        guard let screen else { return }
        let visible = screen.visibleFrame

        if let window {
            // Anchor the pill to the BOTTOM EDGE OF THE TARGET WINDOW - the
            // "bottom-most element" the user is working in. A normal window's
            // bottom sits just above the Dock, so the pill rides there; a
            // window that fills the screen (fullscreen or Dock-hidden) has its
            // bottom at the physical screen edge, so the pill drops all the
            // way down. One rule, both cases, no fullscreen guesswork.
            let x = window.midX - panelSize.width / 2
            // Never let it sit below the physical screen bottom.
            let y = max(window.minY, screen.frame.minY)
            // Keep horizontally on-screen for off-centre / narrow windows.
            let clampedX = min(max(x, visible.minX + 8), visible.maxX - panelSize.width - 8)
            panel.setFrameOrigin(NSPoint(x: clampedX, y: y))
        } else {
            // No AX window info (no grant / opaque app): bottom-centre of the
            // visible frame, as before.
            panel.setFrameOrigin(NSPoint(x: visible.midX - panelSize.width / 2, y: visible.minY))
        }
    }

    /// Focused window frame of `pid` in Cocoa (bottom-left origin) screen
    /// coordinates, via the Accessibility API. Returns nil without an AX
    /// grant or if the app exposes no focused window.
    private static func focusedWindowFrameCocoa(pid: pid_t) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let w = winRef, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        let win = w as! AXUIElement

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

        // AX is top-left origin measured from the primary (menu-bar) screen;
        // Cocoa is bottom-left. Flip the window's BOTTOM edge into Cocoa Y.
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main else { return nil }
        let cocoaY = primary.frame.maxY - (pos.y + size.height)
        return CGRect(x: pos.x, y: cocoaY, width: size.width, height: size.height)
    }
}
