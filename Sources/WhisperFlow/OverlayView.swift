import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState: AppState
    @State private var isHoveringBars = false

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
        HStack(spacing: 12) {
            // Clickable bars — hover dims bars, reveals stop square
            ZStack {
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(.primary.opacity(isHoveringBars ? 0.15 : 0.4))
                            .frame(width: 3, height: barHeight(for: i))
                    }
                }
                .frame(height: 16)
                .animation(.easeOut(duration: 0.08), value: appState.audioLevel)

                if isHoveringBars {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.primary.opacity(0.5))
                        .frame(width: 7, height: 7)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onHover { h in
                withAnimation(.easeInOut(duration: 0.12)) { isHoveringBars = h }
            }
            .onTapGesture { appState.toggleRecording() }

            durationLabel
        }
        .overlayChrome()
    }

    private func barHeight(for index: Int) -> CGFloat {
        let level = CGFloat(appState.audioLevel)
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

    // MARK: - Transcribing (very subtle wave)

    private var transcribingView: some View {
        TimelineView(.animation) { timeline in
            let phase = CGFloat(
                timeline.date.timeIntervalSince1970
                    .truncatingRemainder(dividingBy: 3.0) / 3.0
            )
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    let offset = CGFloat(i) / 4.0
                    let wave = (sin((phase + offset) * .pi * 2) + 1) / 2
                    let h: CGFloat = 4 + wave * 8
                    let opacity = 0.2 + wave * 0.25
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.primary.opacity(opacity))
                        .frame(width: 3, height: h)
                }
            }
            .frame(height: 16)
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
