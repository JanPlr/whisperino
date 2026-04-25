import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState: AppState

    private var isDismissing: Bool {
        if case .dismissing = appState.state { return true }
        return false
    }

    private var isCancelled: Bool {
        if case .cancelled = appState.state { return true }
        return false
    }

    /// Extra height for attachment rows + add-more button
    private var attachmentExtraHeight: CGFloat {
        let count = appState.attachedContexts.count
        guard count > 0 else { return 0 }
        let rows = CGFloat(min(count, AppState.maxAttachments)) * 32
        let addButton: CGFloat = count < AppState.maxAttachments ? 36 : 0
        return rows + addButton
    }

    /// Extra height reserved for the input device picker.
    /// Always included (even when picker is closed) so the panel and body frame
    /// never resize for picker open/close — SwiftUI handles the visual animation.
    /// Must match OverlayPanel.pickerExtraHeight exactly.
    private var pickerExtraHeight: CGFloat {
        let deviceCount = max(appState.inputDevices.count, 1)
        return 28 + CGFloat(deviceCount) * 26 + 12 + 1
    }

    var body: some View {
        Group {
            switch appState.state {
            case .idle:
                Color.clear.frame(width: 0, height: 0)
            case .recording, .paused, .cancelled:
                recordingView.padding(.top, 6)
            case .transcribing:
                transcribingView.padding(.top, 6)
            case .refining:
                refiningView.padding(.top, 6)
            case .result, .dismissing:
                resultDismissView.padding(.top, 6)
            case .error(let message):
                errorView(message: message).padding(.top, 6)
            }
        }
        .frame(width: 380)
        .padding(.bottom, 44)
        .frame(height: 180 + attachmentExtraHeight + pickerExtraHeight, alignment: .bottom)
        .animation(appState.suppressStateAnimation ? nil : .spring(response: 0.35, dampingFraction: 0.82), value: appState.state)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: appState.attachedContexts.count)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: appState.showingInputPicker)
    }

    @State private var isHoveringPill = false
    @State private var isHoveringCancel = false
    @State private var isHoveringMic = false
    @State private var isHoveringWaveform = false

    // MARK: - Recording

    private var recordingView: some View {
        let hasAttachments = appState.isInstructionMode && !appState.attachedContexts.isEmpty
        let cancelled = isCancelled

        return ZStack {
            // === The pill ===
            VStack(spacing: 0) {
                if appState.showingInputPicker && !cancelled {
                    InputDevicePicker(appState: appState, isPresented: $appState.showingInputPicker)
                        .transition(.opacity.combined(with: .move(edge: .top)))

                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                        .transition(.opacity)
                }

                HStack(spacing: 10) {
                    if hasAttachments && !cancelled {
                        Spacer(minLength: 0)
                        Color.clear.frame(width: 20, height: 1)
                    }

                    HStack(spacing: 3) {
                        ForEach(0..<AppState.waveformBarCount, id: \.self) { i in
                            Capsule()
                                .fill(.white.opacity(0.78))
                                .frame(width: 3.5, height: barHeight(for: i))
                        }
                    }
                    .frame(height: 22)

                    if appState.isInstructionMode && !cancelled {
                        clipboardButton
                    }

                    if hasAttachments && !cancelled { Spacer(minLength: 0) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onHover { isHoveringWaveform = $0 }
                .onTapGesture { appState.toggleRecording() }

                if hasAttachments && !cancelled {
                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(height: 1)
                        .padding(.horizontal, 8)

                    VStack(spacing: 2) {
                        ForEach(appState.attachedContexts) { ctx in
                            attachmentRow(ctx)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        if appState.attachedContexts.count < AppState.maxAttachments {
                            addMoreButton
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
            .frame(width: (!cancelled && (hasAttachments || appState.showingInputPicker)) ? 300 : nil)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
            .overlay(
                Group {
                    if cancelled {
                        EmptyView()
                    } else if isHoveringCancel {
                        GlowBorder(cornerRadius: 18, color: Color(red: 0.9, green: 0.25, blue: 0.25))
                    } else if isHoveringWaveform {
                        GlowBorder(cornerRadius: 18, color: Color(red: 0.25, green: 0.78, blue: 0.45))
                    } else if appState.showingInputPicker || isHoveringMic {
                        GlowBorder(cornerRadius: 18, color: Color(red: 0.95, green: 0.55, blue: 0.15))
                    } else if isHoveringPill {
                        GlowBorder(cornerRadius: 18, color: Color(red: 0.25, green: 0.78, blue: 0.45))
                    } else if appState.isInstructionMode {
                        AnimatedGradientBorder(cornerRadius: 18)
                    } else {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
                    }
                }
            )
            .scaleEffect(cancelled ? 0.92 : 1.0)
            .opacity(cancelled ? 0 : 1)
            .blur(radius: cancelled ? 4 : 0)
            .animation(.easeOut(duration: 0.22), value: cancelled)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hasAttachments)
            // Cancel X button — top-right
            .overlay(alignment: .topTrailing) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(isHoveringCancel ? 1 : 0.85))
                    .frame(width: 16, height: 16)
                    .background(
                        Circle().fill(
                            isHoveringCancel
                                ? Color(red: 0.8, green: 0.2, blue: 0.2)
                                : Color(white: 0.3)
                        )
                    )
                    .clipShape(Circle())
                    .contentShape(Circle().scale(1.5))
                    .onHover { isHoveringCancel = $0 }
                    .onTapGesture { appState.cancelRecording() }
                    .opacity(isHoveringPill && !cancelled ? (isHoveringCancel ? 1 : 0.7) : 0)
                    .scaleEffect(isHoveringPill && !cancelled ? 1 : 0.4)
                    .offset(x: 6, y: -6)
                    .animation(.easeOut(duration: 0.15), value: isHoveringPill)
                    .animation(.easeInOut(duration: 0.1), value: isHoveringCancel)
            }
            // Mic button — top-left
            .overlay(alignment: .topLeading) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(isHoveringMic ? 1 : 0.85))
                    .frame(width: 16, height: 16)
                    .background(
                        Circle().fill(
                            isHoveringMic
                                ? Color(red: 0.95, green: 0.55, blue: 0.15)
                                : Color(white: 0.3)
                        )
                    )
                    .clipShape(Circle())
                    .contentShape(Circle().scale(1.5))
                    .onHover { isHoveringMic = $0 }
                    .onTapGesture {
                        appState.refreshInputDevices()
                        appState.showingInputPicker.toggle()
                    }
                    .opacity(isHoveringPill && !cancelled ? (isHoveringMic ? 1 : 0.7) : 0)
                    .scaleEffect(isHoveringPill && !cancelled ? 1 : 0.4)
                    .offset(x: -6, y: -6)
                    .animation(.easeOut(duration: 0.15), value: isHoveringPill)
                    .animation(.easeInOut(duration: 0.1), value: isHoveringMic)
            }
        }
        .onHover { isHoveringPill = $0 }
        .animation(.easeInOut(duration: 0.18), value: appState.audioSamples)
        .animation(.easeInOut(duration: 0.15), value: isHoveringPill)
        .animation(.easeInOut(duration: 0.15), value: isHoveringMic)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: appState.attachedContexts.count)
    }

    private func attachmentRow(_ ctx: AttachedContext) -> some View {
        AttachmentRowView(ctx: ctx, onRemove: { appState.removeAttachment(id: ctx.id) })
    }

    private var clipboardButton: some View {
        let hasAttachments = !appState.attachedContexts.isEmpty
        return Image(systemName: "paperclip")
            .font(.system(size: 11, weight: hasAttachments ? .semibold : .regular))
            .foregroundStyle(.white.opacity(hasAttachments ? 0.75 : 0.35))
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .onTapGesture {
                if hasAttachments {
                    appState.clearAllAttachments()
                } else {
                    appState.addClipboardAttachment()
                }
            }
    }

    @State private var isHoveringAddMore = false

    private var addMoreButton: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .medium))
                Text("Add more clipboard content")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(.white.opacity(isHoveringAddMore ? 0.6 : 0.3))

            Text("Copy more context or images to your clipboard and add them here")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(isHoveringAddMore ? 0.35 : 0.18))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHoveringAddMore = $0 }
        .onTapGesture { appState.addClipboardAttachment() }
    }

    /// Center-emphasizing shape mask: bars at the edges are visually muted so
    /// the wave reads as a centered crest. Voice samples enter on the right
    /// (small), grow as they roll into the middle (peak), then fade as they
    /// continue left and exit.
    private static let barShape: [CGFloat] = [
        0.45, 0.65, 0.85, 0.95, 1.0, 0.95, 0.85, 0.65, 0.45
    ]

    private func barHeight(for index: Int) -> CGFloat {
        let samples = appState.audioSamples
        guard samples.indices.contains(index) else { return 4 }
        // Spatial smoothing — blend each sample with its neighbours [1,2,1]/4
        // so a single-tick spike in one buffer position gets diluted into a
        // smooth crest instead of a jagged jump.
        let curr = CGFloat(samples[index])
        let prev = index > 0 ? CGFloat(samples[index - 1]) : curr
        let next = index < samples.count - 1 ? CGFloat(samples[index + 1]) : curr
        let smoothed = (prev + curr * 2 + next) / 4
        let shape = Self.barShape.indices.contains(index) ? Self.barShape[index] : 1.0
        return max(4, 4 + smoothed * shape * 16)
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
            if appState.isAgentMode {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                Text("\(appState.activeAgentName ?? "Agent"): \(appState.agentStatus ?? "Working\u{2026}")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.25), value: appState.agentStatus)
            } else if appState.isInstructionMode {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Generating\u{2026}")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Refining\u{2026}")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .overlayChrome(instruction: appState.isInstructionMode || appState.isAgentMode)
    }

    // MARK: - Result / Dismissing

    private var resultDismissView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.green)

            Text(appState.isAgentMode
                ? "\(appState.activeAgentName ?? "Agent") responded"
                : appState.isInstructionMode ? "Generated" : "Copied to clipboard")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
        }
        .overlayChrome()
        .scaleEffect(isDismissing ? 0.95 : 1.0)
        .opacity(isDismissing ? 0 : 1.0)
        .animation(.easeOut(duration: 0.3), value: isDismissing)
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
            .padding(.vertical, 10)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
            .overlay(
                Group {
                    if instruction {
                        AnimatedGradientBorder(cornerRadius: 18)
                    } else {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    }
                }
            )
    }
}

// MARK: - Attachment row with image preview

private struct AttachmentRowView: View {
    let ctx: AttachedContext
    let onRemove: () -> Void
    @State private var showingPreview = false

    var body: some View {
        HStack(spacing: 6) {
            // Thumbnail or text icon
            if case .image(let image) = ctx.content {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.white.opacity(showingPreview ? 0.4 : 0.15), lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { showingPreview.toggle() }
                    .popover(isPresented: $showingPreview, arrowEdge: .top) {
                        imagePreview(image)
                    }
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 24, height: 24)
            }

            Text(ctx.preview)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            // Remove button
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .onTapGesture { onRemove() }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private func imagePreview(_ image: NSImage) -> some View {
        let maxWidth: CGFloat = 520
        let maxHeight: CGFloat = 400
        let aspect = image.size.width / max(image.size.height, 1)
        let width = min(maxWidth, maxHeight * aspect)
        let height = min(maxHeight, maxWidth / aspect)

        return Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(8)
    }
}

// MARK: - Input Device Picker (inline overlay)

private struct InputDevicePicker: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var hoveredDeviceUID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Input Source")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if appState.inputDevices.isEmpty {
                Text("No input devices found")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(appState.inputDevices.enumerated()), id: \.element.uid) { _, device in
                    let isSelected = appState.selectedInputDevice?.uid == device.uid
                    HStack(spacing: 6) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 10))
                            .foregroundStyle(isSelected ? .green : .white.opacity(0.3))
                            .frame(width: 14)

                        Text(device.name)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(isSelected ? 0.9 : 0.6))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(hoveredDeviceUID == device.uid ? Color.white.opacity(0.08) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering in hoveredDeviceUID = hovering ? device.uid : nil }
                    .onTapGesture {
                        appState.selectInputDevice(device)
                        isPresented = false
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Animated gradient border for instruction mode

private struct AnimatedGradientBorder: View {
    var cornerRadius: CGFloat = 12
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
        RoundedRectangle(cornerRadius: cornerRadius)
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

// MARK: - Glow border with traveling shine for hover states

private struct GlowBorder: View {
    var cornerRadius: CGFloat = 14
    var color: Color
    @State private var appeared = false
    @State private var shineAngle: Double = 0

    var body: some View {
        ZStack {
            // Base border — fades in (strokeBorder stays inside bounds)
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(color.opacity(appeared ? 0.5 : 0), lineWidth: 1.5)

            // Traveling shine highlight (also inside bounds)
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    AngularGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.35),
                            .init(color: color.opacity(appeared ? 0.9 : 0), location: 0.5),
                            .init(color: .clear, location: 0.65),
                            .init(color: .clear, location: 1.0),
                        ],
                        center: .center,
                        angle: .degrees(shineAngle)
                    ),
                    lineWidth: 1.5
                )
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) { appeared = true }
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                shineAngle = 360
            }
        }
        .allowsHitTesting(false)
    }
}
