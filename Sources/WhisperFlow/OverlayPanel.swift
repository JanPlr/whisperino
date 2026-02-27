import AppKit
import SwiftUI

class OverlayPanel {
    private let panel: NSPanel
    private let appState: AppState
    private var isVisible = false
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(appState: AppState) {
        self.appState = appState
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 56),
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
        panel.acceptsMouseMovedEvents = true

        let hostingView = NSHostingView(
            rootView: OverlayView(appState: appState)
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView
    }

    func present() {
        guard !isVisible else { return }
        isVisible = true
        positionAtBottomCenter()
        panel.alphaValue = 0
        panel.orderFront(nil)
        startMouseMonitoring()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        stopMouseMonitoring()
        DispatchQueue.main.async { [weak self] in
            self?.appState.isPillHovered = false
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }

    // MARK: - Mouse Hover Monitoring
    //
    // Monitors global + local mouse movement to detect when the cursor
    // enters/leaves the panel frame. This bypasses all SwiftUI/NSTrackingArea
    // issues with non-activating floating panels.

    private func startMouseMonitoring() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.updateHoverState()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.updateHoverState()
        }
    }

    private func stopMouseMonitoring() {
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func updateHoverState() {
        let mouseLocation = NSEvent.mouseLocation // screen coordinates
        let isInside = panel.frame.contains(mouseLocation)
        guard appState.isPillHovered != isInside else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                self.appState.isPillHovered = isInside
            }
        }
    }

    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.minY + 60
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
