import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var store = SettingsStore.shared

    /// Team Rafterino easter egg - retints the pill (never reshapes it).
    private var rafterino: Bool { store.settings.rafterinoModeEnabled }

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


    /// Extra height reserved for the input device picker.
    /// Always included (even when picker is closed) so the panel and body frame
    /// never resize for picker open/close - SwiftUI handles the visual animation.
    /// Must match OverlayPanel.pickerExtraHeight exactly.
    private var pickerExtraHeight: CGFloat {
        let deviceCount = max(appState.inputDevices.count, 1)
        // 28 header + one row per device + 26 for the "Follow system default"
        // row + 12 padding + 1 hairline. Must match OverlayPanel.
        return 28 + CGFloat(deviceCount) * 26 + 26 + 12 + 1
    }

    var body: some View {
        Group {
            if appState.fallbackResult != nil {
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
                // turning the morph into crossfades. AI takes keep the same
                // pill and show the typing flow while the model works.
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
        // Picker pop is its own, snappier curve - it's a menu, not a
        // panel morph; it should appear, not unfold.
        .animation(.spring(response: 0.16, dampingFraction: 0.9), value: appState.showingInputPicker)
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
                if rafterino {
                    // The card is black, so punched-out eyes read the same
                    // as painted ones - and the mark stays monochrome.
                    RafterinoSkull(bone: .white, field: nil)
                        .frame(width: 17, height: 17)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }

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

    /// Vertical room the SwiftUI body claims inside the panel. Must match
    /// `OverlayPanel.panelHeight`.
    private var panelContentHeight: CGFloat {
        180 + pickerExtraHeight
    }

    @State private var isHoveringPill = false
    @State private var isHoveringMic = false
    @State private var isHoveringWaveform = false
    @State private var isHoveringLatchedCancel = false
    @State private var isHoveringLatchedSubmit = false
    /// Drives the pulsing orange ping around the mic button while the
    /// no-audio nudge is showing.
    @State private var micPulse = false

    // MARK: - Recording

    private var recordingView: some View {
        let cancelled = isCancelled
        // Recording stopped → same pill, typing-flow content. Applies to both
        // raw dictation and AI takes: once the mic closes, the waveform hands
        // over to the typing flow while transcription / generation runs.
        let processing = isProcessingState
        // The latched cluster - mic-select ○, ✕ to discard, waveform, ✓ to
        // submit - is the persistent anchor while the mic is open in AI mode
        // (or any latched take), rather than a plain waveform.
        let latched = (appState.isLatchedRecording
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

            // The bottom pill: the live waveform, or the typing flow while
            // transcription / AI generation runs.
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if processing {
                        // Same pill, new content: the typing flow takes the
                        // waveform's place and the pill springs wider to fit.
                        // In Rafterino mode your words drift by as a message
                        // in a bottle instead.
                        Group {
                            if rafterino {
                                RafterinoBottleFlowView()
                            } else {
                                TypingFlowView()
                            }
                        }
                        .frame(height: 16)
                        .transition(.opacity)
                    } else {
                        if latched {
                            latchedCancelButton
                                .transition(.scale.combined(with: .opacity))
                        }

                        // Live level display: the classic bar waveform, or -
                        // in Rafterino mode - the sea itself, with the raft
                        // riding the wave your voice makes.
                        Group {
                            if rafterino {
                                RafterinoLiveWaveView(samples: appState.audioSamples)
                            } else {
                                HStack(spacing: 2) {
                                    ForEach(0..<AppState.waveformBarCount, id: \.self) { i in
                                        Capsule()
                                            .fill(.white.opacity(0.78))
                                            .frame(width: 2, height: barHeight(for: i))
                                    }
                                }
                            }
                        }
                        .frame(height: 16)
                        .transition(.opacity)

                        if latched {
                            latchedSubmitButton
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .padding(.horizontal, latched ? 4 : 11)
                .padding(.vertical, latched ? 4 : 7)
                .contentShape(Rectangle())
                .onHover { isHoveringWaveform = $0 }
                .onTapGesture {
                    // Latched mode carries explicit ✕ / ✓ controls, so a tap
                    // on the pill body is a no-op (a stray click shouldn't end
                    // the take). The plain hold-to-talk pill still toggles
                    // recording on body tap.
                    if !processing && !latched {
                        appState.toggleRecording()
                    }
                }
            }
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
                        // Gradient applies whenever we're in AI mode.
                        // Rafterino mode trades the calm hairline for slow
                        // water; the AI rainbow still wins - mode identity
                        // beats theming.
                        let inAIContext = appState.isInstructionMode || appState.isAgentMode
                        ZStack {
                            RoundedRectangle(cornerRadius: pillRadius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
                                .opacity(inAIContext || rafterino ? 0 : 1)
                            if rafterino {
                                RafterinoWaterBorder(cornerRadius: pillRadius)
                                    .opacity(inAIContext ? 0 : 1)
                            }
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
            // Width morph when the waveform hands over to the typing
            // flow - springy so the pill visibly *grows* into the
            // transcribing state rather than snapping.
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: processing)
            }
            // Input device picker for latched takes - anchored to the mic
            // satellite, popping out like a menu.
            .overlay(alignment: .bottomLeading) {
                if appState.showingInputPicker && latched {
                    inputDevicePickerCard
                        .offset(y: -36)
                        .transition(
                            .scale(scale: 0.96, anchor: .bottomLeading)
                                .combined(with: .opacity)
                        )
                }
            }
        }
        // "We're recording but hearing nothing" nudge, floated just above the
        // pill without displacing it - the pill stays the stable anchor. Only
        // while the mic is actually open (not during the typing-flow handover
        // or a cancel).
        .overlay(alignment: .top) {
            // Hidden while the input picker is open - the picker sprouts from
            // the same mic button and would otherwise overlap the nudge.
            if appState.noAudioDetected && !processing && !cancelled
                && !appState.showingInputPicker {
                noAudioNudge
                    .offset(y: -42)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: appState.noAudioDetected)
        .animation(.easeOut(duration: 0.15), value: appState.showingInputPicker)
        .onHover { hovering in
            isHoveringPill = hovering
        }
        .animation(.easeOut(duration: 0.04), value: appState.audioSamples)
        .animation(.easeInOut(duration: 0.15), value: isHoveringPill)
        .animation(.easeInOut(duration: 0.15), value: isHoveringMic)
        .animation(.spring(response: 0.24, dampingFraction: 0.85), value: appState.isLatchedRecording)
    }

    /// The input-device picker in its floating panel chrome, anchored to the
    /// mic satellite. Same dark panel + hairline border as the pill.
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
            // Pulsing orange ping while the nudge is up - draws the eye to the
            // mic button as the place to fix a dead input.
            .overlay {
                if appState.noAudioDetected {
                    Circle()
                        .stroke(Color(red: 0.95, green: 0.55, blue: 0.15), lineWidth: 1.5)
                        .scaleEffect(micPulse ? 1.18 : 1.0)
                        .opacity(micPulse ? 0 : 0.55)
                        .animation(
                            .easeOut(duration: 1.3).repeatForever(autoreverses: false),
                            value: micPulse
                        )
                        .onAppear { micPulse = true }
                        .onDisappear { micPulse = false }
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Circle())
            .onHover { isHoveringMic = $0 }
            .onTapGesture {
                // The picker springs from here, so the nudge (which points at
                // this button) has served its purpose - clear it immediately
                // so the two never overlap.
                appState.noAudioDetected = false
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

    // MARK: - No-audio nudge

    /// Floated above the pill when the mic is open but no sound is coming
    /// through - almost always the wrong input device. Same black-capsule
    /// chrome as every status pill; the orange mic.slash borrows the error
    /// pill's warning idiom so it reads as "attention", not alarm.
    private var noAudioNudge: some View {
        HStack(spacing: 7) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)

            Text("No audio detected - check your mic source")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .fixedSize()
        }
        .overlayChrome()
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

// MARK: - Input Device Picker (inline overlay)

private struct InputDevicePicker: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var hoveredDeviceUID: String?

    /// Sentinel hover key for the "Follow system default" row - no real device
    /// carries this UID.
    private static let followDefaultUID = "__follow_system_default__"

    /// One picker row: radio-style checkmark, label, hover highlight. Shared by
    /// the "Follow system default" entry and each device.
    @ViewBuilder
    private func row(title: String, isSelected: Bool, uid: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? .green : .white.opacity(0.3))
                .frame(width: 14)

            Text(title)
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
                .fill(hoveredDeviceUID == uid ? Color.white.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in hoveredDeviceUID = hovering ? uid : nil }
        .onTapGesture(perform: action)
    }

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
                // "Follow system default" - the un-pinned mode. Selected when
                // no preferred mic is set.
                let followingDefault = !appState.hasPreferredInputDevice
                row(
                    title: "Follow system default",
                    isSelected: followingDefault,
                    uid: Self.followDefaultUID
                ) {
                    appState.clearPreferredInputDevice()
                    isPresented = false
                }

                ForEach(Array(appState.inputDevices.enumerated()), id: \.element.uid) { _, device in
                    // Only the pinned device gets the checkmark. While following
                    // the system default, no single device is singled out.
                    let isPinned = appState.hasPreferredInputDevice
                        && appState.selectedInputDevice?.uid == device.uid
                    row(title: device.name, isSelected: isPinned, uid: device.uid) {
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
