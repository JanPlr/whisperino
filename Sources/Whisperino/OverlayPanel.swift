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

        // Resize panel whenever attachments, picker visibility, or device count changes.
        // Uses the exact same height formula as OverlayView.pickerExtraHeight.
        cancellable = Publishers.CombineLatest3(
            appState.$attachedContexts.map(\.count).removeDuplicates(),
            appState.$showingInputPicker.removeDuplicates(),
            appState.$inputDevices.map(\.count).removeDuplicates()
        )
        .sink { [weak self] attachmentCount, pickerShowing, deviceCount in
            self?.updatePanelHeight(
                attachmentCount: attachmentCount,
                pickerShowing: pickerShowing,
                deviceCount: deviceCount
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

    private func panelHeight(attachmentCount: Int, pickerShowing: Bool, deviceCount: Int) -> CGFloat {
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
        return height
    }

    private func updatePanelHeight(attachmentCount: Int, pickerShowing: Bool, deviceCount: Int) {
        guard isVisible else { return }
        let newHeight = panelHeight(
            attachmentCount: attachmentCount,
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

        NSAnimationContext.runAnimationGroup { context in
            context.duration = isCollapsing ? 0.35 : 0.25
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.25, 0.1, 0.25, 1.0
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
