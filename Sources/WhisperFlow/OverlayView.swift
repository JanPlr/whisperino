import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState: AppState

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
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: appState.state)
    }

    // MARK: - Recording: just bars + timer + stop

    private var recordingView: some View {
        HStack(spacing: 16) {
            audioLevelBars
            durationLabel
            stopButton
        }
        .overlayChrome()
    }

    private var audioLevelBars: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white.opacity(0.9))
                    .frame(width: 3.5, height: barHeight(for: i))
            }
        }
        .frame(height: 28)
        .animation(.easeOut(duration: 0.08), value: appState.audioLevel)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let level = CGFloat(appState.audioLevel)
        let patterns: [CGFloat] = [0.45, 0.75, 1.0, 0.65, 0.35]
        let barLevel = level * patterns[index]
        return max(4, barLevel * 28)
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

    private var stopButton: some View {
        Button(action: { appState.toggleRecording() }) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 28, height: 28)
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(.white.opacity(0.55))
                    .frame(width: 10, height: 10)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Transcribing: wave animation

    private var transcribingView: some View {
        TimelineView(.animation) { timeline in
            let phase = CGFloat(
                timeline.date.timeIntervalSince1970
                    .truncatingRemainder(dividingBy: 1.6) / 1.6
            )
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let offset = CGFloat(i) / 4.0
                    let wave = (sin((phase + offset) * .pi * 2) + 1) / 2
                    let h = 5 + wave * 23
                    let opacity = 0.3 + wave * 0.6
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(opacity))
                        .frame(width: 3.5, height: h)
                }
            }
            .frame(height: 28)
        }
        .overlayChrome()
    }

    // MARK: - Result / Dismissing

    private var resultDismissView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.green)

            Text("Copied to clipboard")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
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
        }
        .overlayChrome()
    }
}

private extension View {
    func overlayChrome() -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }
}
