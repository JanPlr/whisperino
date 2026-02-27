import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState: AppState
    @State private var isHoveringBars = false

    private var isDismissing: Bool {
        if case .dismissing = appState.state { return true }
        return false
    }

    var body: some View {
        contentView
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: appState.state)
    }

    @ViewBuilder
    private var contentView: some View {
        switch appState.state {
        case .idle:
            Color.clear.frame(width: 0, height: 0)
        case .recording:
            recordingView
        case .transcribing:
            transcribingView
        case .result(_), .dismissing:
            resultDismissView
        case .error(let message):
            errorView(message: message)
        }
    }

    // MARK: - Recording: large audio bars + stop button, no text

    private var recordingView: some View {
        HStack(spacing: 14) {
            audioBarsInteractive
            stopButton
        }
        .overlayChrome()
    }

    private var audioBarsInteractive: some View {
        ZStack {
            // The actual audio level bars
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white)
                        .frame(width: 4, height: barHeight(for: i))
                }
            }
            .opacity(isHoveringBars ? 0.25 : 1.0)
            .animation(.easeOut(duration: 0.08), value: appState.audioLevel)

            // Stop icon revealed on hover
            if isHoveringBars {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .transition(.opacity)
            }
        }
        .frame(width: 36, height: 48)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHoveringBars = hovering
            }
        }
        .onTapGesture {
            appState.toggleRecording()
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let level = CGFloat(appState.audioLevel)
        let patterns: [CGFloat] = [0.40, 0.70, 1.0, 0.65, 0.35]
        let barLevel = level * patterns[index]
        return max(5, barLevel * 48)
    }

    private var stopButton: some View {
        Button(action: { appState.toggleRecording() }) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.1))
                    .frame(width: 28, height: 28)
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(.white.opacity(0.6))
                    .frame(width: 10, height: 10)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Transcribing: shimmer wave animation, no text

    private var transcribingView: some View {
        TimelineView(.animation) { timeline in
            let phase = CGFloat(
                timeline.date.timeIntervalSince1970
                    .truncatingRemainder(dividingBy: 1.8) / 1.8
            )
            shimmerBars(phase: phase)
        }
        .overlayChrome()
    }

    private func shimmerBars(phase: CGFloat) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { i in
                let offset = CGFloat(i) / 4.0
                // Traveling sine wave left-to-right
                let wave = (sin((phase + offset) * .pi * 2) + 1) / 2  // 0..1
                let h = 5 + wave * 40   // 5..45
                let opacity = 0.25 + wave * 0.75  // 0.25..1.0
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white.opacity(opacity))
                    .frame(width: 4, height: h)
            }
        }
        .frame(width: 36, height: 48)
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

            Spacer()
        }
        .frame(width: 272)
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
        .frame(width: 272)
        .overlayChrome()
    }
}

private extension View {
    func overlayChrome() -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
    }
}
