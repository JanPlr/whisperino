import AppKit

/// Briefly draws a frame around a window to show the user which window AI mode
/// just screenshotted. A borderless, click-through overlay that fades itself
/// out - purely a "this is what I'm looking at" affordance.
final class WindowHighlighter {
    private var window: NSWindow?
    private var dismissWork: DispatchWorkItem?

    /// Flash a frame around `frame` (Cocoa, bottom-left origin, global coords).
    func flash(frame: CGRect) {
        dismiss()
        guard frame.width > 4, frame.height > 4 else { return }

        let panel = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Above everything, across Spaces and over fullscreen apps - same
        // treatment as the overlay pill so it's never buried.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.animationBehavior = .none

        let view = HighlightBorderView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        panel.contentView = view
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFront(nil)
        window = panel

        // Hold briefly, then fade out and tear down.
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.window else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.5
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                panel.orderOut(nil)
                if self?.window === panel { self?.window = nil }
            })
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        window?.orderOut(nil)
        window = nil
    }
}

/// Draws the rounded accent frame. Matches the app's AI accent so the frame
/// reads as "Whisperino is looking here".
private final class HighlightBorderView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = 3
        let inset = lineWidth / 2 + 0.5
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let radius: CGFloat = 12
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = lineWidth

        // Warm accent + soft outer glow, matching the mic satellite accent.
        let accent = NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.15, alpha: 1)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = accent.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = .zero
        shadow.set()
        accent.setStroke()
        path.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
