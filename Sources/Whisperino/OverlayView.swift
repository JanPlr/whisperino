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

    /// True from "recording stopped" until the pill is gone - the span
    /// where the unified pill shows the typing flow instead of the
    /// waveform.
    private var isProcessingState: Bool {
        switch appState.state {
        case .transcribing, .refining, .result, .dismissing: return true
        default: return false
        }
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
    /// never resize for picker open/close - SwiftUI handles the visual animation.
    /// Must match OverlayPanel.pickerExtraHeight exactly.
    private var pickerExtraHeight: CGFloat {
        let deviceCount = max(appState.inputDevices.count, 1)
        return 28 + CGFloat(deviceCount) * 26 + 12 + 1
    }

    var body: some View {
        Group {
            if appState.isChatActive {
                // Chat open → the unified pill (with chat scroll docked on
                // top), whatever the recording state. Content reacts to
                // state internally so the layout doesn't jump.
                recordingView.padding(.top, 6)
            } else if appState.fallbackResult != nil {
                // The take had no text field to land in - show it in a
                // card with a Copy escape hatch instead of losing it.
                fallbackResultCard.padding(.top, 6)
            } else {
                switch appState.state {
                case .idle:
                    Color.clear.frame(width: 0, height: 0)
                // One case for the ENTIRE take lifecycle so the pill is a
                // single stable element the whole way: the waveform morphs
                // into the typing flow, then the same pill fades out.
                // Separate cases re-created the view at each state hop,
                // turning the morph into crossfades. There's no separate
                // "Generating…" pill for AI takes - the chat sliding up is
                // the signal the model is working.
                case .recording, .cancelled,
                     .transcribing, .refining, .result, .dismissing:
                    recordingView.padding(.top, 6)
                case .error(let message):
                    errorView(message: message).padding(.top, 6)
                }
            }
        }
        .frame(width: 380)
        .padding(.bottom, 10)
        .frame(height: panelContentHeight, alignment: .bottom)
        .animation(appState.suppressStateAnimation ? nil : .spring(response: 0.24, dampingFraction: 0.85), value: appState.state)
        .animation(.spring(response: 0.24, dampingFraction: 0.85), value: appState.attachedContexts.count)
        // Picker pop is its own, snappier curve - it's a menu, not a
        // panel morph; it should appear, not unfold.
        .animation(.spring(response: 0.16, dampingFraction: 0.9), value: appState.showingInputPicker)
        // Same spring the picker uses, so opening the chat reads as
        // "the pill expanded" - both animations share a feel rather
        // than chat using a tween while every other expansion springs.
        .animation(.spring(response: 0.24, dampingFraction: 0.85), value: appState.isChatActive)
        .animation(.spring(response: 0.24, dampingFraction: 0.85), value: appState.fallbackResult != nil)
    }

    // MARK: - Fallback result card (nothing focused to paste into)

    @State private var copiedFallback = false
    @State private var isHoveringFallbackClose = false
    @State private var isHoveringFallbackCopy = false
    /// Drains 1→0 over `AppState.fallbackTimeout`, drawing the countdown
    /// ring around the ✕. Reset on each card appearance.
    @State private var fallbackCountdown: CGFloat = 1

    /// Wispr-style rescue card: the transcription couldn't be pasted
    /// (no focused text field), so it's shown here with a Copy button
    /// instead of silently vanishing.
    private var fallbackResultCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer(minLength: 8)

                Text("Select a textbox first, then dictate")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)

                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(isHoveringFallbackClose ? 1 : 0.8))
                    .frame(width: 26, height: 26)
                    .background(
                        // Track ring + draining countdown arc, starting
                        // at 12 o'clock and sweeping clockwise.
                        ZStack {
                            Circle().strokeBorder(
                                .white.opacity(isHoveringFallbackClose ? 0.7 : 0.18),
                                lineWidth: 1
                            )
                            Circle()
                                .trim(from: 0, to: fallbackCountdown)
                                .stroke(
                                    .white.opacity(isHoveringFallbackClose ? 0.9 : 0.55),
                                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                                .padding(0.75)
                        }
                    )
                    .contentShape(Circle())
                    .onHover { isHoveringFallbackClose = $0 }
                    .onTapGesture { appState.dismissFallback() }
                    .pointerOnHover()
            }

            Text(appState.fallbackResult ?? "")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.leading)
                .lineLimit(4)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Text(copiedFallback ? "Copied" : "Copy")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(isHoveringFallbackCopy ? 0.3 : 0.22))
                    )
                    .contentShape(Rectangle())
                    .onHover { isHoveringFallbackCopy = $0 }
                    .onTapGesture {
                        guard !copiedFallback else { return }
                        appState.copyToClipboard(appState.fallbackResult ?? "")
                        copiedFallback = true
                        // Brief "Copied" confirmation, then the card has
                        // done its job.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                            appState.dismissFallback()
                            copiedFallback = false
                        }
                    }
                    .pointerOnHover()
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
        )
        .transition(.scale(scale: 0.95).combined(with: .opacity))
        .onAppear {
            // Snap full, then drain over the same window AppState's
            // auto-dismiss timer uses, so the ring empties exactly as
            // the card vanishes.
            fallbackCountdown = 1
            withAnimation(.linear(duration: AppState.fallbackTimeout)) {
                fallbackCountdown = 0
            }
        }
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
    static let chatScrollHeight: CGFloat = 360

    @State private var isHoveringPill = false
    @State private var isHoveringMic = false
    @State private var isHoveringWaveform = false
    @State private var isHoveringLatchedCancel = false
    @State private var isHoveringLatchedSubmit = false

    // MARK: - Recording

    private var recordingView: some View {
        // Chips show whenever something is attached and we're in an AI
        // context - instruction mode (one-shot) or any chat state.
        let chatActive = appState.isChatActive
        let hasAttachments = (appState.isInstructionMode || chatActive) && !appState.attachedContexts.isEmpty
        let cancelled = isCancelled
        // Recording stopped → same pill, typing-flow content. Only the RAW
        // dictation path morphs into the typing flow; AI takes keep the
        // latched cluster up the whole time (see `latched`).
        let processing = isProcessingState && !chatActive
            && !appState.isInstructionMode && !appState.isAgentMode
        // The latched cluster - mic-select ○, ✕ to discard, waveform, ✓ to
        // submit - is the persistent anchor for the WHOLE AI flow: first
        // take, generation gap and open chat all keep the identical cluster
        // rather than morphing into a status pill or plain waveform.
        let latched = (appState.isLatchedRecording || chatActive
            || appState.isInstructionMode || appState.isAgentMode)
            && !cancelled && !processing
        // Every pill is a full capsule, 30pt tall in all modes (radius 15 =
        // half height): waveform row 16pt + 7 padding; latched swaps in 22pt
        // ✕/✓ buttons with 4pt padding — same 30pt.
        let pillRadius: CGFloat = 15
        return ZStack {
            // Wispr-style cluster: mic satellite + pill in one bottom-aligned
            // HStack. The mic circle is exactly the pill's height (30pt), so
            // bottom alignment IS center alignment. Only shown in latched
            // mode; hold-to-talk takes are too quick for device switching.
            HStack(alignment: .bottom, spacing: 4) {
            if latched {
                micSelectorButton
                    .transition(.scale.combined(with: .opacity))
            }

            // The bottom pill: the live waveform (or typing flow). In chat
            // mode the conversation floats in a detached card above it;
            // outside chat it's the usual dictation pill, optionally widened
            // for instruction-mode attachment chips.
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if hasAttachments && !chatActive && !cancelled { Spacer(minLength: 0) }

                    if processing {
                        // Same pill, new content: the typing flow takes the
                        // waveform's place and the pill springs wider to fit.
                        TypingFlowView()
                            .frame(height: 16)
                            .transition(.opacity)
                    } else {
                        if latched {
                            latchedCancelButton
                                .transition(.scale.combined(with: .opacity))
                        }

                        HStack(spacing: 2) {
                            ForEach(0..<AppState.waveformBarCount, id: \.self) { i in
                                Capsule()
                                    .fill(.white.opacity(0.78))
                                    .frame(width: 2, height: barHeight(for: i))
                            }
                        }
                        .frame(height: 16)
                        .transition(.opacity)

                        if latched {
                            latchedSubmitButton
                                .transition(.scale.combined(with: .opacity))
                        }
                    }

                    if hasAttachments && !chatActive && !cancelled { Spacer(minLength: 0) }
                }
                .padding(.horizontal, latched ? 4 : 11)
                .padding(.vertical, latched ? 4 : 7)
                .contentShape(Rectangle())
                .onHover { isHoveringWaveform = $0 }
                .onTapGesture {
                    // Latched mode carries explicit ✕ / ✓ controls, so a tap
                    // on the pill body is a no-op (a stray click shouldn't end
                    // the take or close the chat). The plain hold-to-talk pill
                    // still toggles recording on body tap.
                    if !processing && !latched {
                        appState.toggleRecording()
                    }
                }

                // Instruction-mode (one-shot) attachments stay inside the
                // pill. In chat mode they live in the floating card instead.
                if hasAttachments && !chatActive && !cancelled {
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
            .frame(width: (!cancelled && hasAttachments && !chatActive) ? 340 : nil)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: pillRadius, style: .continuous))
            .overlay(
                Group {
                    if cancelled {
                        EmptyView()
                    } else if isHoveringLatchedCancel {
                        GlowBorder(cornerRadius: pillRadius, color: Color(red: 0.9, green: 0.25, blue: 0.25))
                    } else if isHoveringLatchedSubmit {
                        GlowBorder(cornerRadius: pillRadius, color: Color(red: 0.25, green: 0.78, blue: 0.45))
                    } else if !latched && isHoveringWaveform {
                        GlowBorder(cornerRadius: pillRadius, color: Color(red: 0.25, green: 0.78, blue: 0.45))
                    } else if !latched && isHoveringPill {
                        GlowBorder(cornerRadius: pillRadius, color: Color(red: 0.25, green: 0.78, blue: 0.45))
                    } else {
                        // Calm dictation border vs. animated AI gradient.
                        // Gradient applies whenever we're in AI context -
                        // instruction mode for one-shots OR chat-active.
                        let inAIContext = appState.isInstructionMode || chatActive
                        ZStack {
                            RoundedRectangle(cornerRadius: pillRadius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
                                .opacity(inAIContext ? 0 : 1)
                            AnimatedGradientBorder(cornerRadius: pillRadius)
                                .opacity(inAIContext ? 1 : 0)
                        }
                        .animation(.easeInOut(duration: 0.35), value: inAIContext)
                    }
                }
            )
            // Exit - cancel and done share one gesture: the pill stays
            // put, slightly scales down, blurs and fades, all in 0.14s.
            .scaleEffect((cancelled || isDismissing) ? 0.9 : 1.0)
            .opacity((cancelled || isDismissing) ? 0 : 1)
            .blur(radius: (cancelled || isDismissing) ? 4 : 0)
            .animation(.easeOut(duration: 0.14), value: cancelled || isDismissing)
            .animation(.spring(response: 0.24, dampingFraction: 0.85), value: hasAttachments)
            // Width morph when the waveform hands over to the typing
            // flow - springy so the pill visibly *grows* into the
            // transcribing state rather than snapping.
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: processing)
            }
            // Input device picker for non-chat latched takes - anchored to
            // the mic satellite, popping out like a menu. In chat the picker
            // replaces the conversation card instead (see below).
            .overlay(alignment: .bottomLeading) {
                if appState.showingInputPicker && latched && !chatActive {
                    inputDevicePickerCard
                        .offset(y: -36)
                        .transition(
                            .scale(scale: 0.96, anchor: .bottomLeading)
                                .combined(with: .opacity)
                        )
                }
            }
        }
        // Detached floating element above the cluster: normally the
        // conversation card, crossfading with the mic picker when it opens.
        // Anchored to the whole ZStack so it stays centered on the panel
        // (not on the pill, which sits right-of-center once the mic
        // satellite joins). Grows upward, never shifts the cluster.
        .overlay(alignment: .bottom) {
            if chatActive && !cancelled {
                Group {
                    if appState.showingInputPicker {
                        inputDevicePickerCard
                            .transition(.opacity)
                    } else {
                        floatingChatCard(showAttachments: hasAttachments)
                            .transition(.opacity)
                    }
                }
                // Pill is 30pt tall; -(30 + 6) lands the floating element's
                // bottom edge 6pt above the pill's top.
                .offset(y: -36)
                .transition(
                    .opacity.combined(with: .scale(scale: 0.97, anchor: .bottom))
                )
            }
        }
        .onHover { hovering in
            isHoveringPill = hovering
            // Cursor over the panel counts as engagement - pause the
            // auto-close timer while hovering, restart the countdown on exit.
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
        .animation(.spring(response: 0.24, dampingFraction: 0.85), value: appState.attachedContexts.count)
        .animation(.spring(response: 0.24, dampingFraction: 0.85), value: appState.isLatchedRecording)
    }

    /// The detached conversation card that floats above the pill in chat
    /// mode. Holds the scrollable bubbles plus (in chat) any attachment
    /// chips. Its own dark rounded panel with a hairline border - the same
    /// chrome as the input-device picker - so it reads as a separate
    /// floating element, not part of the pill.
    private func floatingChatCard(showAttachments: Bool) -> some View {
        VStack(spacing: 0) {
            ChatScroll(appState: appState)
                .frame(height: Self.chatScrollHeight)

            if showAttachments {
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
        .frame(width: 360)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
        )
        // Hovering the card counts as reading the conversation - hold the
        // auto-close timer the same way the pill's onHover does. The card
        // floats outside the pill's frame, so the pill's own onHover never
        // fires here.
        .onHover { hovering in
            if hovering {
                appState.pauseChatIdleTimer()
            } else {
                appState.bumpChatIdleTimer()
            }
        }
    }

    /// The input-device picker in its floating panel chrome. Used in two
    /// spots: anchored to the mic satellite for non-chat latched takes,
    /// and (in chat) centered above the pill where it crossfades with the
    /// conversation card. Same dark panel + hairline border as the card.
    private var inputDevicePickerCard: some View {
        InputDevicePicker(appState: appState, isPresented: $appState.showingInputPicker)
            .frame(width: 240)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
            )
    }

    /// Mic circle to the left of the pill - exactly the latched row's
    /// height (32pt) and the same chrome (black, hairline border), so
    /// the cluster reads like one segmented control, Wispr-style.
    /// Click toggles the input device picker.
    private var micSelectorButton: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(isHoveringMic ? 1 : 0.8))
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.black))
            .overlay(
                Circle().strokeBorder(
                    isHoveringMic || appState.showingInputPicker
                        ? Color(red: 0.95, green: 0.55, blue: 0.15).opacity(0.8)
                        : Color.white.opacity(0.32),
                    lineWidth: 1
                )
            )
            .contentShape(Circle())
            .onHover { isHoveringMic = $0 }
            .onTapGesture {
                appState.refreshInputDevices()
                appState.showingInputPicker.toggle()
            }
            .pointerOnHover()
            .animation(.easeInOut(duration: 0.1), value: isHoveringMic)
    }

    // MARK: - Latched-recording controls (✕ / ✓ inline in the pill)

    /// Discard the take. Gray circle, white ✕ - turns red on hover like
    /// the corner cancel button so "destructive" reads the same everywhere.
    private var latchedCancelButton: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(isHoveringLatchedCancel ? 1 : 0.9))
            .frame(width: 22, height: 22)
            .background(
                Circle().fill(
                    isHoveringLatchedCancel
                        ? Color(red: 0.8, green: 0.2, blue: 0.2)
                        : Color(white: 0.32)
                )
            )
            .contentShape(Circle())
            .onHover { isHoveringLatchedCancel = $0 }
            .onTapGesture { appState.cancelRecording() }
            .pointerOnHover()
            .animation(.easeInOut(duration: 0.1), value: isHoveringLatchedCancel)
    }

    /// Submit the take. White circle, dark ✓ - the affirmative twin of
    /// the cancel button.
    private var latchedSubmitButton: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.black.opacity(0.85))
            .frame(width: 22, height: 22)
            .background(
                Circle().fill(.white.opacity(isHoveringLatchedSubmit ? 1 : 0.9))
            )
            .contentShape(Circle())
            .onHover { isHoveringLatchedSubmit = $0 }
            .onTapGesture { appState.submitOrFinish() }
            .pointerOnHover()
            .animation(.easeInOut(duration: 0.1), value: isHoveringLatchedSubmit)
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
        .allowsHitTesting(false)
    }

    /// Gentle shape mask - barely attenuates the edges so the wave is
    /// visibly present across the whole pill as it rolls right-to-left,
    /// rather than collapsing to a right-side spike.
    private static let barShape: [CGFloat] = [
        0.80, 0.85, 0.90, 0.94, 0.97, 1.0, 1.0,
        1.0, 0.97, 0.94, 0.90, 0.85, 0.80
    ]

    private func barHeight(for index: Int) -> CGFloat {
        let samples = appState.audioSamples
        guard samples.indices.contains(index) else { return 3 }
        // Spatial smoothing - blend each sample with its neighbours [1,2,1]/4
        // so a single-tick spike in one buffer position gets diluted into a
        // smooth crest instead of a jagged jump.
        let curr = CGFloat(samples[index])
        let prev = index > 0 ? CGFloat(samples[index - 1]) : curr
        let next = index < samples.count - 1 ? CGFloat(samples[index + 1]) : curr
        let smoothed = (prev + curr * 2 + next) / 4
        let shape = Self.barShape.indices.contains(index) ? Self.barShape[index] : 1.0
        // pow < 1 lifts quiet speech into clearly visible motion -
        // linear mapping left normal talking almost flat.
        let boosted = pow(smoothed, 0.6)
        return max(3, min(16, 3 + boosted * shape * 13))
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)

            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .overlayChrome()
    }
}

// MARK: - Overlay Chrome

/// Shared pill chrome, so every status pill matches: black, full capsule
/// (30pt tall, radius 15), 16pt content row, 11/7 padding, white 0.32
/// hairline.
private extension View {
    func overlayChrome(instruction: Bool = false) -> some View {
        self
            .frame(height: 16)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                Group {
                    if instruction {
                        AnimatedGradientBorder(cornerRadius: 15)
                    } else {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
                    }
                }
            )
    }
}

// MARK: - Typing flow (transcription in flight)

/// Speech-to-text made visible: word-length dashes write themselves
/// out left to right behind a caret, hold for a beat, fade, and start
/// a fresh line. Styled in the waveform's exact idiom - same white,
/// same 3pt stroke (a resting waveform dot, stretched into a word) -
/// and sized to the waveform's line width so the pill barely changes
/// when listening hands over to transcribing.
private struct TypingFlowView: View {
    /// Widths of the ghost words, varied like real text. Sum + gaps ≈
    /// the 13-bar waveform's width (~50pt).
    private static let words: [CGFloat] = [9, 13, 7, 11]
    private static let gap: CGFloat = 4
    /// Cadence between word starts (s). Fast: a warm whisper server
    /// finishes sub-second, and the user should see a COMPLETE line
    /// (~0.35s) within that window, not a half-drawn one.
    private static let perWord: Double = 0.1
    /// How long one word takes to ink out (s).
    private static let writeTime: Double = 0.08
    /// Full line lingers, then fades, then the cycle restarts.
    private static let hold: Double = 0.35
    private static let fade: Double = 0.2

    private static var typingTime: Double {
        Double(words.count - 1) * perWord + writeTime
    }
    private static var cycle: Double { typingTime + hold + fade }
    private static var lineWidth: CGFloat {
        words.reduce(0, +) + gap * CGFloat(words.count - 1)
    }

    /// Anchor for the animation clock. Captured when the view appears so
    /// every new transcription starts at the beginning of the cycle -
    /// clocking off absolute time made fresh pills join mid-cycle,
    /// sometimes right at the fade-out.
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = max(timeline.date.timeIntervalSince(start), 0)
                .truncatingRemainder(dividingBy: Self.cycle)

            ZStack(alignment: .leading) {
                ForEach(Self.words.indices, id: \.self) { i in
                    let p = wordProgress(i, at: t)
                    Capsule()
                        .fill(.white.opacity(0.78))
                        .frame(width: Self.words[i] * p, height: 3)
                        .offset(x: wordStart(i))
                        .opacity(p > 0 ? 1 : 0)
                }

                // Caret - glides along the writing edge, blinks while
                // the finished line holds.
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white.opacity(caretOpacity(at: t)))
                    .frame(width: 1.5, height: 11)
                    .offset(x: caretX(at: t) + 2)
            }
            .frame(width: Self.lineWidth + 4, height: 16, alignment: .leading)
            .opacity(lineOpacity(at: t))
        }
        .onAppear { start = Date() }
    }

    /// Leading x of word `i` within the line.
    private func wordStart(_ i: Int) -> CGFloat {
        Self.words.prefix(i).reduce(0, +) + Self.gap * CGFloat(i)
    }

    /// 0…1 ink-out progress of word `i`, smoothstep-eased.
    private func wordProgress(_ i: Int, at t: Double) -> CGFloat {
        let raw = (t - Double(i) * Self.perWord) / Self.writeTime
        let clamped = min(max(raw, 0), 1)
        return CGFloat(clamped * clamped * (3 - 2 * clamped))
    }

    private func caretX(at t: Double) -> CGFloat {
        guard t < Self.typingTime else {
            return Self.lineWidth
        }
        let k = min(Int(t / Self.perWord), Self.words.count - 1)
        return wordStart(k) + Self.words[k] * wordProgress(k, at: t)
    }

    private func caretOpacity(at t: Double) -> Double {
        // Solid while writing; soft 0.5s blink once the line is done.
        guard t >= Self.typingTime else { return 0.9 }
        let blink = 0.5 + 0.5 * cos((t - Self.typingTime) * 2 * .pi / 0.5)
        return 0.15 + 0.75 * blink
    }

    private func lineOpacity(at t: Double) -> Double {
        let fadeStart = Self.typingTime + Self.hold
        guard t > fadeStart else { return 1 }
        let raw = min(max((t - fadeStart) / Self.fade, 0), 1)
        return 1 - raw * raw * (3 - 2 * raw)
    }
}

// MARK: - Attachment row with image preview

private struct AttachmentRowView: View {
    let ctx: AttachedContext
    let onRemove: () -> Void
    @State private var showingPreview = false

    var body: some View {
        HStack(spacing: 6) {
            if case .image(let image) = ctx.content {
                Image(nsImage: ctx.thumbnail ?? image)
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
                .allowsHitTesting(false)

            Spacer(minLength: 0)

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
            // Base border - fades in (strokeBorder stays inside bounds)
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

/// The scrollable list of message bubbles. Hosted by `floatingChatCard`,
/// the detached panel that floats above the pill - the conversation grows
/// upward while the pill stays fixed at the bottom.
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
                    // Non-hit-testable so macOS doesn't show the text
                    // I-beam over the bubble - it's a read-only panel,
                    // the arrow cursor is correct.
                    .allowsHitTesting(false)
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
            Image(nsImage: ctx.thumbnail ?? image)
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
        // the action row - 4pt felt cramped, the buttons read as part
        // of the text.
        VStack(alignment: .leading, spacing: 8) {
            // Agent step timeline (only present on agent turns) - small
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
                    // See userBubble - keep the arrow cursor over text.
                    .allowsHitTesting(false)
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
        // reach for an I-beam from the Text - only the outer HStack
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
                // rows - no trailing line below the last step.
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
        // Read-only - keep the arrow cursor (no text I-beam).
        .allowsHitTesting(false)
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
