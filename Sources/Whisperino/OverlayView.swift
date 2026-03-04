import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState: AppState

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
            case .refining:
                refiningView
            case .result, .dismissing:
                resultDismissView
            case .error(let message):
                errorView(message: message)
            }
        }
        .frame(width: 320)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: appState.state)
    }

    @State private var isHoveringWaveform = false

    // MARK: - Recording

    private var recordingView: some View {
        HStack(spacing: 10) {
            // Cancel button (left)
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary.opacity(0.25))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .onTapGesture { appState.cancelRecording() }

            // Waveform bars — hover dims bars and overlays stop icon
            ZStack {
                // Waveform bars (dim on hover, never fully hidden)
                HStack(spacing: 2.5) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.primary.opacity(isPaused ? 0.2 : 0.4))
                            .frame(width: 3.5, height: barHeight(for: i))
                    }
                }
                .opacity(isHoveringWaveform ? 0.35 : 1)

                // Stop icon (fades in on hover, overlaid on dimmed bars)
                RoundedRectangle(cornerRadius: 2)
                    .fill(.primary.opacity(0.45))
                    .frame(width: 10, height: 10)
                    .opacity(isHoveringWaveform ? 1 : 0)
            }
            .frame(height: 20)
            .animation(.easeOut(duration: 0.08), value: appState.audioLevel)
            .animation(.easeInOut(duration: 0.15), value: isHoveringWaveform)
            .animation(.easeInOut(duration: 0.2), value: isPaused)
            .contentShape(Rectangle())
            .onHover { hovering in isHoveringWaveform = hovering }
            .onTapGesture { appState.toggleRecording() }

            // Pause / Resume button (right)
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary.opacity(0.25))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
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

    // MARK: - Transcribing

    private var transcribingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            Text("Transcribing…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .overlayChrome()
    }

    // MARK: - Refining

    private var refiningView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            Text("Refining…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
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
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            )
    }
}

