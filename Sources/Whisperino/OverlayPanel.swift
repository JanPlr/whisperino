import AppKit
import Combine
import SwiftUI

class OverlayPanel {
    private let panel: NSPanel
    private var isVisible = false
    private var dismissGeneration = 0
    private var cancellable: AnyCancellable?

    /// Base panel height with no attachments or picker
    private static let baseHeight: CGFloat = 180
    /// Extra height per attachment row
    private static let rowHeight: CGFloat = 32

    init(appState: AppState) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: Self.baseHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // `.none` — we run our own alpha fade in present()/dismiss(). The
        // default `.utilityWindow` adds a separate OS-level fade that
        // overlaps ours and shows a faint gray rectangle for a frame or
        // two until both animations settle.
        panel.animationBehavior = .none

        let hostingView = NSHostingView(
            rootView: OverlayView(appState: appState)
        )
        hostingView.wantsLayer = true
        // `nil`, not `.clear` — `.clear` is still a CGColor (transparent
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
        isVisible = true
        dismissGeneration += 1
        positionAtBottomCenter()
        panel.alphaValue = 0
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        dismissGeneration += 1
        let gen = dismissGeneration

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
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
    private static let chatScrollHeight: CGFloat = 320

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
        // Chat is additive — when active, the scroll grows the panel
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
                      // Re-check size on fire — another resize may have
                      // overtaken us in the meantime.
                      abs(self.panel.frame.height - newHeight) > 1 else { return }
                self.panel.setFrame(newFrame, display: true)
            }
        } else {
            // Growing: snap the panel to the new size right away. The
            // transparent area above the dark container is invisible,
            // so the user sees only SwiftUI's spring expanding the
            // pill — same feel as the input device picker, which
            // doesn't resize the panel either.
            panel.setFrame(newFrame, display: true)
        }
    }

    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.minY + 30
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
