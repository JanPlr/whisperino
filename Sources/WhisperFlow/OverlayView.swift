import AppKit
import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState: AppState
    @State private var isHoveringBars = false
    @State private var isHoveringCancel = false
    @State private var isHoveringPause = false

    private var isDismissing: Bool {
        if case .dismissing = appState.state { return true }
        return false
    }

    private var isPaused: Bool {
        if case .paused = appState.state { return true }
        return false
    }

    var body: some View {
        Group {
            switch appState.state {
            case .idle:
                Color.clear.frame(width: 0, height: 0)
            case .recording, .paused:
                recordingView
            case .transcribing:
                transcribingView
            case .result, .dismissing:
                resultDismissView
            case .error(let message):
                errorView(message: message)
            }
        }
        .frame(width: 320)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: appState.state)
    }

    // MARK: - Recording

    /// Buttons visible when mouse is over the panel or recording is paused
    private var showButtons: Bool { appState.isPillHovered || isPaused }

    private var recordingView: some View {
        HStack(spacing: showButtons ? 10 : 0) {
            // Cancel button — slides in from left on hover
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary.opacity(isHoveringCancel ? 0.5 : 0.25))
                .frame(width: showButtons ? 16 : 0, height: 16)
                .opacity(showButtons ? 1 : 0)
                .clipped()
                .contentShape(Rectangle())
                .floatingHover { h in withAnimation(.easeInOut(duration: 0.15)) { isHoveringCancel = h } }
                .onTapGesture { appState.cancelRecording() }

            // Waveform bars — always visible, clickable to submit
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.primary.opacity(isPaused ? 0.2 : (isHoveringBars ? 0.6 : 0.4)))
                        .frame(width: 3.5, height: barHeight(for: i))
                }
            }
            .frame(height: 20)
            .animation(.easeOut(duration: 0.08), value: appState.audioLevel)
            .animation(.easeInOut(duration: 0.2), value: isPaused)
            .contentShape(Rectangle())
            .floatingHover { h in withAnimation(.easeInOut(duration: 0.15)) { isHoveringBars = h } }
            .onTapGesture { appState.toggleRecording() }

            // Pause / Resume button — slides in from right on hover
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary.opacity(isHoveringPause ? 0.5 : 0.25))
                .frame(width: showButtons ? 16 : 0, height: 16)
                .opacity(showButtons ? 1 : 0)
                .clipped()
                .contentShape(Rectangle())
                .floatingHover { h in withAnimation(.easeInOut(duration: 0.15)) { isHoveringPause = h } }
                .onTapGesture {
                    if isPaused { appState.resumeRecording() }
                    else { appState.pauseRecording() }
                }
        }
        .overlayChrome()
    }

    private func barHeight(for index: Int) -> CGFloat {
        let level = CGFloat(appState.audioLevel)
        let patterns: [CGFloat] = [0.5, 0.8, 1.0, 0.7, 0.4]
        let barLevel = level * patterns[index]
        return max(3, barLevel * 20)
    }

    // MARK: - Transcribing (very subtle wave)

    private var transcribingView: some View {
        TimelineView(.animation) { timeline in
            let phase = CGFloat(
                timeline.date.timeIntervalSince1970
                    .truncatingRemainder(dividingBy: 3.0) / 3.0
            )
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { i in
                    let offset = CGFloat(i) / 4.0
                    let wave = (sin((phase + offset) * .pi * 2) + 1) / 2
                    let h: CGFloat = 4 + wave * 10
                    let opacity = 0.2 + wave * 0.25
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.primary.opacity(opacity))
                        .frame(width: 3.5, height: h)
                }
            }
            .frame(height: 20)
        }
        .overlayChrome()
    }

    // MARK: - Result / Dismissing

    private var resultDismissView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.green)

            Text("Copied to clipboard")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .overlayChrome()
        .scaleEffect(isDismissing ? 0.88 : 1.0)
        .opacity(isDismissing ? 0 : 1.0)
        .animation(.easeOut(duration: 0.45), value: isDismissing)
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)

            Text(message)
                .font(.system(size: 13, weight: .medium))
        }
        .overlayChrome()
    }
}

// MARK: - Overlay Chrome

private extension View {
    func overlayChrome() -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
    }
}

// MARK: - Floating Hover (for individual elements within the panel)
//
// Uses NSTrackingArea with .activeAlways for element-level hover effects
// (bar brightness, button highlight) on non-activating panels.

private struct FloatingHoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> FloatingHoverNSView {
        let view = FloatingHoverNSView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: FloatingHoverNSView, context: Context) {
        nsView.onChange = onChange
    }
}

private class FloatingHoverNSView: NSView {
    var onChange: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        reinstallTrackingArea()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reinstallTrackingArea()
    }

    override func layout() {
        super.layout()
        reinstallTrackingArea()
    }

    private func reinstallTrackingArea() {
        if let area { removeTrackingArea(area) }
        guard bounds.width > 0, bounds.height > 0 else { return }
        area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area!)
    }

    override func mouseEntered(with event: NSEvent) {
        onChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onChange?(false)
    }
}

private extension View {
    func floatingHover(onChange: @escaping (Bool) -> Void) -> some View {
        background(FloatingHoverTracker(onChange: onChange))
    }
}
