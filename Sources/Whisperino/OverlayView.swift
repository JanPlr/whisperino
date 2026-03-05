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
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                // Cancel button (left)
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                    .onTapGesture { appState.cancelRecording() }

                // Waveform bars — hover dims bars and overlays stop icon
                ZStack {
                    HStack(spacing: 2.5) {
                        ForEach(0..<5, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.white.opacity(isPaused ? 0.25 : 0.7))
                                .frame(width: 3.5, height: barHeight(for: i))
                        }
                    }
                    .opacity(isHoveringWaveform ? 0.35 : 1)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.8))
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

                // Right button: pause (transcription) or clipboard toggle (instruction)
                if appState.isInstructionMode {
                    clipboardButton
                } else {
                    pauseButton
                }
            }

            // Clipboard preview row (instruction mode only, fades in when attached)
            if appState.isInstructionMode, let preview = appState.clipboardPreview {
                HStack(spacing: 4) {
                    Text("Clipboard context:")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                    Text(preview)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlayChrome(instruction: appState.isInstructionMode)
        .animation(.easeInOut(duration: 0.2), value: appState.clipboardPreview != nil)
    }

    private var pauseButton: some View {
        Image(systemName: isPaused ? "play.fill" : "pause.fill")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.4))
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .onTapGesture {
                if isPaused { appState.resumeRecording() }
                else { appState.pauseRecording() }
            }
    }

    private var clipboardButton: some View {
        let attached = appState.clipboardPreview != nil
        return Image(systemName: "paperclip")
            .font(.system(size: 11, weight: attached ? .semibold : .regular))
            .foregroundStyle(.white.opacity(attached ? 0.75 : 0.35))
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .onTapGesture { appState.toggleClipboardAttachment() }
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
                .foregroundStyle(.white.opacity(0.75))
        }
        .overlayChrome()
    }

    // MARK: - Refining / Generating

    private var refiningView: some View {
        HStack(spacing: 8) {
            if appState.isInstructionMode {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Generating…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Refining…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .overlayChrome(instruction: appState.isInstructionMode)
    }

    // MARK: - Result / Dismissing

    private var resultDismissView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.green)

            Text(appState.isInstructionMode ? "Generated" : "Copied to clipboard")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
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
                .foregroundStyle(.white.opacity(0.85))
        }
        .overlayChrome()
    }
}

// MARK: - Overlay Chrome

private extension View {
    func overlayChrome(instruction: Bool = false) -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                Group {
                    if instruction {
                        AnimatedGradientBorder()
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    }
                }
            )
    }
}

// MARK: - Animated gradient border for instruction mode

private struct AnimatedGradientBorder: View {
    @State private var angle: Double = 0

    private let colors: [Color] = [
        Color(red: 0.85, green: 0.35, blue: 0.65),
        Color(red: 0.75, green: 0.45, blue: 0.9),
        Color(red: 0.45, green: 0.7, blue: 1.0),
        Color(red: 0.4, green: 0.55, blue: 1.0),
        .clear, .clear, .clear, .clear,
        Color(red: 0.85, green: 0.35, blue: 0.65),
    ]

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                AngularGradient(colors: colors, center: .center, angle: .degrees(angle)),
                lineWidth: 1.5
            )
            .onAppear {
                withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
            .allowsHitTesting(false)
    }
}
