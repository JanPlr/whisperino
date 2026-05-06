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
            if appState.isChatActive {
                // Chat is open → always show the unified pill (with chat
                // scroll docked on top), regardless of recording / refining
                // / idle. The pill's content reacts to state internally
                // so the layout doesn't jump.
                recordingView.padding(.top, 6)
            } else {
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
        }
        .frame(width: 380)
        .padding(.bottom, 44)
        .frame(height: panelContentHeight, alignment: .bottom)
        .animation(appState.suppressStateAnimation ? nil : .spring(response: 0.35, dampingFraction: 0.82), value: appState.state)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: appState.attachedContexts.count)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: appState.showingInputPicker)
        // Same spring the picker uses, so opening the chat reads as
        // "the pill expanded" — both animations share a feel rather
        // than chat using a tween while every other expansion springs.
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: appState.isChatActive)
    }

    /// Vertical room the SwiftUI body claims inside the panel. Pill alone
    /// is short; chat reserves a fixed scroll area above. Must match
    /// `OverlayPanel.panelHeight`.
    private var panelContentHeight: CGFloat {
        var h = 180 + attachmentExtraHeight + pickerExtraHeight
        if appState.isChatActive {
            h += Self.chatScrollHeight
        }
        return h
    }

    /// Height reserved for the chat scroll area when chat is active.
    /// Internal scroll handles longer conversations past this.
    static let chatScrollHeight: CGFloat = 320

    @State private var isHoveringPill = false
    @State private var isHoveringCancel = false
    @State private var isHoveringMic = false
    @State private var isHoveringWaveform = false

    // MARK: - Recording

    private var recordingView: some View {
        // Chips are visible whenever there's something attached and the
        // user is in an AI context — instruction mode (one-shot) or any
        // chat state. Without `chatActive`, pre-attached items between
        // turns wouldn't render.
        let chatActive = appState.isChatActive
        let hasAttachments = (appState.isInstructionMode || chatActive) && !appState.attachedContexts.isEmpty
        let cancelled = isCancelled

        return ZStack {
            // === The pill (with optional chat scroll docked on top) ===
            VStack(spacing: 0) {
                if chatActive {
                    // Same transition the input device picker uses
                    // (.opacity + .move(edge: .top)) so the chat reads
                    // as "the pill expanded upward" rather than a
                    // separate slab sliding into place. The
                    // panel itself is also growing on this gesture.
                    ChatScroll(appState: appState)
                        .frame(height: Self.chatScrollHeight)
                        .transition(.opacity.combined(with: .move(edge: .top)))

                    Rectangle()
                        .fill(.white.opacity(0.06))
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                        .transition(.opacity)
                }

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
                    if (hasAttachments || chatActive) && !cancelled { Spacer(minLength: 0) }

                    if chatActive {
                        // Chat-aware pill content. The waveform only
                        // shows during *actual* recording — during
                        // transcribing / refining we'd just be showing
                        // flat bars next to status text, which read as
                        // confused "listening" UI. So those states get
                        // a simple centered indicator and nothing else.
                        ChatPillContent(appState: appState)
                    } else {
                        HStack(spacing: 3) {
                            ForEach(0..<AppState.waveformBarCount, id: \.self) { i in
                                Capsule()
                                    .fill(.white.opacity(0.78))
                                    .frame(width: 3.5, height: barHeight(for: i))
                            }
                        }
                        .frame(height: 22)
                    }

                    if (hasAttachments || chatActive) && !cancelled { Spacer(minLength: 0) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onHover { isHoveringWaveform = $0 }
                .onTapGesture {
                    // In chat-idle, tapping the pill = "finish" (paste latest
                    // and close, per the user's spec). Otherwise it toggles
                    // recording as before.
                    if chatActive, case .idle = appState.state {
                        if let latest = appState.chatHistory.last(where: { $0.role == .assistant }),
                           !latest.text.isEmpty {
                            appState.pasteIntoTargetApp(latest.text)
                        }
                        appState.closeChat()
                    } else {
                        appState.toggleRecording()
                    }
                }

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
                            addMoreHint
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
            .frame(width: (!cancelled && (hasAttachments || appState.showingInputPicker || chatActive)) ? 340 : nil)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                    } else {
                        // Calm dictation border vs. animated AI gradient.
                        // Gradient applies whenever we're in AI context —
                        // instruction mode for one-shots OR chat-active.
                        let inAIContext = appState.isInstructionMode || chatActive
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
                                .opacity(inAIContext ? 0 : 1)
                            AnimatedGradientBorder(cornerRadius: 18)
                                .opacity(inAIContext ? 1 : 0)
                        }
                        .animation(.easeInOut(duration: 0.35), value: inAIContext)
                    }
                }
            )
            .scaleEffect(cancelled ? 0.92 : 1.0)
            .opacity(cancelled ? 0 : 1)
            .blur(radius: cancelled ? 4 : 0)
            .animation(.easeOut(duration: 0.22), value: cancelled)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hasAttachments)
            // Cancel / close X — top-right. Same style as the existing
            // recording-pill cancel button so chat doesn't introduce a
            // foreign visual idiom. Tap closes the chat when chat is
            // active, cancels the recording otherwise.
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
                    .onTapGesture {
                        if chatActive {
                            appState.closeChat()
                        } else {
                            appState.cancelRecording()
                        }
                    }
                    .opacity((isHoveringPill && !cancelled) ? (isHoveringCancel ? 1 : 0.7) : 0)
                    .scaleEffect((isHoveringPill && !cancelled) ? 1 : 0.4)
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
        .onHover { hovering in
            isHoveringPill = hovering
            // Reading / scrolling the chat counts as engagement — keep
            // the auto-close timer paused while the cursor is anywhere
            // over the panel. When the cursor leaves, restart the
            // 20s countdown.
            if appState.isChatActive {
                if hovering {
                    appState.pauseChatIdleTimer()
                } else {
                    appState.bumpChatIdleTimer()
                }
            }
        }
        .animation(.easeOut(duration: 0.04), value: appState.audioSamples)
        .animation(.easeInOut(duration: 0.15), value: isHoveringPill)
        .animation(.easeInOut(duration: 0.15), value: isHoveringMic)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: appState.attachedContexts.count)
    }

    private func attachmentRow(_ ctx: AttachedContext) -> some View {
        AttachmentRowView(ctx: ctx, onRemove: { appState.removeAttachment(id: ctx.id) })
    }

    private var addMoreHint: some View {
        HStack(spacing: 5) {
            Image(systemName: "command")
                .font(.system(size: 8, weight: .medium))
            Text("Cmd+C anything to add as context")
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.3))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    /// Gentle shape mask — barely attenuates the edges so the wave is
    /// visibly present across the whole pill as it rolls right-to-left,
    /// rather than collapsing to a right-side spike.
    private static let barShape: [CGFloat] = [
        0.85, 0.90, 0.95, 1.0, 1.0, 1.0, 0.95, 0.90, 0.85
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
                Image(systemName: "pencil")
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
                Image(systemName: "pencil")
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
                : appState.isInstructionMode ? "Generated" : "Saved transcription")
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

// MARK: - Chat scroll (sits above the pill when chat-active)

/// The scrollable list of message bubbles. Lives inside the same dark
/// rounded panel as the pill, mirroring the InputDevicePicker pattern —
/// content expands above; the pill stays fixed at the bottom.
private struct ChatScroll: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Top spacer so the close X corner doesn't overlap
                    // the first user bubble's right edge.
                    Color.clear.frame(height: 12)

                    ForEach(appState.chatHistory) { turn in
                        ChatBubble(turn: turn, appState: appState)
                            .id(turn.id)
                    }

                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            // Disable rubber-band overscroll when content already fits.
            // When it overflows, AppKit's elastic edge still helps the
            // user feel the boundary, but the slow snap-back the user
            // saw with short conversations is gone.
            .scrollBounceBehavior(.basedOnSize)
            // Auto-scroll on new bubbles AND while text is streaming
            // into the latest assistant turn. Snapping (no animation)
            // each chunk reads as smooth follow-along because chunks
            // arrive faster than any animation could complete; an
            // animated scroll on every chunk would queue up and stall.
            .onChange(of: appState.chatHistory.count) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: appState.chatHistory.last?.text) {
                guard appState.isStreamingResponse else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

// MARK: - Chat bubble

private struct ChatBubble: View {
    let turn: ChatTurn
    @ObservedObject var appState: AppState
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        if turn.role == .user {
            userBubble
        } else if turn.text.isEmpty && turn.isStreaming && turn.agentSteps.isEmpty {
            // Empty + streaming + no agent timeline → render nothing.
            // The bubble materialises once tokens arrive.
            EmptyView()
        } else {
            assistantBubble
        }
    }

    // MARK: User

    private var userBubble: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 32)
            VStack(alignment: .trailing, spacing: 6) {
                if !turn.attachments.isEmpty {
                    attachmentStrip
                }
                Text(turn.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    )
            }
            .frame(maxWidth: 250, alignment: .trailing)
        }
    }

    private var attachmentStrip: some View {
        HStack(spacing: 4) {
            ForEach(turn.attachments) { ctx in
                attachmentChip(ctx)
            }
        }
    }

    @ViewBuilder
    private func attachmentChip(_ ctx: AttachedContext) -> some View {
        switch ctx.content {
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                )
        case .text:
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .font(.system(size: 8))
                Text(ctx.preview)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(.white.opacity(0.05))
            )
        }
    }

    // MARK: Assistant

    private var assistantBubble: some View {
        // Actions always rendered (so layout never shifts) and fade
        // in/out via opacity. 8pt of breathing room between text and
        // the action row — 4pt felt cramped, the buttons read as part
        // of the text.
        VStack(alignment: .leading, spacing: 8) {
            // Agent step timeline (only present on agent turns) — small
            // dim rows above the answer, like a build log. Fades to
            // ~0.5 opacity once the answer arrives so it doesn't
            // compete visually with the response.
            if !turn.agentSteps.isEmpty {
                AgentStepTimeline(steps: turn.agentSteps, dim: !turn.text.isEmpty)
                    .padding(.bottom, turn.text.isEmpty ? 0 : 4)
            }

            if !turn.text.isEmpty {
                Text(turn.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.88))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                bubbleAction(
                    icon: copied ? "checkmark" : "doc.on.doc",
                    label: copied ? "copied" : "copy"
                ) {
                    appState.copyToClipboard(turn.text)
                    withAnimation(.easeOut(duration: 0.15)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copied = false
                    }
                }
                bubbleAction(icon: "arrow.up.right.square", label: "paste") {
                    appState.pasteIntoTargetApp(turn.text)
                }
            }
            .opacity((turn.isStreaming || turn.text.isEmpty) ? 0 : (hovering ? 0.85 : 0.4))
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.15), value: turn.isStreaming)
            .allowsHitTesting(!turn.isStreaming && !turn.text.isEmpty)
        }
        .frame(maxWidth: 280, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { h in hovering = h }
    }

    private func bubbleAction(icon: String, label: String, action: @escaping () -> Void) -> some View {
        // Inner Image/Text are non-hit-testable so the system can't
        // reach for an I-beam from the Text — only the outer HStack
        // (with its rect contentShape) receives cursor and tap events.
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .allowsHitTesting(false)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .allowsHitTesting(false)
        }
        .foregroundStyle(.white.opacity(0.45))
        // Fixed slot width so a label change ("copy" → "copied") on
        // one button doesn't shove the next button sideways. Leading
        // alignment keeps the icon anchored to the left of the slot.
        .frame(width: 56, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .pointerOnHover()
    }
}

// MARK: - Agent step timeline (rendered above the final answer in the
// assistant bubble for agent runs)

private struct AgentStepTimeline: View {
    let steps: [AgentStepEvent]
    /// Once the final answer is in, the timeline dims so it doesn't
    /// compete with the response text.
    let dim: Bool

    private static let iconColumnWidth: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                HStack(spacing: 8) {
                    Image(systemName: step.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(iconOpacity(for: step)))
                        .frame(width: Self.iconColumnWidth, alignment: .center)

                    Text(step.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(textOpacity(for: step)))

                    Spacer(minLength: 0)
                }

                // Thin connector to the next row's icon. Only between
                // rows — no trailing line below the last step.
                if idx < steps.count - 1 {
                    Rectangle()
                        .fill(.white.opacity(dim ? 0.08 : 0.14))
                        .frame(width: 1, height: 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Centered under the icon column.
                        .padding(.leading, (Self.iconColumnWidth - 1) / 2)
                }
            }
        }
    }

    private func iconOpacity(for step: AgentStepEvent) -> Double {
        if dim { return 0.4 }
        return step.completed ? 0.5 : 0.85
    }

    private func textOpacity(for step: AgentStepEvent) -> Double {
        if dim { return 0.4 }
        return step.completed ? 0.5 : 0.78
    }
}

// MARK: - Inline pill status (right of the waveform during chat)

/// Single source of truth for what the pill shows during a chat
/// session. Branches on state so the pill area never simultaneously
/// shows a waveform *and* a status label — that combination read as
/// "listening" even when we were actually transcribing or thinking.
private struct ChatPillContent: View {
    @ObservedObject var appState: AppState
    @State private var pulse = false

    var body: some View {
        Group {
            switch appState.state {
            case .recording, .paused:
                // Live waveform mirrors what the standalone pill shows —
                // we just inline it here when chat is open.
                HStack(spacing: 3) {
                    ForEach(0..<AppState.waveformBarCount, id: \.self) { i in
                        Capsule()
                            .fill(.white.opacity(0.78))
                            .frame(width: 3.5, height: barHeight(for: i))
                    }
                }
                .frame(height: 22)
                .animation(.easeOut(duration: 0.04), value: appState.audioSamples)

            case .transcribing, .refining:
                // No status label here. The animated border on the panel
                // and the streaming bubble (once tokens arrive) carry the
                // "AI is working" signal — a duplicate label in the pill
                // just adds noise. Empty area keeps layout stable.
                Color.clear.frame(height: 22)

            case .error(let msg):
                Text(msg)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: 22)

            default:
                idleIndicator
            }
        }
    }

    // Calm chat-idle indicator — subtle mic + key glyph. Replaces the
    // waveform when no recording is in flight so the pill doesn't *look*
    // like it's listening when it isn't.
    private var idleIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(pulse ? 0.55 : 0.32))

            Text(SettingsStore.shared.settings.triggerKey.shortLabel)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 0.5)
                )
        }
        .frame(height: 22)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private func workingLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(height: 22)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let samples = appState.audioSamples
        guard samples.indices.contains(index) else { return 4 }
        let curr = CGFloat(samples[index])
        let prev = index > 0 ? CGFloat(samples[index - 1]) : curr
        let next = index < samples.count - 1 ? CGFloat(samples[index + 1]) : curr
        let smoothed = (prev + curr * 2 + next) / 4
        return max(4, 4 + smoothed * 16)
    }
}

// MARK: - Pointer cursor helper

private extension View {
    /// Force the pointing-hand cursor while hovering this view.
    ///
    /// `.onContinuousHover` (not `.onHover`) is essential here:
    /// `.onHover` only fires when hover state *changes*, so after a
    /// click the system can revert the cursor (e.g. macOS resetting to
    /// the view's default after the press) and we never get a chance
    /// to set it back. Continuous hover fires on every mouse movement
    /// inside the view, which means we re-assert the pointing-hand on
    /// every micro-motion and the system can't drift it back to an
    /// I-beam between clicks.
    func pointerOnHover() -> some View {
        self.onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.pointingHand.set()
            case .ended:
                NSCursor.arrow.set()
            }
        }
    }
}
