import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState: AppState
    @State private var isPulsing = false

    var body: some View {
        Group {
            switch appState.state {
            case .idle:
                Color.clear.frame(width: 0, height: 0)
            case .recording:
                recordingView
            case .transcribing:
                transcribingView
            case .result(let text):
                resultView(text: text)
            case .error(let message):
                errorView(message: message)
            }
        }
        .frame(width: 320)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: appState.state)
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

            shortcutBadge("Stop")
        }
        .overlayChrome()
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

    // MARK: - Result

    private func resultView(text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)

                Text("Copied to clipboard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            Text(text)
                .font(.system(size: 13))
                .lineLimit(3)
                .truncationMode(.tail)
        }
        .overlayChrome()
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

    // MARK: - Shared

    private func shortcutBadge(_ label: String) -> some View {
        Text("\u{2325}D \(label)")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
