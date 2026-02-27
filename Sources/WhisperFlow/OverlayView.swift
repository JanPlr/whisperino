import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState: AppState
    @State private var isPulsing = false

    private var isDismissing: Bool {
        if case .dismissing = appState.state { return true }
        return false
    }

    var body: some View {
        Group {
            switch appState.state {
            case .idle:
                Color.clear.frame(width: 0, height: 0)
            case .recording:
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

    private var recordingView: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(isPulsing ? 0.4 : 1.0)
                .onAppear { isPulsing = true }
                .onDisappear { isPulsing = false }
                .animation(
                    .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                    value: isPulsing
                )

            Text("Recording")
                .font(.system(size: 13, weight: .medium))

            audioLevelBars

            Spacer()

            durationLabel

            stopButton
        }
        .overlayChrome()
    }

    private var stopButton: some View {
        Button(action: { appState.toggleRecording() }) {
            ZStack {
                Circle()
                    .fill(.primary.opacity(0.08))
                    .frame(width: 26, height: 26)
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(.primary.opacity(0.5))
                    .frame(width: 9, height: 9)
            }
        }
        .buttonStyle(.plain)
    }

    private var audioLevelBars: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.primary.opacity(0.4))
                    .frame(width: 3, height: barHeight(for: i))
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.08), value: appState.audioLevel)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let level = CGFloat(appState.audioLevel) // already 0..1
        // Each bar gets a different scale for a waveform look
        let patterns: [CGFloat] = [0.5, 0.8, 1.0, 0.7, 0.4]
        let barLevel = level * patterns[index]
        return max(3, barLevel * 16)
    }

    private var durationLabel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            if let start = appState.recordingStartTime {
                let seconds = Int(timeline.date.timeIntervalSince(start))
                let m = seconds / 60
                let s = seconds % 60
                Text(String(format: "%d:%02d", m, s))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Transcribing

    private var transcribingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)

            Text("Transcribing...")
                .font(.system(size: 13, weight: .medium))

            Spacer()
        }
        .overlayChrome()
    }

    // MARK: - Result / Dismissing (Dynamic Island-style)

    private var resultDismissView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.green)

            Text("Copied to clipboard")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .overlayChrome()
        .scaleEffect(isDismissing ? 0.6 : 1.0)
        .opacity(isDismissing ? 0 : 1.0)
        .animation(.easeInOut(duration: 0.4), value: isDismissing)
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)

            Text(message)
                .font(.system(size: 13, weight: .medium))

            Spacer()
        }
        .overlayChrome()
    }

}

private extension View {
    func overlayChrome() -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
    }
}
