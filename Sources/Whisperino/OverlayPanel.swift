import AppKit
import Combine
import SwiftUI

class OverlayPanel {
    private let panel: NSPanel
    private var isVisible = false
    private var cancellable: AnyCancellable?

    /// Base panel height with no attachments
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
        panel.animationBehavior = .utilityWindow

        let hostingView = NSHostingView(
            rootView: OverlayView(appState: appState)
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView

        // Resize panel when attachments change
        cancellable = appState.$attachedContexts
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] count in
                self?.updatePanelHeight(attachmentCount: count)
            }
    }

    func present() {
        guard !isVisible else { return }
        isVisible = true
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

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)

            // Reset to base height so next present() starts clean
            let baseFrame = NSRect(
                x: self.panel.frame.origin.x,
                y: self.panel.frame.minY,
                width: self.panel.frame.width,
                height: Self.baseHeight
            )
            self.panel.setFrame(baseFrame, display: false)
        })
    }

    private func panelHeight(attachmentCount: Int) -> CGFloat {
        guard attachmentCount > 0 else { return Self.baseHeight }
        let rows = CGFloat(min(attachmentCount, AppState.maxAttachments)) * Self.rowHeight
        let addButton: CGFloat = attachmentCount < AppState.maxAttachments ? 36 : 0
        return Self.baseHeight + rows + addButton
    }

    private func updatePanelHeight(attachmentCount: Int) {
        guard isVisible else { return }
        let newHeight = panelHeight(attachmentCount: attachmentCount)
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

        NSAnimationContext.runAnimationGroup { context in
            // Collapsing uses a longer, gentler curve; expanding is snappier
            context.duration = isCollapsing ? 0.35 : 0.25
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.25, 0.1, 0.25, 1.0  // ease-out curve
            )
            panel.animator().setFrame(newFrame, display: true)
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
